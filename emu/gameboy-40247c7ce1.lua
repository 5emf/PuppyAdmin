-- PuppyAdmin gameboy 40247c7ce1 (original Game Boy emulator; games are loaded from your own PuppyAdmin/roms folder)
local GB = (function()
-- Puppy Admin Game Boy core (original DMG). Plain Lua that runs in Luau.
-- GB.new(romString, saveString?) -> emu   (errors on a ROM it cannot run)
--   emu.runFrame()            one video frame (70224 clock cycles)
--   emu.fb                    160 x 144 shades 0 (lightest) .. 3, row by row, index 1..23040
--   emu.setButton(name, down) right left up down a b select start
--   emu.saveData()            battery RAM as a string, or nil;  emu.dirty() / emu.clearDirty()
--   emu.title, emu.battery, emu.serial() (text the game sent to the link port; used by test ROMs)
-- No sound. Timing is per instruction, rendering per scanline.
local GB = {}

local band, bor, bxor, rsh = bit32.band, bit32.bor, bit32.bxor, bit32.rshift
local byte, char, concat = string.byte, string.char, table.concat

local IRQ_BIT = { [0] = 1, [1] = 2, [2] = 4, [3] = 8, [4] = 16 }
-- BITS[v][p + 1]: pixel p (0 = left) of a tile row byte v; BITSF: mirrored
local BITS, BITSF = {}, {}
for v = 0, 255 do
    local t, f = {}, {}
    for p = 0, 7 do
        t[p + 1] = bit32.band(bit32.rshift(v, 7 - p), 1)
        f[p + 1] = bit32.band(bit32.rshift(v, p), 1)
    end
    BITS[v], BITSF[v] = t, f
end
local RAM_SIZES = { [0] = 0, [1] = 2048, [2] = 8192, [3] = 32768, [4] = 131072, [5] = 65536 }
local CART = {
    [0x00] = { "none" }, [0x08] = { "none" }, [0x09] = { "none", true },
    [0x01] = { "mbc1" }, [0x02] = { "mbc1" }, [0x03] = { "mbc1", true },
    [0x05] = { "mbc2" }, [0x06] = { "mbc2", true },
    [0x0F] = { "mbc3", true }, [0x10] = { "mbc3", true }, [0x11] = { "mbc3" }, [0x12] = { "mbc3" }, [0x13] = { "mbc3", true },
    [0x19] = { "mbc5" }, [0x1A] = { "mbc5" }, [0x1B] = { "mbc5", true },
    [0x1C] = { "mbc5" }, [0x1D] = { "mbc5" }, [0x1E] = { "mbc5", true },
}
GB.CART = CART

function GB.new(romStr, saveStr)
    assert(type(romStr) == "string" and #romStr >= 0x150, "not a Game Boy ROM (too small)")
    local cgbFlag = byte(romStr, 0x144)
    if cgbFlag == 0xC0 then error("this is a Game Boy Color-only game; only original Game Boy games run here", 0) end
    local cartType = byte(romStr, 0x148)
    local cart = CART[cartType]
    if not cart then error(string.format("unsupported cartridge type 0x%02X", cartType), 0) end
    local mbc, battery = cart[1], cart[2] == true

    -- ROM as a table of bytes (1-based), padded to whole 16 KiB banks
    local rom = {}
    local n = #romStr
    local i = 1
    while i <= n do
        local j = math.min(n, i + 1023)
        local t = { byte(romStr, i, j) }
        for k = 1, #t do rom[i + k - 1] = t[k] end
        i = j + 1
    end
    local romBanks = math.max(2, math.ceil(n / 16384))
    for k = n + 1, romBanks * 16384 do rom[k] = 0xFF end

    local ramSize = RAM_SIZES[byte(romStr, 0x14A)] or 0
    if mbc == "mbc2" then ramSize = 512 end
    local eram = {}
    for k = 1, ramSize do eram[k] = 0 end
    if saveStr and #saveStr > 0 then
        for k = 1, math.min(ramSize, #saveStr) do eram[k] = byte(saveStr, k) end
    end

    local title = romStr:sub(0x135, 0x144):gsub("[%z\128-\255]", ""):gsub("%s+$", "")

    local vram, wram, oam, hram, io = {}, {}, {}, {}, {}
    for k = 1, 8192 do vram[k] = 0; wram[k] = 0 end
    for k = 1, 160 do oam[k] = 0 end
    for k = 1, 127 do hram[k] = 0 end
    local fb = {}
    for k = 1, 23040 do fb[k] = 0 end
    local bgIdx = {}
    for k = 0, 159 do bgIdx[k] = 0 end
    local linePal = { [0] = 0, 0, 0, 0 }

    -- CPU state (post boot ROM values)
    local A, B, C, D, E, H, L = 0x01, 0x00, 0x13, 0x00, 0xD8, 0x01, 0x4D
    local fZ, fN, fH, fC = 1, 0, 1, 1
    local SP, PC = 0xFFFE, 0x0100
    local ime, eiDelay, halted = false, false, false
    local IE, IF = 0, 0xE1

    -- cartridge
    local romOff = 16384          -- 1-based start of the switchable bank in rom[] minus 0x4000 handled in rb
    local rom0Off = 0             -- bank used for 0000-3FFF (MBC1 mode 1)
    local ramOn, ramOff = false, 0
    local bankLo, bankHi, mbcMode = 1, 0, 0
    local rtcSel = -1
    local dirty = false

    local function mapBanks()
        if mbc == "mbc1" then
            local bank = bankLo + bankHi * 32
            romOff = (bank % romBanks) * 16384
            if mbcMode == 1 then
                rom0Off = ((bankHi * 32) % romBanks) * 16384
                ramOff = (ramSize > 8192) and (bankHi * 8192) or 0
            else
                rom0Off = 0
                ramOff = 0
            end
        elseif mbc == "mbc5" then
            romOff = ((bankLo + bankHi * 256) % romBanks) * 16384
        else
            romOff = (bankLo % romBanks) * 16384
        end
    end

    local function mbcWrite(a, v)
        if mbc == "none" then return end
        if a < 0x2000 then
            if mbc == "mbc2" then
                if band(a, 0x100) == 0 then ramOn = band(v, 15) == 10 else bankLo = math.max(1, band(v, 15)) end
            else
                ramOn = band(v, 15) == 10
            end
        elseif a < 0x4000 then
            if mbc == "mbc1" then
                bankLo = band(v, 31)
                if bankLo == 0 then bankLo = 1 end
            elseif mbc == "mbc3" then
                bankLo = band(v, 127)
                if bankLo == 0 then bankLo = 1 end
            elseif mbc == "mbc5" then
                if a < 0x3000 then bankLo = v else bankHi = band(v, 1) end
            elseif mbc == "mbc2" then
                if band(a, 0x100) ~= 0 then bankLo = math.max(1, band(v, 15)) end
            end
        elseif a < 0x6000 then
            if mbc == "mbc1" then
                bankHi = band(v, 3)
            elseif mbc == "mbc3" then
                if v <= 3 then ramOff = v * 8192; rtcSel = -1 elseif v >= 8 and v <= 12 then rtcSel = v end
            elseif mbc == "mbc5" then
                ramOff = band(v, 15) * 8192
            end
        else
            if mbc == "mbc1" then mbcMode = band(v, 1) end
        end
        mapBanks()
    end

    -- MBC3 clock registers: read from the real time (latching is ignored)
    local function rtcRead()
        local t = os.time()
        if rtcSel == 8 then return t % 60 end
        if rtcSel == 9 then return math.floor(t / 60) % 60 end
        if rtcSel == 10 then return math.floor(t / 3600) % 24 end
        local days = math.floor(t / 86400) % 512
        if rtcSel == 11 then return days % 256 end
        return math.floor(days / 256)
    end

    -- timer / video / input registers
    local div, divCount, tima, tma, tac, timerCount = 0xAB, 0, 0, 0, 0xF8, 0
    local TIMER_PERIOD = { [0] = 1024, [1] = 16, [2] = 64, [3] = 256 }
    local lcdc, stat, scy, scx, ly, lyc, bgp, obp0, obp1, wy, wx = 0x91, 0x85, 0, 0, 0, 0, 0xFC, 0xFF, 0xFF, 0, 0
    local mode, lineClock, winLine, frameDone = 2, 0, 0, false
    local joySel, dpad, buttons = 0x30, 15, 15     -- 1 = released
    local sb, serialOut = 0, {}

    -- Sound chip: registers, length / envelope / sweep timers and a per-frame
    -- snapshot of each channel (emu.audio). No samples are generated here: the
    -- front end plays looping tones at these pitches and volumes.
    local SND_OR = {
        [0x10] = 0x80, [0x11] = 0x3F, [0x12] = 0x00, [0x13] = 0xFF, [0x14] = 0xBF, [0x15] = 0xFF,
        [0x16] = 0x3F, [0x17] = 0x00, [0x18] = 0xFF, [0x19] = 0xBF, [0x1A] = 0x7F, [0x1B] = 0xFF,
        [0x1C] = 0x9F, [0x1D] = 0xFF, [0x1E] = 0xBF, [0x1F] = 0xFF, [0x20] = 0xFF, [0x21] = 0x00,
        [0x22] = 0x00, [0x23] = 0xBF, [0x24] = 0x00, [0x25] = 0x00,
    }
    local snd = { regs = {}, power = true, seqCount = 0, seqStep = 0, wave = {}, shape = "tri", waveDirty = true, ch = {} }
    for k = 0x10, 0x25 do snd.regs[k] = 0 end
    for k = 0, 15 do snd.wave[k] = 0 end
    for n = 1, 4 do
        snd.ch[n] = { on = false, dac = false, len = 0, lenOn = false, vol = 0, envVol = 0, envUp = false, envPeriod = 0, envTimer = 0,
            freq = 0, duty = 2, volCode = 0, sweepTimer = 0, sweepOn = false, shadow = 0 }
    end
    local SND_BASE = { 0x10, 0x15, 0x1A, 0x1F }

    local function sweepCalc(c)
        local r = snd.regs[0x10]
        local delta = rsh(c.shadow, band(r, 7))
        local nf = band(r, 8) ~= 0 and (c.shadow - delta) or (c.shadow + delta)
        if nf > 2047 then c.on = false end
        return nf
    end

    local function trigger(n)
        local c = snd.ch[n]
        c.on = c.dac
        if c.len == 0 then c.len = n == 3 and 256 or 64 end
        if n ~= 3 then
            c.vol = c.envVol
            c.envTimer = c.envPeriod == 0 and 8 or c.envPeriod
        end
        if n == 1 then
            local r = snd.regs[0x10]
            local period, shift = band(rsh(r, 4), 7), band(r, 7)
            c.shadow = c.freq
            c.sweepTimer = period == 0 and 8 or period
            c.sweepOn = period > 0 or shift > 0
            if shift > 0 then sweepCalc(c) end
        end
    end

    local function sndWrite(reg, v)
        if reg >= 0x30 then
            snd.wave[reg - 0x30] = v
            snd.waveDirty = true
            return
        end
        if reg == 0x26 then
            local on = band(v, 0x80) ~= 0
            if snd.power and not on then
                for k = 0x10, 0x25 do snd.regs[k] = 0 end
                for n = 1, 4 do local c = snd.ch[n]; c.on = false; c.dac = false; c.len = 0; c.lenOn = false end
            end
            snd.power = on
            return
        end
        if not snd.power or not SND_OR[reg] then return end
        snd.regs[reg] = v
        local n = reg < 0x15 and 1 or (reg < 0x1A and 2 or (reg < 0x1F and 3 or (reg < 0x24 and 4 or 0)))
        if n == 0 then return end
        local c = snd.ch[n]
        local r = reg - SND_BASE[n]
        if r == 1 then
            if n == 3 then c.len = 256 - v
            else
                c.len = 64 - band(v, 63)
                if n <= 2 then c.duty = rsh(v, 6) end
            end
        elseif r == 2 then
            if n == 3 then
                c.volCode = band(rsh(v, 5), 3)
            else
                c.envVol, c.envUp, c.envPeriod = rsh(v, 4), band(v, 8) ~= 0, band(v, 7)
                c.dac = band(v, 0xF8) ~= 0
                if not c.dac then c.on = false end
            end
        elseif r == 0 and n == 3 then
            c.dac = band(v, 0x80) ~= 0
            if not c.dac then c.on = false end
        elseif r == 3 or r == 4 then
            if n ~= 4 then
                c.freq = snd.regs[SND_BASE[n] + 3] + band(snd.regs[SND_BASE[n] + 4], 7) * 256
            end
            if r == 4 then
                c.lenOn = band(v, 0x40) ~= 0
                if band(v, 0x80) ~= 0 then trigger(n) end
            end
        end
    end

    local function sndRead(reg)
        if reg >= 0x30 then return snd.wave[reg - 0x30] end
        if reg == 0x26 then
            local v = 0x70 + (snd.power and 0x80 or 0)
            for n = 1, 4 do if snd.ch[n].on then v = v + IRQ_BIT[n - 1] end end
            return v
        end
        local m = SND_OR[reg]
        if not m then return 0xFF end
        return bor(snd.regs[reg], m)
    end

    -- 512 Hz: length (256 Hz), sweep (128 Hz), envelope (64 Hz)
    local function sndStep()
        local step = snd.seqStep
        snd.seqStep = (step + 1) % 8
        if step % 2 == 0 then
            for n = 1, 4 do
                local c = snd.ch[n]
                if c.lenOn and c.len > 0 then
                    c.len = c.len - 1
                    if c.len == 0 then c.on = false end
                end
            end
        end
        if step == 2 or step == 6 then
            local c = snd.ch[1]
            c.sweepTimer = c.sweepTimer - 1
            if c.sweepTimer <= 0 then
                local r = snd.regs[0x10]
                local period = band(rsh(r, 4), 7)
                c.sweepTimer = period == 0 and 8 or period
                if c.sweepOn and period > 0 and c.on then
                    local nf = sweepCalc(c)
                    if nf <= 2047 and band(r, 7) > 0 then
                        c.shadow, c.freq = nf, nf
                        snd.regs[0x13] = band(nf, 255)
                        snd.regs[0x14] = band(snd.regs[0x14], 0xF8) + rsh(nf, 8)
                        sweepCalc(c)
                    end
                end
            end
        end
        if step == 7 then
            for _, n in ipairs({ 1, 2, 4 }) do
                local c = snd.ch[n]
                if c.envPeriod ~= 0 then
                    c.envTimer = c.envTimer - 1
                    if c.envTimer <= 0 then
                        c.envTimer = c.envPeriod
                        if c.envUp and c.vol < 15 then c.vol = c.vol + 1
                        elseif not c.envUp and c.vol > 0 then c.vol = c.vol - 1 end
                    end
                end
            end
        end
    end

    -- the wave channel's shape, roughly: "tri", "saw" or "sq" (decided when the game changes it)
    local function waveShape()
        if not snd.waveDirty then return snd.shape end
        snd.waveDirty = false
        local s, distinct, nd = {}, {}, 0
        for k = 0, 15 do
            local b = snd.wave[k]
            s[k * 2 + 1], s[k * 2 + 2] = rsh(b, 4), band(b, 15)
        end
        for k = 1, 32 do if not distinct[s[k]] then distinct[s[k]] = true; nd = nd + 1 end end
        if nd <= 2 then snd.shape = "sq"; return "sq" end
        local changes, last = 0, 0
        for k = 2, 32 do
            local d = s[k] - s[k - 1]
            local sign = d > 0 and 1 or (d < 0 and -1 or 0)
            if sign ~= 0 then
                if last ~= 0 and sign ~= last then changes = changes + 1 end
                last = sign
            end
        end
        snd.shape = changes <= 2 and "saw" or "tri"
        return snd.shape
    end

    local function readIO(a)
        if a >= 0xFF10 and a < 0xFF40 then return sndRead(a - 0xFF00) end
        if a == 0xFF00 then
            local v = 0xC0 + joySel + 15
            if band(joySel, 0x10) == 0 then v = band(v, 0xF0 + dpad) end
            if band(joySel, 0x20) == 0 then v = band(v, 0xF0 + buttons) end
            return v
        elseif a == 0xFF04 then return div
        elseif a == 0xFF05 then return tima
        elseif a == 0xFF06 then return tma
        elseif a == 0xFF07 then return bor(tac, 0xF8)
        elseif a == 0xFF0F then return bor(IF, 0xE0)
        elseif a == 0xFF40 then return lcdc
        elseif a == 0xFF41 then
            local v = bor(band(stat, 0x78), 0x80) + mode
            if ly == lyc then v = v + 4 end
            return v
        elseif a == 0xFF42 then return scy
        elseif a == 0xFF43 then return scx
        elseif a == 0xFF44 then return ly
        elseif a == 0xFF45 then return lyc
        elseif a == 0xFF47 then return bgp
        elseif a == 0xFF48 then return obp0
        elseif a == 0xFF49 then return obp1
        elseif a == 0xFF4A then return wy
        elseif a == 0xFF4B then return wx
        elseif a == 0xFF01 then return sb
        end
        return io[a] or 0xFF
    end

    local function statIrq(bitMask)
        if band(stat, bitMask) ~= 0 then IF = bor(IF, 2) end
    end
    local function checkLyc()
        if ly == lyc then statIrq(0x40) end
    end

    local rb, wb

    local function writeIO(a, v)
        if a >= 0xFF10 and a < 0xFF40 then sndWrite(a - 0xFF00, v); return end
        if a == 0xFF00 then joySel = band(v, 0x30)
        elseif a == 0xFF01 then sb = v
        elseif a == 0xFF02 then
            if band(v, 0x81) == 0x81 then
                serialOut[#serialOut + 1] = char(sb)
                sb = 0xFF
                IF = bor(IF, 8)
            end
        elseif a == 0xFF04 then div = 0; divCount = 0
        elseif a == 0xFF05 then tima = v
        elseif a == 0xFF06 then tma = v
        elseif a == 0xFF07 then tac = band(v, 7)
        elseif a == 0xFF0F then IF = band(v, 0x1F)
        elseif a == 0xFF40 then
            local was = band(lcdc, 0x80) ~= 0
            lcdc = v
            local on = band(v, 0x80) ~= 0
            if was and not on then ly = 0; mode = 0; lineClock = 0
            elseif on and not was then ly = 0; mode = 2; lineClock = 0; winLine = 0; checkLyc() end
        elseif a == 0xFF41 then stat = band(v, 0x78)
        elseif a == 0xFF42 then scy = v
        elseif a == 0xFF43 then scx = v
        elseif a == 0xFF45 then lyc = v; if band(lcdc, 0x80) ~= 0 then checkLyc() end
        elseif a == 0xFF46 then
            local base = v * 256
            for k = 0, 159 do oam[k + 1] = rb(base + k) end
        elseif a == 0xFF47 then bgp = v
        elseif a == 0xFF48 then obp0 = v
        elseif a == 0xFF49 then obp1 = v
        elseif a == 0xFF4A then wy = v
        elseif a == 0xFF4B then wx = v
        elseif a ~= 0xFF44 then io[a] = v
        end
    end

    rb = function(a)
        if a < 0x4000 then return rom[a + rom0Off + 1]
        elseif a < 0x8000 then return rom[a - 0x4000 + romOff + 1]
        elseif a < 0xA000 then return vram[a - 0x7FFF]
        elseif a < 0xC000 then
            if not ramOn then return 0xFF end
            if mbc == "mbc3" and rtcSel >= 8 then return rtcRead() end
            if ramSize == 0 then return 0xFF end
            if mbc == "mbc2" then return bor(eram[band(a, 511) + 1], 0xF0) end
            return eram[(a - 0xA000 + ramOff) % ramSize + 1]
        elseif a < 0xE000 then return wram[a - 0xBFFF]
        elseif a < 0xFE00 then return wram[a - 0xDFFF]
        elseif a < 0xFEA0 then return oam[a - 0xFDFF]
        elseif a < 0xFF00 then return 0
        elseif a < 0xFF80 then return readIO(a)
        elseif a < 0xFFFF then return hram[a - 0xFF7F]
        end
        return IE
    end

    wb = function(a, v)
        if a < 0x8000 then mbcWrite(a, v)
        elseif a < 0xA000 then vram[a - 0x7FFF] = v
        elseif a < 0xC000 then
            if ramOn and ramSize > 0 and not (mbc == "mbc3" and rtcSel >= 8) then
                if mbc == "mbc2" then eram[band(a, 511) + 1] = band(v, 15)
                else eram[(a - 0xA000 + ramOff) % ramSize + 1] = v end
                dirty = true
            end
        elseif a < 0xE000 then wram[a - 0xBFFF] = v
        elseif a < 0xFE00 then wram[a - 0xDFFF] = v
        elseif a < 0xFEA0 then oam[a - 0xFDFF] = v
        elseif a < 0xFF00 then return
        elseif a < 0xFF80 then writeIO(a, v)
        elseif a < 0xFFFF then hram[a - 0xFF7F] = v
        else IE = v end
    end

    local function fetch()
        local v = rb(PC)
        PC = (PC + 1) % 65536
        return v
    end
    local function fetch16()
        local lo = fetch()
        return fetch() * 256 + lo
    end
    local function push16(v)
        SP = (SP + 65535) % 65536
        wb(SP, rsh(v, 8))
        SP = (SP + 65535) % 65536
        wb(SP, band(v, 255))
    end
    local function pop16()
        local lo = rb(SP)
        SP = (SP + 1) % 65536
        local hi = rb(SP)
        SP = (SP + 1) % 65536
        return hi * 256 + lo
    end
    local function getF() return fZ * 128 + fN * 64 + fH * 32 + fC * 16 end
    local function setF(v)
        fZ = band(v, 128) ~= 0 and 1 or 0
        fN = band(v, 64) ~= 0 and 1 or 0
        fH = band(v, 32) ~= 0 and 1 or 0
        fC = band(v, 16) ~= 0 and 1 or 0
    end

    -- ALU
    local function add8(v, c)
        local r = A + v + c
        fH = (band(A, 15) + band(v, 15) + c) > 15 and 1 or 0
        fC = r > 255 and 1 or 0
        A = band(r, 255)
        fZ = A == 0 and 1 or 0
        fN = 0
    end
    local function sub8(v, c, store)
        local r = A - v - c
        fH = (band(A, 15) - band(v, 15) - c) < 0 and 1 or 0
        fC = r < 0 and 1 or 0
        r = band(r + 256, 255)
        fZ = r == 0 and 1 or 0
        fN = 1
        if store then A = r end
    end
    local function and8(v) A = band(A, v); fZ = A == 0 and 1 or 0; fN = 0; fH = 1; fC = 0 end
    local function xor8(v) A = bxor(A, v); fZ = A == 0 and 1 or 0; fN = 0; fH = 0; fC = 0 end
    local function or8(v) A = bor(A, v); fZ = A == 0 and 1 or 0; fN = 0; fH = 0; fC = 0 end
    local function inc8(v)
        local r = band(v + 1, 255)
        fZ = r == 0 and 1 or 0; fN = 0; fH = band(v, 15) == 15 and 1 or 0
        return r
    end
    local function dec8(v)
        local r = band(v + 255, 255)
        fZ = r == 0 and 1 or 0; fN = 1; fH = band(v, 15) == 0 and 1 or 0
        return r
    end
    local function addHL(v)
        local hl = H * 256 + L
        local r = hl + v
        fN = 0
        fH = (band(hl, 0xFFF) + band(v, 0xFFF)) > 0xFFF and 1 or 0
        fC = r > 0xFFFF and 1 or 0
        r = r % 65536
        H = rsh(r, 8); L = band(r, 255)
    end
    local function spPlus(e)
        fZ = 0; fN = 0
        fH = (band(SP, 15) + band(e, 15)) > 15 and 1 or 0
        fC = (band(SP, 255) + e) > 255 and 1 or 0
        if e >= 128 then e = e - 256 end
        return (SP + e) % 65536
    end
    local function daa()
        local a = A
        if fN == 0 then
            if fC == 1 or a > 0x99 then a = a + 0x60; fC = 1 end
            if fH == 1 or band(a, 15) > 9 then a = a + 6 end
        else
            if fC == 1 then a = a - 0x60 end
            if fH == 1 then a = a - 6 end
        end
        A = band(a + 256, 255)
        fZ = A == 0 and 1 or 0
        fH = 0
    end
    local function doHalt()
        if not ime and band(band(IE, IF), 0x1F) ~= 0 then return end -- (the halt bug is not emulated)
        halted = true
    end

    -- CB shifts / rotates: return the new value and set flags
    local function rlc(v) fC = rsh(v, 7); v = band(v * 2 + fC, 255); fZ = v == 0 and 1 or 0; fN = 0; fH = 0; return v end
    local function rrc(v) fC = band(v, 1); v = rsh(v, 1) + fC * 128; fZ = v == 0 and 1 or 0; fN = 0; fH = 0; return v end
    local function rl(v) local c = rsh(v, 7); v = band(v * 2 + fC, 255); fC = c; fZ = v == 0 and 1 or 0; fN = 0; fH = 0; return v end
    local function rr(v) local c = band(v, 1); v = rsh(v, 1) + fC * 128; fC = c; fZ = v == 0 and 1 or 0; fN = 0; fH = 0; return v end
    local function sla(v) fC = rsh(v, 7); v = band(v * 2, 255); fZ = v == 0 and 1 or 0; fN = 0; fH = 0; return v end
    local function sra(v) fC = band(v, 1); v = rsh(v, 1) + band(v, 128); fZ = v == 0 and 1 or 0; fN = 0; fH = 0; return v end
    local function swap(v) v = band(v, 15) * 16 + rsh(v, 4); fZ = v == 0 and 1 or 0; fN = 0; fH = 0; fC = 0; return v end
    local function srl(v) fC = band(v, 1); v = rsh(v, 1); fZ = v == 0 and 1 or 0; fN = 0; fH = 0; return v end

    local ops, cb = {}, {}
    ops[64] = function()  return 4 end
    ops[65] = function() B = C return 4 end
    ops[66] = function() B = D return 4 end
    ops[67] = function() B = E return 4 end
    ops[68] = function() B = H return 4 end
    ops[69] = function() B = L return 4 end
    ops[70] = function() B = rb(H * 256 + L) return 8 end
    ops[71] = function() B = A return 4 end
    ops[72] = function() C = B return 4 end
    ops[73] = function()  return 4 end
    ops[74] = function() C = D return 4 end
    ops[75] = function() C = E return 4 end
    ops[76] = function() C = H return 4 end
    ops[77] = function() C = L return 4 end
    ops[78] = function() C = rb(H * 256 + L) return 8 end
    ops[79] = function() C = A return 4 end
    ops[80] = function() D = B return 4 end
    ops[81] = function() D = C return 4 end
    ops[82] = function()  return 4 end
    ops[83] = function() D = E return 4 end
    ops[84] = function() D = H return 4 end
    ops[85] = function() D = L return 4 end
    ops[86] = function() D = rb(H * 256 + L) return 8 end
    ops[87] = function() D = A return 4 end
    ops[88] = function() E = B return 4 end
    ops[89] = function() E = C return 4 end
    ops[90] = function() E = D return 4 end
    ops[91] = function()  return 4 end
    ops[92] = function() E = H return 4 end
    ops[93] = function() E = L return 4 end
    ops[94] = function() E = rb(H * 256 + L) return 8 end
    ops[95] = function() E = A return 4 end
    ops[96] = function() H = B return 4 end
    ops[97] = function() H = C return 4 end
    ops[98] = function() H = D return 4 end
    ops[99] = function() H = E return 4 end
    ops[100] = function()  return 4 end
    ops[101] = function() H = L return 4 end
    ops[102] = function() H = rb(H * 256 + L) return 8 end
    ops[103] = function() H = A return 4 end
    ops[104] = function() L = B return 4 end
    ops[105] = function() L = C return 4 end
    ops[106] = function() L = D return 4 end
    ops[107] = function() L = E return 4 end
    ops[108] = function() L = H return 4 end
    ops[109] = function()  return 4 end
    ops[110] = function() L = rb(H * 256 + L) return 8 end
    ops[111] = function() L = A return 4 end
    ops[112] = function() wb(H * 256 + L, B) return 8 end
    ops[113] = function() wb(H * 256 + L, C) return 8 end
    ops[114] = function() wb(H * 256 + L, D) return 8 end
    ops[115] = function() wb(H * 256 + L, E) return 8 end
    ops[116] = function() wb(H * 256 + L, H) return 8 end
    ops[117] = function() wb(H * 256 + L, L) return 8 end
    ops[118] = function() doHalt() return 4 end
    ops[119] = function() wb(H * 256 + L, A) return 8 end
    ops[120] = function() A = B return 4 end
    ops[121] = function() A = C return 4 end
    ops[122] = function() A = D return 4 end
    ops[123] = function() A = E return 4 end
    ops[124] = function() A = H return 4 end
    ops[125] = function() A = L return 4 end
    ops[126] = function() A = rb(H * 256 + L) return 8 end
    ops[127] = function()  return 4 end
    ops[128] = function() add8(B, 0) return 4 end
    ops[129] = function() add8(C, 0) return 4 end
    ops[130] = function() add8(D, 0) return 4 end
    ops[131] = function() add8(E, 0) return 4 end
    ops[132] = function() add8(H, 0) return 4 end
    ops[133] = function() add8(L, 0) return 4 end
    ops[134] = function() add8(rb(H * 256 + L), 0) return 8 end
    ops[135] = function() add8(A, 0) return 4 end
    ops[198] = function() add8(fetch(), 0) return 8 end
    ops[136] = function() add8(B, fC) return 4 end
    ops[137] = function() add8(C, fC) return 4 end
    ops[138] = function() add8(D, fC) return 4 end
    ops[139] = function() add8(E, fC) return 4 end
    ops[140] = function() add8(H, fC) return 4 end
    ops[141] = function() add8(L, fC) return 4 end
    ops[142] = function() add8(rb(H * 256 + L), fC) return 8 end
    ops[143] = function() add8(A, fC) return 4 end
    ops[206] = function() add8(fetch(), fC) return 8 end
    ops[144] = function() sub8(B, 0, true) return 4 end
    ops[145] = function() sub8(C, 0, true) return 4 end
    ops[146] = function() sub8(D, 0, true) return 4 end
    ops[147] = function() sub8(E, 0, true) return 4 end
    ops[148] = function() sub8(H, 0, true) return 4 end
    ops[149] = function() sub8(L, 0, true) return 4 end
    ops[150] = function() sub8(rb(H * 256 + L), 0, true) return 8 end
    ops[151] = function() sub8(A, 0, true) return 4 end
    ops[214] = function() sub8(fetch(), 0, true) return 8 end
    ops[152] = function() sub8(B, fC, true) return 4 end
    ops[153] = function() sub8(C, fC, true) return 4 end
    ops[154] = function() sub8(D, fC, true) return 4 end
    ops[155] = function() sub8(E, fC, true) return 4 end
    ops[156] = function() sub8(H, fC, true) return 4 end
    ops[157] = function() sub8(L, fC, true) return 4 end
    ops[158] = function() sub8(rb(H * 256 + L), fC, true) return 8 end
    ops[159] = function() sub8(A, fC, true) return 4 end
    ops[222] = function() sub8(fetch(), fC, true) return 8 end
    ops[160] = function() and8(B) return 4 end
    ops[161] = function() and8(C) return 4 end
    ops[162] = function() and8(D) return 4 end
    ops[163] = function() and8(E) return 4 end
    ops[164] = function() and8(H) return 4 end
    ops[165] = function() and8(L) return 4 end
    ops[166] = function() and8(rb(H * 256 + L)) return 8 end
    ops[167] = function() and8(A) return 4 end
    ops[230] = function() and8(fetch()) return 8 end
    ops[168] = function() xor8(B) return 4 end
    ops[169] = function() xor8(C) return 4 end
    ops[170] = function() xor8(D) return 4 end
    ops[171] = function() xor8(E) return 4 end
    ops[172] = function() xor8(H) return 4 end
    ops[173] = function() xor8(L) return 4 end
    ops[174] = function() xor8(rb(H * 256 + L)) return 8 end
    ops[175] = function() xor8(A) return 4 end
    ops[238] = function() xor8(fetch()) return 8 end
    ops[176] = function() or8(B) return 4 end
    ops[177] = function() or8(C) return 4 end
    ops[178] = function() or8(D) return 4 end
    ops[179] = function() or8(E) return 4 end
    ops[180] = function() or8(H) return 4 end
    ops[181] = function() or8(L) return 4 end
    ops[182] = function() or8(rb(H * 256 + L)) return 8 end
    ops[183] = function() or8(A) return 4 end
    ops[246] = function() or8(fetch()) return 8 end
    ops[184] = function() sub8(B, 0, false) return 4 end
    ops[185] = function() sub8(C, 0, false) return 4 end
    ops[186] = function() sub8(D, 0, false) return 4 end
    ops[187] = function() sub8(E, 0, false) return 4 end
    ops[188] = function() sub8(H, 0, false) return 4 end
    ops[189] = function() sub8(L, 0, false) return 4 end
    ops[190] = function() sub8(rb(H * 256 + L), 0, false) return 8 end
    ops[191] = function() sub8(A, 0, false) return 4 end
    ops[254] = function() sub8(fetch(), 0, false) return 8 end
    ops[4] = function() B = inc8(B) return 4 end
    ops[5] = function() B = dec8(B) return 4 end
    ops[6] = function() B = fetch() return 8 end
    ops[12] = function() C = inc8(C) return 4 end
    ops[13] = function() C = dec8(C) return 4 end
    ops[14] = function() C = fetch() return 8 end
    ops[20] = function() D = inc8(D) return 4 end
    ops[21] = function() D = dec8(D) return 4 end
    ops[22] = function() D = fetch() return 8 end
    ops[28] = function() E = inc8(E) return 4 end
    ops[29] = function() E = dec8(E) return 4 end
    ops[30] = function() E = fetch() return 8 end
    ops[36] = function() H = inc8(H) return 4 end
    ops[37] = function() H = dec8(H) return 4 end
    ops[38] = function() H = fetch() return 8 end
    ops[44] = function() L = inc8(L) return 4 end
    ops[45] = function() L = dec8(L) return 4 end
    ops[46] = function() L = fetch() return 8 end
    ops[52] = function() local a = H * 256 + L wb(a, inc8(rb(a))) return 12 end
    ops[53] = function() local a = H * 256 + L wb(a, dec8(rb(a))) return 12 end
    ops[54] = function() wb(H * 256 + L, fetch()) return 12 end
    ops[60] = function() A = inc8(A) return 4 end
    ops[61] = function() A = dec8(A) return 4 end
    ops[62] = function() A = fetch() return 8 end
    ops[1] = function() C = fetch() B = fetch() return 12 end
    ops[3] = function() local v = (B * 256 + C + 1) % 65536 B = rsh(v, 8) C = band(v, 255) return 8 end
    ops[11] = function() local v = (B * 256 + C + 65535) % 65536 B = rsh(v, 8) C = band(v, 255) return 8 end
    ops[9] = function() addHL(B * 256 + C) return 8 end
    ops[197] = function() push16(B * 256 + C) return 16 end
    ops[193] = function() local v = pop16() B = rsh(v, 8) C = band(v, 255) return 12 end
    ops[17] = function() E = fetch() D = fetch() return 12 end
    ops[19] = function() local v = (D * 256 + E + 1) % 65536 D = rsh(v, 8) E = band(v, 255) return 8 end
    ops[27] = function() local v = (D * 256 + E + 65535) % 65536 D = rsh(v, 8) E = band(v, 255) return 8 end
    ops[25] = function() addHL(D * 256 + E) return 8 end
    ops[213] = function() push16(D * 256 + E) return 16 end
    ops[209] = function() local v = pop16() D = rsh(v, 8) E = band(v, 255) return 12 end
    ops[33] = function() L = fetch() H = fetch() return 12 end
    ops[35] = function() local v = (H * 256 + L + 1) % 65536 H = rsh(v, 8) L = band(v, 255) return 8 end
    ops[43] = function() local v = (H * 256 + L + 65535) % 65536 H = rsh(v, 8) L = band(v, 255) return 8 end
    ops[41] = function() addHL(H * 256 + L) return 8 end
    ops[229] = function() push16(H * 256 + L) return 16 end
    ops[225] = function() local v = pop16() H = rsh(v, 8) L = band(v, 255) return 12 end
    ops[49] = function() SP = fetch16() return 12 end
    ops[51] = function() SP = (SP + 1) % 65536 return 8 end
    ops[59] = function() SP = (SP + 65535) % 65536 return 8 end
    ops[57] = function() addHL(SP) return 8 end
    ops[245] = function() push16(A * 256 + getF()) return 16 end
    ops[241] = function() local v = pop16() A = rsh(v, 8) setF(band(v, 255)) return 12 end
    ops[2] = function() wb(B * 256 + C, A) return 8 end
    ops[18] = function() wb(D * 256 + E, A) return 8 end
    ops[10] = function() A = rb(B * 256 + C) return 8 end
    ops[26] = function() A = rb(D * 256 + E) return 8 end
    ops[34] = function() local a = H * 256 + L wb(a, A) a = (a + 1) % 65536 H = rsh(a, 8) L = band(a, 255) return 8 end
    ops[50] = function() local a = H * 256 + L wb(a, A) a = (a + 65535) % 65536 H = rsh(a, 8) L = band(a, 255) return 8 end
    ops[42] = function() local a = H * 256 + L A = rb(a) a = (a + 1) % 65536 H = rsh(a, 8) L = band(a, 255) return 8 end
    ops[58] = function() local a = H * 256 + L A = rb(a) a = (a + 65535) % 65536 H = rsh(a, 8) L = band(a, 255) return 8 end
    ops[8] = function() local a = fetch16() wb(a, band(SP, 255)) wb((a + 1) % 65536, rsh(SP, 8)) return 20 end
    ops[234] = function() wb(fetch16(), A) return 16 end
    ops[250] = function() A = rb(fetch16()) return 16 end
    ops[224] = function() wb(0xFF00 + fetch(), A) return 12 end
    ops[240] = function() A = rb(0xFF00 + fetch()) return 12 end
    ops[226] = function() wb(0xFF00 + C, A) return 8 end
    ops[242] = function() A = rb(0xFF00 + C) return 8 end
    ops[249] = function() SP = H * 256 + L return 8 end
    ops[232] = function() SP = spPlus(fetch()) return 16 end
    ops[248] = function() local v = spPlus(fetch()) H = rsh(v, 8) L = band(v, 255) return 12 end
    ops[7] = function() fC = rsh(A, 7) A = band(A * 2 + fC, 255) fZ = 0 fN = 0 fH = 0 return 4 end
    ops[15] = function() fC = band(A, 1) A = rsh(A, 1) + fC * 128 fZ = 0 fN = 0 fH = 0 return 4 end
    ops[23] = function() local c = rsh(A, 7) A = band(A * 2 + fC, 255) fC = c fZ = 0 fN = 0 fH = 0 return 4 end
    ops[31] = function() local c = band(A, 1) A = rsh(A, 1) + fC * 128 fC = c fZ = 0 fN = 0 fH = 0 return 4 end
    ops[39] = function() daa() return 4 end
    ops[47] = function() A = bxor(A, 255) fN = 1 fH = 1 return 4 end
    ops[55] = function() fN = 0 fH = 0 fC = 1 return 4 end
    ops[63] = function() fN = 0 fH = 0 fC = 1 - fC return 4 end
    ops[0] = function()  return 4 end
    ops[16] = function() fetch() return 4 end
    ops[243] = function() ime = false eiDelay = false return 4 end
    ops[251] = function() eiDelay = true return 4 end
    ops[24] = function() local e = fetch() if e >= 128 then e = e - 256 end PC = (PC + e) % 65536 return 12 end
    ops[195] = function() PC = fetch16() return 16 end
    ops[233] = function() PC = H * 256 + L return 4 end
    ops[205] = function() local a = fetch16() push16(PC) PC = a return 24 end
    ops[201] = function() PC = pop16() return 16 end
    ops[217] = function() PC = pop16() ime = true return 16 end
    ops[32] = function() local e = fetch() if fZ == 0 then if e >= 128 then e = e - 256 end PC = (PC + e) % 65536 return 12 end return 8 end
    ops[194] = function() local a = fetch16() if fZ == 0 then PC = a return 16 end return 12 end
    ops[196] = function() local a = fetch16() if fZ == 0 then push16(PC) PC = a return 24 end return 12 end
    ops[192] = function() if fZ == 0 then PC = pop16() return 20 end return 8 end
    ops[40] = function() local e = fetch() if fZ == 1 then if e >= 128 then e = e - 256 end PC = (PC + e) % 65536 return 12 end return 8 end
    ops[202] = function() local a = fetch16() if fZ == 1 then PC = a return 16 end return 12 end
    ops[204] = function() local a = fetch16() if fZ == 1 then push16(PC) PC = a return 24 end return 12 end
    ops[200] = function() if fZ == 1 then PC = pop16() return 20 end return 8 end
    ops[48] = function() local e = fetch() if fC == 0 then if e >= 128 then e = e - 256 end PC = (PC + e) % 65536 return 12 end return 8 end
    ops[210] = function() local a = fetch16() if fC == 0 then PC = a return 16 end return 12 end
    ops[212] = function() local a = fetch16() if fC == 0 then push16(PC) PC = a return 24 end return 12 end
    ops[208] = function() if fC == 0 then PC = pop16() return 20 end return 8 end
    ops[56] = function() local e = fetch() if fC == 1 then if e >= 128 then e = e - 256 end PC = (PC + e) % 65536 return 12 end return 8 end
    ops[218] = function() local a = fetch16() if fC == 1 then PC = a return 16 end return 12 end
    ops[220] = function() local a = fetch16() if fC == 1 then push16(PC) PC = a return 24 end return 12 end
    ops[216] = function() if fC == 1 then PC = pop16() return 20 end return 8 end
    ops[199] = function() push16(PC) PC = 0 return 16 end
    ops[207] = function() push16(PC) PC = 8 return 16 end
    ops[215] = function() push16(PC) PC = 16 return 16 end
    ops[223] = function() push16(PC) PC = 24 return 16 end
    ops[231] = function() push16(PC) PC = 32 return 16 end
    ops[239] = function() push16(PC) PC = 40 return 16 end
    ops[247] = function() push16(PC) PC = 48 return 16 end
    ops[255] = function() push16(PC) PC = 56 return 16 end
    ops[203] = function() return cb[fetch()]() end
    ops[211] = function()  return 4 end
    ops[219] = function()  return 4 end
    ops[221] = function()  return 4 end
    ops[227] = function()  return 4 end
    ops[228] = function()  return 4 end
    ops[235] = function()  return 4 end
    ops[236] = function()  return 4 end
    ops[237] = function()  return 4 end
    ops[244] = function()  return 4 end
    ops[252] = function()  return 4 end
    ops[253] = function()  return 4 end
    cb[0] = function() B = rlc(B) return 8 end
    cb[1] = function() C = rlc(C) return 8 end
    cb[2] = function() D = rlc(D) return 8 end
    cb[3] = function() E = rlc(E) return 8 end
    cb[4] = function() H = rlc(H) return 8 end
    cb[5] = function() L = rlc(L) return 8 end
    cb[6] = function() local a = H * 256 + L wb(a, rlc(rb(a))) return 16 end
    cb[7] = function() A = rlc(A) return 8 end
    cb[8] = function() B = rrc(B) return 8 end
    cb[9] = function() C = rrc(C) return 8 end
    cb[10] = function() D = rrc(D) return 8 end
    cb[11] = function() E = rrc(E) return 8 end
    cb[12] = function() H = rrc(H) return 8 end
    cb[13] = function() L = rrc(L) return 8 end
    cb[14] = function() local a = H * 256 + L wb(a, rrc(rb(a))) return 16 end
    cb[15] = function() A = rrc(A) return 8 end
    cb[16] = function() B = rl(B) return 8 end
    cb[17] = function() C = rl(C) return 8 end
    cb[18] = function() D = rl(D) return 8 end
    cb[19] = function() E = rl(E) return 8 end
    cb[20] = function() H = rl(H) return 8 end
    cb[21] = function() L = rl(L) return 8 end
    cb[22] = function() local a = H * 256 + L wb(a, rl(rb(a))) return 16 end
    cb[23] = function() A = rl(A) return 8 end
    cb[24] = function() B = rr(B) return 8 end
    cb[25] = function() C = rr(C) return 8 end
    cb[26] = function() D = rr(D) return 8 end
    cb[27] = function() E = rr(E) return 8 end
    cb[28] = function() H = rr(H) return 8 end
    cb[29] = function() L = rr(L) return 8 end
    cb[30] = function() local a = H * 256 + L wb(a, rr(rb(a))) return 16 end
    cb[31] = function() A = rr(A) return 8 end
    cb[32] = function() B = sla(B) return 8 end
    cb[33] = function() C = sla(C) return 8 end
    cb[34] = function() D = sla(D) return 8 end
    cb[35] = function() E = sla(E) return 8 end
    cb[36] = function() H = sla(H) return 8 end
    cb[37] = function() L = sla(L) return 8 end
    cb[38] = function() local a = H * 256 + L wb(a, sla(rb(a))) return 16 end
    cb[39] = function() A = sla(A) return 8 end
    cb[40] = function() B = sra(B) return 8 end
    cb[41] = function() C = sra(C) return 8 end
    cb[42] = function() D = sra(D) return 8 end
    cb[43] = function() E = sra(E) return 8 end
    cb[44] = function() H = sra(H) return 8 end
    cb[45] = function() L = sra(L) return 8 end
    cb[46] = function() local a = H * 256 + L wb(a, sra(rb(a))) return 16 end
    cb[47] = function() A = sra(A) return 8 end
    cb[48] = function() B = swap(B) return 8 end
    cb[49] = function() C = swap(C) return 8 end
    cb[50] = function() D = swap(D) return 8 end
    cb[51] = function() E = swap(E) return 8 end
    cb[52] = function() H = swap(H) return 8 end
    cb[53] = function() L = swap(L) return 8 end
    cb[54] = function() local a = H * 256 + L wb(a, swap(rb(a))) return 16 end
    cb[55] = function() A = swap(A) return 8 end
    cb[56] = function() B = srl(B) return 8 end
    cb[57] = function() C = srl(C) return 8 end
    cb[58] = function() D = srl(D) return 8 end
    cb[59] = function() E = srl(E) return 8 end
    cb[60] = function() H = srl(H) return 8 end
    cb[61] = function() L = srl(L) return 8 end
    cb[62] = function() local a = H * 256 + L wb(a, srl(rb(a))) return 16 end
    cb[63] = function() A = srl(A) return 8 end
    cb[64] = function() fZ = band(B, 1) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[128] = function() B = band(B, 254) return 8 end
    cb[192] = function() B = bor(B, 1) return 8 end
    cb[65] = function() fZ = band(C, 1) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[129] = function() C = band(C, 254) return 8 end
    cb[193] = function() C = bor(C, 1) return 8 end
    cb[66] = function() fZ = band(D, 1) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[130] = function() D = band(D, 254) return 8 end
    cb[194] = function() D = bor(D, 1) return 8 end
    cb[67] = function() fZ = band(E, 1) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[131] = function() E = band(E, 254) return 8 end
    cb[195] = function() E = bor(E, 1) return 8 end
    cb[68] = function() fZ = band(H, 1) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[132] = function() H = band(H, 254) return 8 end
    cb[196] = function() H = bor(H, 1) return 8 end
    cb[69] = function() fZ = band(L, 1) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[133] = function() L = band(L, 254) return 8 end
    cb[197] = function() L = bor(L, 1) return 8 end
    cb[70] = function() fZ = band(rb(H * 256 + L), 1) == 0 and 1 or 0 fN = 0 fH = 1 return 12 end
    cb[134] = function() local a = H * 256 + L wb(a, band(rb(a), 254)) return 16 end
    cb[198] = function() local a = H * 256 + L wb(a, bor(rb(a), 1)) return 16 end
    cb[71] = function() fZ = band(A, 1) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[135] = function() A = band(A, 254) return 8 end
    cb[199] = function() A = bor(A, 1) return 8 end
    cb[72] = function() fZ = band(B, 2) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[136] = function() B = band(B, 253) return 8 end
    cb[200] = function() B = bor(B, 2) return 8 end
    cb[73] = function() fZ = band(C, 2) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[137] = function() C = band(C, 253) return 8 end
    cb[201] = function() C = bor(C, 2) return 8 end
    cb[74] = function() fZ = band(D, 2) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[138] = function() D = band(D, 253) return 8 end
    cb[202] = function() D = bor(D, 2) return 8 end
    cb[75] = function() fZ = band(E, 2) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[139] = function() E = band(E, 253) return 8 end
    cb[203] = function() E = bor(E, 2) return 8 end
    cb[76] = function() fZ = band(H, 2) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[140] = function() H = band(H, 253) return 8 end
    cb[204] = function() H = bor(H, 2) return 8 end
    cb[77] = function() fZ = band(L, 2) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[141] = function() L = band(L, 253) return 8 end
    cb[205] = function() L = bor(L, 2) return 8 end
    cb[78] = function() fZ = band(rb(H * 256 + L), 2) == 0 and 1 or 0 fN = 0 fH = 1 return 12 end
    cb[142] = function() local a = H * 256 + L wb(a, band(rb(a), 253)) return 16 end
    cb[206] = function() local a = H * 256 + L wb(a, bor(rb(a), 2)) return 16 end
    cb[79] = function() fZ = band(A, 2) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[143] = function() A = band(A, 253) return 8 end
    cb[207] = function() A = bor(A, 2) return 8 end
    cb[80] = function() fZ = band(B, 4) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[144] = function() B = band(B, 251) return 8 end
    cb[208] = function() B = bor(B, 4) return 8 end
    cb[81] = function() fZ = band(C, 4) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[145] = function() C = band(C, 251) return 8 end
    cb[209] = function() C = bor(C, 4) return 8 end
    cb[82] = function() fZ = band(D, 4) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[146] = function() D = band(D, 251) return 8 end
    cb[210] = function() D = bor(D, 4) return 8 end
    cb[83] = function() fZ = band(E, 4) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[147] = function() E = band(E, 251) return 8 end
    cb[211] = function() E = bor(E, 4) return 8 end
    cb[84] = function() fZ = band(H, 4) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[148] = function() H = band(H, 251) return 8 end
    cb[212] = function() H = bor(H, 4) return 8 end
    cb[85] = function() fZ = band(L, 4) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[149] = function() L = band(L, 251) return 8 end
    cb[213] = function() L = bor(L, 4) return 8 end
    cb[86] = function() fZ = band(rb(H * 256 + L), 4) == 0 and 1 or 0 fN = 0 fH = 1 return 12 end
    cb[150] = function() local a = H * 256 + L wb(a, band(rb(a), 251)) return 16 end
    cb[214] = function() local a = H * 256 + L wb(a, bor(rb(a), 4)) return 16 end
    cb[87] = function() fZ = band(A, 4) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[151] = function() A = band(A, 251) return 8 end
    cb[215] = function() A = bor(A, 4) return 8 end
    cb[88] = function() fZ = band(B, 8) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[152] = function() B = band(B, 247) return 8 end
    cb[216] = function() B = bor(B, 8) return 8 end
    cb[89] = function() fZ = band(C, 8) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[153] = function() C = band(C, 247) return 8 end
    cb[217] = function() C = bor(C, 8) return 8 end
    cb[90] = function() fZ = band(D, 8) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[154] = function() D = band(D, 247) return 8 end
    cb[218] = function() D = bor(D, 8) return 8 end
    cb[91] = function() fZ = band(E, 8) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[155] = function() E = band(E, 247) return 8 end
    cb[219] = function() E = bor(E, 8) return 8 end
    cb[92] = function() fZ = band(H, 8) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[156] = function() H = band(H, 247) return 8 end
    cb[220] = function() H = bor(H, 8) return 8 end
    cb[93] = function() fZ = band(L, 8) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[157] = function() L = band(L, 247) return 8 end
    cb[221] = function() L = bor(L, 8) return 8 end
    cb[94] = function() fZ = band(rb(H * 256 + L), 8) == 0 and 1 or 0 fN = 0 fH = 1 return 12 end
    cb[158] = function() local a = H * 256 + L wb(a, band(rb(a), 247)) return 16 end
    cb[222] = function() local a = H * 256 + L wb(a, bor(rb(a), 8)) return 16 end
    cb[95] = function() fZ = band(A, 8) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[159] = function() A = band(A, 247) return 8 end
    cb[223] = function() A = bor(A, 8) return 8 end
    cb[96] = function() fZ = band(B, 16) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[160] = function() B = band(B, 239) return 8 end
    cb[224] = function() B = bor(B, 16) return 8 end
    cb[97] = function() fZ = band(C, 16) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[161] = function() C = band(C, 239) return 8 end
    cb[225] = function() C = bor(C, 16) return 8 end
    cb[98] = function() fZ = band(D, 16) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[162] = function() D = band(D, 239) return 8 end
    cb[226] = function() D = bor(D, 16) return 8 end
    cb[99] = function() fZ = band(E, 16) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[163] = function() E = band(E, 239) return 8 end
    cb[227] = function() E = bor(E, 16) return 8 end
    cb[100] = function() fZ = band(H, 16) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[164] = function() H = band(H, 239) return 8 end
    cb[228] = function() H = bor(H, 16) return 8 end
    cb[101] = function() fZ = band(L, 16) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[165] = function() L = band(L, 239) return 8 end
    cb[229] = function() L = bor(L, 16) return 8 end
    cb[102] = function() fZ = band(rb(H * 256 + L), 16) == 0 and 1 or 0 fN = 0 fH = 1 return 12 end
    cb[166] = function() local a = H * 256 + L wb(a, band(rb(a), 239)) return 16 end
    cb[230] = function() local a = H * 256 + L wb(a, bor(rb(a), 16)) return 16 end
    cb[103] = function() fZ = band(A, 16) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[167] = function() A = band(A, 239) return 8 end
    cb[231] = function() A = bor(A, 16) return 8 end
    cb[104] = function() fZ = band(B, 32) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[168] = function() B = band(B, 223) return 8 end
    cb[232] = function() B = bor(B, 32) return 8 end
    cb[105] = function() fZ = band(C, 32) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[169] = function() C = band(C, 223) return 8 end
    cb[233] = function() C = bor(C, 32) return 8 end
    cb[106] = function() fZ = band(D, 32) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[170] = function() D = band(D, 223) return 8 end
    cb[234] = function() D = bor(D, 32) return 8 end
    cb[107] = function() fZ = band(E, 32) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[171] = function() E = band(E, 223) return 8 end
    cb[235] = function() E = bor(E, 32) return 8 end
    cb[108] = function() fZ = band(H, 32) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[172] = function() H = band(H, 223) return 8 end
    cb[236] = function() H = bor(H, 32) return 8 end
    cb[109] = function() fZ = band(L, 32) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[173] = function() L = band(L, 223) return 8 end
    cb[237] = function() L = bor(L, 32) return 8 end
    cb[110] = function() fZ = band(rb(H * 256 + L), 32) == 0 and 1 or 0 fN = 0 fH = 1 return 12 end
    cb[174] = function() local a = H * 256 + L wb(a, band(rb(a), 223)) return 16 end
    cb[238] = function() local a = H * 256 + L wb(a, bor(rb(a), 32)) return 16 end
    cb[111] = function() fZ = band(A, 32) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[175] = function() A = band(A, 223) return 8 end
    cb[239] = function() A = bor(A, 32) return 8 end
    cb[112] = function() fZ = band(B, 64) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[176] = function() B = band(B, 191) return 8 end
    cb[240] = function() B = bor(B, 64) return 8 end
    cb[113] = function() fZ = band(C, 64) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[177] = function() C = band(C, 191) return 8 end
    cb[241] = function() C = bor(C, 64) return 8 end
    cb[114] = function() fZ = band(D, 64) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[178] = function() D = band(D, 191) return 8 end
    cb[242] = function() D = bor(D, 64) return 8 end
    cb[115] = function() fZ = band(E, 64) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[179] = function() E = band(E, 191) return 8 end
    cb[243] = function() E = bor(E, 64) return 8 end
    cb[116] = function() fZ = band(H, 64) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[180] = function() H = band(H, 191) return 8 end
    cb[244] = function() H = bor(H, 64) return 8 end
    cb[117] = function() fZ = band(L, 64) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[181] = function() L = band(L, 191) return 8 end
    cb[245] = function() L = bor(L, 64) return 8 end
    cb[118] = function() fZ = band(rb(H * 256 + L), 64) == 0 and 1 or 0 fN = 0 fH = 1 return 12 end
    cb[182] = function() local a = H * 256 + L wb(a, band(rb(a), 191)) return 16 end
    cb[246] = function() local a = H * 256 + L wb(a, bor(rb(a), 64)) return 16 end
    cb[119] = function() fZ = band(A, 64) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[183] = function() A = band(A, 191) return 8 end
    cb[247] = function() A = bor(A, 64) return 8 end
    cb[120] = function() fZ = band(B, 128) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[184] = function() B = band(B, 127) return 8 end
    cb[248] = function() B = bor(B, 128) return 8 end
    cb[121] = function() fZ = band(C, 128) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[185] = function() C = band(C, 127) return 8 end
    cb[249] = function() C = bor(C, 128) return 8 end
    cb[122] = function() fZ = band(D, 128) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[186] = function() D = band(D, 127) return 8 end
    cb[250] = function() D = bor(D, 128) return 8 end
    cb[123] = function() fZ = band(E, 128) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[187] = function() E = band(E, 127) return 8 end
    cb[251] = function() E = bor(E, 128) return 8 end
    cb[124] = function() fZ = band(H, 128) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[188] = function() H = band(H, 127) return 8 end
    cb[252] = function() H = bor(H, 128) return 8 end
    cb[125] = function() fZ = band(L, 128) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[189] = function() L = band(L, 127) return 8 end
    cb[253] = function() L = bor(L, 128) return 8 end
    cb[126] = function() fZ = band(rb(H * 256 + L), 128) == 0 and 1 or 0 fN = 0 fH = 1 return 12 end
    cb[190] = function() local a = H * 256 + L wb(a, band(rb(a), 127)) return 16 end
    cb[254] = function() local a = H * 256 + L wb(a, bor(rb(a), 128)) return 16 end
    cb[127] = function() fZ = band(A, 128) == 0 and 1 or 0 fN = 0 fH = 1 return 8 end
    cb[191] = function() A = band(A, 127) return 8 end
    cb[255] = function() A = bor(A, 128) return 8 end

    -- one scanline into fb (background, window, sprites)
    local function renderLine()
        local row = ly * 160
        if band(lcdc, 1) ~= 0 then
            local mapBase = band(lcdc, 8) ~= 0 and 0x1C00 or 0x1800
            local unsignedTiles = band(lcdc, 16) ~= 0
            local y = (ly + scy) % 256
            local tileRow = rsh(y, 3) * 32
            local lineInTile = band(y, 7) * 2
            local pal = linePal
            pal[0], pal[1], pal[2], pal[3] = band(bgp, 3), band(rsh(bgp, 2), 3), band(rsh(bgp, 4), 3), rsh(bgp, 6)
            local x = 0
            local sx = scx
            while x < 160 do
                local mx = (sx + x) % 256
                local tile = vram[mapBase + tileRow + rsh(mx, 3) + 1]
                local addr
                if unsignedTiles then addr = tile * 16 else if tile >= 128 then tile = tile - 256 end addr = 0x1000 + tile * 16 end
                local lo, hi = BITS[vram[addr + lineInTile + 1]], BITS[vram[addr + lineInTile + 2]]
                local px = band(mx, 7) + 1
                while px <= 8 and x < 160 do
                    local ci = lo[px] + hi[px] * 2
                    bgIdx[x] = ci
                    fb[row + x + 1] = pal[ci]
                    x = x + 1
                    px = px + 1
                end
            end
            -- window
            if band(lcdc, 32) ~= 0 and ly >= wy and wx <= 166 then
                local wmap = band(lcdc, 64) ~= 0 and 0x1C00 or 0x1800
                local wyLine = winLine
                local trow = rsh(wyLine, 3) * 32
                local lit = band(wyLine, 7) * 2
                local startX = wx - 7
                local drew = false
                for xx = math.max(0, startX), 159 do
                    local wxp = xx - startX
                    local tile = vram[wmap + trow + rsh(wxp, 3) + 1]
                    local addr
                    if unsignedTiles then addr = tile * 16 else if tile >= 128 then tile = tile - 256 end addr = 0x1000 + tile * 16 end
                    local px = band(wxp, 7) + 1
                    local ci = BITS[vram[addr + lit + 1]][px] + BITS[vram[addr + lit + 2]][px] * 2
                    bgIdx[xx] = ci
                    fb[row + xx + 1] = pal[ci]
                    drew = true
                end
                if drew then winLine = winLine + 1 end
            end
        else
            for x = 0, 159 do bgIdx[x] = 0; fb[row + x + 1] = 0 end
        end
        -- sprites: the first 10 on this line in OAM order; lower X wins, then OAM order
        if band(lcdc, 2) ~= 0 then
            local tall = band(lcdc, 4) ~= 0
            local hgt = tall and 16 or 8
            local list, count = {}, 0
            for s = 0, 39 do
                local o = s * 4 + 1
                local sy = oam[o] - 16
                if ly >= sy and ly < sy + hgt then
                    count = count + 1
                    list[count] = o
                    if count == 10 then break end
                end
            end
            -- draw lowest priority first: higher X, then later in OAM
            table.sort(list, function(p, q)
                local xp, xq = oam[p + 1], oam[q + 1]
                if xp ~= xq then return xp > xq end
                return p > q
            end)
            for k = 1, count do
                local o = list[k]
                local sy, sx, tile, attr = oam[o] - 16, oam[o + 1] - 8, oam[o + 2], oam[o + 3]
                if tall then tile = band(tile, 0xFE) end
                local line = ly - sy
                if band(attr, 64) ~= 0 then line = hgt - 1 - line end
                local addr = tile * 16 + line * 2
                local set = band(attr, 32) ~= 0 and BITSF or BITS
                local lo, hi = set[vram[addr + 1]], set[vram[addr + 2]]
                local pal = band(attr, 16) ~= 0 and obp1 or obp0
                local behind = band(attr, 128) ~= 0
                for px = 1, 8 do
                    local x = sx + px - 1
                    if x >= 0 and x < 160 then
                        local ci = lo[px] + hi[px] * 2
                        if ci ~= 0 and (not behind or bgIdx[x] == 0) then
                            fb[row + x + 1] = band(rsh(pal, ci * 2), 3)
                        end
                    end
                end
            end
        end
    end

    local emu = { fb = fb, title = title, battery = battery and ramSize > 0, mbc = mbc }

    -- runs one frame; returns the clock cycles it took
    function emu.runFrame()
        frameDone = false
        local total = 0
        while not frameDone and total < 70224 do
            local cyc
            local pending = band(band(IE, IF), 0x1F)
            if halted and pending ~= 0 then halted = false end
            if ime and pending ~= 0 then
                ime = false
                local bitN = 0
                while band(pending, 1) == 0 do pending = rsh(pending, 1); bitN = bitN + 1 end
                IF = band(IF, 255 - IRQ_BIT[bitN])
                push16(PC)
                PC = 0x40 + bitN * 8
                cyc = 20
            elseif halted then
                cyc = 4
            else
                local enable = eiDelay
                eiDelay = false
                cyc = ops[fetch()]()
                if enable then ime = true end
            end
            total = total + cyc

            -- sound sequencer (512 Hz)
            local sc = snd.seqCount + cyc
            if sc >= 8192 then sc = sc - 8192; sndStep() end
            snd.seqCount = sc

            -- timer
            divCount = divCount + cyc
            while divCount >= 256 do divCount = divCount - 256; div = (div + 1) % 256 end
            if band(tac, 4) ~= 0 then
                timerCount = timerCount + cyc
                local period = TIMER_PERIOD[band(tac, 3)]
                while timerCount >= period do
                    timerCount = timerCount - period
                    tima = tima + 1
                    if tima > 255 then tima = tma; IF = bor(IF, 4) end
                end
            end

            -- video: mode 2 (80) -> 3 (172) -> 0 (204) per line, lines 144-153 = mode 1
            if band(lcdc, 0x80) ~= 0 then
                lineClock = lineClock + cyc
                local again = true
                while again do
                    again = false
                    if mode == 2 then
                        if lineClock >= 80 then lineClock = lineClock - 80; mode = 3; again = true end
                    elseif mode == 3 then
                        if lineClock >= 172 then lineClock = lineClock - 172; mode = 0; renderLine(); statIrq(0x08); again = true end
                    elseif mode == 0 then
                        if lineClock >= 204 then
                            lineClock = lineClock - 204
                            ly = ly + 1
                            checkLyc()
                            if ly == 144 then
                                mode = 1
                                IF = bor(IF, 1)
                                statIrq(0x10)
                                frameDone = true
                            else
                                mode = 2
                                statIrq(0x20)
                            end
                            again = true
                        end
                    else
                        if lineClock >= 456 then
                            lineClock = lineClock - 456
                            ly = ly + 1
                            if ly > 153 then
                                ly = 0
                                winLine = 0
                                mode = 2
                                statIrq(0x20)
                            end
                            checkLyc()
                            again = true
                        end
                    end
                end
            end
        end
        return total
    end

    local BUTTON = { right = { 1, true }, left = { 2, true }, up = { 4, true }, down = { 8, true },
        a = { 1, false }, b = { 2, false }, select = { 4, false }, start = { 8, false } }
    function emu.setButton(name, down)
        local def = BUTTON[name]
        if not def then return end
        local m, isPad = def[1], def[2]
        if isPad then
            local before = dpad
            dpad = down and band(dpad, 15 - m) or bor(dpad, m)
            if before ~= dpad and down then IF = bor(IF, 16) end
        else
            local before = buttons
            buttons = down and band(buttons, 15 - m) or bor(buttons, m)
            if before ~= buttons and down then IF = bor(IF, 16) end
        end
    end

    function emu.saveData()
        if ramSize == 0 then return nil end
        local parts = {}
        for k = 1, ramSize, 1024 do
            local t = {}
            for j = k, math.min(ramSize, k + 1023) do t[#t + 1] = eram[j] end
            parts[#parts + 1] = char(table.unpack(t))
        end
        return concat(parts)
    end
    -- emu.audio(): { power, master (0..1), c = { [1..4] = { on, freq (Hz), vol (0..1), duty (0-3) | shape | short } } }
    local snap = { c = { {}, {}, {}, {} } }
    local WAVE_VOL = { [0] = 0, [1] = 1, [2] = 0.5, [3] = 0.25 }
    local NOISE_DIV = { [0] = 0.5, 1, 2, 3, 4, 5, 6, 7 }
    function emu.audio()
        local r = snd.regs
        snap.power = snd.power
        snap.master = (band(rsh(r[0x24], 4), 7) + band(r[0x24], 7) + 2) / 16
        local pan = r[0x25]
        for n = 1, 4 do
            local c, s = snd.ch[n], snap.c[n]
            s.on = snd.power and c.on and c.dac and band(pan, IRQ_BIT[n - 1] + IRQ_BIT[n - 1] * 16) ~= 0
            if n <= 2 then
                s.freq = 131072 / (2048 - c.freq)
                s.vol = c.vol / 15
                s.duty = c.duty
            elseif n == 3 then
                s.freq = 65536 / (2048 - c.freq)
                s.vol = WAVE_VOL[c.volCode]
                s.shape = waveShape()
            else
                local nr = r[0x22]
                s.freq = 524288 / NOISE_DIV[band(nr, 7)] / 2 ^ (rsh(nr, 4) + 1)
                s.vol = c.vol / 15
                s.short = band(nr, 8) ~= 0
            end
            if s.vol <= 0 then s.on = false end
        end
        return snap
    end

    function emu.dirty() return dirty end
    function emu.clearDirty() dirty = false end
    function emu.serial() return concat(serialOut) end
    function emu.pc() return PC end

    mapBanks()
    return emu
end

return GB

end)()
local Zip = (function()
-- .zip reading for the Game Boy tab: finds the first .gb / .gbc file and
-- unpacks it (stored or deflate). Zip.extract(zipString) -> romString, name | nil, error
local Zip = {}
do
    local band, rsh, lsh = bit32.band, bit32.rshift, bit32.lshift
    local byte, char, concat = string.byte, string.char, table.concat

    local function u16(s, p) local a, b = byte(s, p, p + 1); return a + b * 256 end
    local function u32(s, p) local a, b, c, d = byte(s, p, p + 3); return a + b * 256 + c * 65536 + d * 16777216 end

    -- Huffman table from code lengths: counts / symbols (canonical, as in zlib's puff)
    local function buildHuff(lengths, n)
        local count, sym, offs = {}, {}, {}
        for i = 0, 15 do count[i] = 0 end
        for i = 0, n - 1 do count[lengths[i] or 0] = count[lengths[i] or 0] + 1 end
        offs[1] = 0
        for i = 1, 14 do offs[i + 1] = offs[i] + count[i] end
        for i = 0, n - 1 do
            local l = lengths[i] or 0
            if l ~= 0 then sym[offs[l]] = i; offs[l] = offs[l] + 1 end
        end
        return { count = count, sym = sym }
    end

    local LBASE = { [0] = 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
    local LEXT = { [0] = 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
    local DBASE = { [0] = 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
        4097, 6145, 8193, 12289, 16385, 24577 }
    local DEXT = { [0] = 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
    local ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

    local fixedL, fixedD
    local function fixed()
        if fixedL then return fixedL, fixedD end
        local l = {}
        for i = 0, 143 do l[i] = 8 end
        for i = 144, 255 do l[i] = 9 end
        for i = 256, 279 do l[i] = 7 end
        for i = 280, 287 do l[i] = 8 end
        fixedL = buildHuff(l, 288)
        local d = {}
        for i = 0, 29 do d[i] = 5 end
        fixedD = buildHuff(d, 30)
        return fixedL, fixedD
    end

    -- raw deflate data from s[pos] -> string (expected size: a hint for errors only)
    local function inflate(s, pos)
        local bitBuf, bitCnt = 0, 0
        local out, outN = {}, 0
        local function need(n)
            while bitCnt < n do
                local b = byte(s, pos)
                if not b then error("zip data ended early", 0) end
                pos = pos + 1
                bitBuf = bitBuf + lsh(b, bitCnt)
                bitCnt = bitCnt + 8
            end
        end
        local function bits(n)
            if n == 0 then return 0 end
            need(n)
            local v = band(bitBuf, lsh(1, n) - 1)
            bitBuf = rsh(bitBuf, n)
            bitCnt = bitCnt - n
            return v
        end
        local function decode(h)
            local code, first, index = 0, 0, 0
            for len = 1, 15 do
                code = code + bits(1)
                local c = h.count[len]
                if code - c < first then return h.sym[index + (code - first)] end
                index = index + c
                first = (first + c) * 2
                code = code * 2
            end
            error("bad zip data", 0)
        end
        repeat
            local last = bits(1)
            local kind = bits(2)
            if kind == 0 then
                bitBuf, bitCnt = 0, 0
                local len = u16(s, pos)
                pos = pos + 4
                for i = 0, len - 1 do outN = outN + 1; out[outN] = byte(s, pos + i) end
                pos = pos + len
            elseif kind == 1 or kind == 2 then
                local lh, dh
                if kind == 1 then
                    lh, dh = fixed()
                else
                    local nlen, ndist, ncode = bits(5) + 257, bits(5) + 1, bits(4) + 4
                    local cl = {}
                    for i = 1, 19 do cl[ORDER[i]] = 0 end
                    for i = 1, ncode do cl[ORDER[i]] = bits(3) end
                    local ch = buildHuff(cl, 19)
                    local lengths, i = {}, 0
                    while i < nlen + ndist do
                        local sym = decode(ch)
                        if sym < 16 then lengths[i] = sym; i = i + 1
                        else
                            local rep, val = 0, 0
                            if sym == 16 then val = lengths[i - 1]; rep = 3 + bits(2)
                            elseif sym == 17 then rep = 3 + bits(3)
                            else rep = 11 + bits(7) end
                            for _ = 1, rep do lengths[i] = val; i = i + 1 end
                        end
                    end
                    local ll, dl = {}, {}
                    for k = 0, nlen - 1 do ll[k] = lengths[k] end
                    for k = 0, ndist - 1 do dl[k] = lengths[nlen + k] end
                    lh, dh = buildHuff(ll, nlen), buildHuff(dl, ndist)
                end
                while true do
                    local sym = decode(lh)
                    if sym < 256 then
                        outN = outN + 1; out[outN] = sym
                    elseif sym == 256 then
                        break
                    else
                        sym = sym - 257
                        local len = LBASE[sym] + bits(LEXT[sym])
                        local ds = decode(dh)
                        local dist = DBASE[ds] + bits(DEXT[ds])
                        local from = outN - dist
                        for k = 1, len do out[outN + k] = out[from + k] end
                        outN = outN + len
                    end
                end
            else
                error("bad zip block", 0)
            end
        until last == 1
        local parts = {}
        for k = 1, outN, 4096 do parts[#parts + 1] = char(table.unpack(out, k, math.min(outN, k + 4095))) end
        return concat(parts)
    end
    Zip.inflate = inflate

    -- what a file that is not a zip looks like, for the error message
    local function describe(z)
        local head = z:sub(1, 8)
        if head:sub(1, 6) == "7z\188\175\39\28" then return "this is a .7z archive, not a .zip - unpack it and use the .gb file" end
        if head:sub(1, 4) == "Rar!" then return "this is a .rar archive, not a .zip - unpack it and use the .gb file" end
        if head:sub(1, 2) == "\31\139" then return "this is a .gz file, not a .zip - unpack it and use the .gb file" end
        local hex = {}
        for k = 1, #head do hex[k] = string.format("%02X", byte(head, k)) end
        local mangled = select(2, z:gsub("\239\191\189", "")) > 16
        return "not a zip file (" .. #z .. " bytes, starts " .. table.concat(hex, " ") .. ")"
            .. (mangled and " - the executor read it as text and changed the bytes" or "")
    end
    Zip.describe = describe

    function Zip.extract(z)
        if type(z) ~= "string" then return nil, "file read returned " .. type(z) .. ", not data" end
        -- the archive may sit after other data (self-extractors, a prefix added on download)
        local start = z:find("PK\3\4", 1, true)
        if not start then return nil, describe(z) end
        local base = start - 1
        -- central directory: find the end record from the back
        local eocd
        for p = #z - 21, math.max(1, #z - 65557), -1 do
            if u32(z, p) == 0x06054b50 then eocd = p; break end
        end
        if not eocd then return nil, "zip directory not found (" .. #z .. " bytes - the file may be cut short)" end
        local count, cdPos = u16(z, eocd + 10), u32(z, eocd + 16) + 1 + base
        local p = cdPos
        for _ = 1, count do
            if u32(z, p) ~= 0x02014b50 then return nil, "bad zip directory" end
            local method, csize, nameLen, extraLen, commentLen = u16(z, p + 10), u32(z, p + 20), u16(z, p + 28), u16(z, p + 30), u16(z, p + 32)
            local local0 = u32(z, p + 42) + 1 + base
            local name = z:sub(p + 46, p + 45 + nameLen)
            local low = name:lower()
            if low:sub(-3) == ".gb" or low:sub(-4) == ".gbc" then
                local lnl, lel = u16(z, local0 + 26), u16(z, local0 + 28)
                local dataPos = local0 + 30 + lnl + lel
                if method == 0 then return z:sub(dataPos, dataPos + csize - 1), name end
                if method == 8 then
                    local ok, out = pcall(inflate, z, dataPos)
                    if not ok then return nil, tostring(out) end
                    return out, name
                end
                return nil, "zip compression method " .. method .. " is not supported"
            end
            p = p + 46 + nameLen + extraLen + commentLen
        end
        return nil, "no .gb file inside the zip"
    end
end
return Zip

end)()
return { GB = GB, Zip = Zip }
