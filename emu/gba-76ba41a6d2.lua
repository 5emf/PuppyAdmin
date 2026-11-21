-- PuppyAdmin gba 76ba41a6d2 (original Game Boy Advance emulator; games are loaded from your own PuppyAdmin/gba folder)
--!optimize 2
--!native
local GBA = (function()
-- Puppy Admin Game Boy Advance core (original). Luau: uses buffer and bit32.
-- GBA.new(romString, biosString, saveString?) -> emu
--   emu.runFrame(render)      one video frame (280896 clock cycles); render = false skips drawing
--   emu.fb                    buffer, 240 x 160 RGBA pixels (4 bytes each), row by row
--   emu.setKeys(mask)         bit set = held: 0 A, 1 B, 2 Select, 3 Start, 4 Right, 5 Left, 6 Up, 7 Down, 8 R, 9 L
--   emu.saveData()            save memory as a string (or nil); emu.saveDirty() / emu.clearSaveDirty()
--   emu.title, emu.code, emu.saveType
--   emu.reg(n), emu.pc()      for tests
-- BIOS: a 16 KB GBA BIOS image (the free Cult-of-GBA BIOS works). The game starts directly
-- (no boot animation). No sound. Timing is approximate (per instruction, video per scanline).
local GBA = {}

local band, bor, bxor, bnot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot
local lsh, rsh, arsh, rrot = bit32.lshift, bit32.rshift, bit32.arshift, bit32.rrotate
local rd8, rd16, rd32 = buffer.readu8, buffer.readu16, buffer.readu32
local wr8, wr16, wr32 = buffer.writeu8, buffer.writeu16, buffer.writeu32

local makePPU, makeSave -- defined below

function GBA.new(romStr, biosStr, saveStr)
    if type(romStr) ~= "string" or #romStr < 192 then error("not a GBA ROM", 0) end
    if #romStr > 0x2000000 then error("ROM is larger than 32 MB", 0) end
    if type(biosStr) ~= "string" or #biosStr ~= 16384 then error("the GBA BIOS must be 16384 bytes", 0) end
    local romSize = #romStr
    local rom = buffer.create(band(romSize + 7, 0xFFFFFFFC) + 4)
    buffer.writestring(rom, 0, romStr)
    local bios = buffer.fromstring(biosStr)
    local ewram = buffer.create(0x40000)
    local iwram = buffer.create(0x8000)
    local io = buffer.create(0x400)
    local pram = buffer.create(0x400)
    local vram = buffer.create(0x18000)
    local oam = buffer.create(0x400)
    local pal15 = table.create(512, 0)   -- palette entry + 1 -> 15-bit colour (kept in step with pram)
    local vflags = { oam = true }        -- oam = OAM changed since the video last read it

    local emu = {}
    emu.title = romStr:sub(0xA1, 0xAC):gsub("%z.*", "")
    emu.code = romStr:sub(0xAD, 0xB0)

    -- CPU state. R[n + 1] is register n; R[16] reads as the current instruction + 8 (ARM) / + 4 (Thumb)
    local R = table.create(16, 0)
    local pc = 0                 -- address of the next instruction to fetch
    local cycles = 0
    local fN, fZ, fC, fV = false, false, false, false
    local iDis, fDis, thumb = false, false, false
    local mode = 0x1F
    local spsr = 0
    local halted = false
    local IE, IF, IME = 0, 0, 0
    local irqLine = false
    local keys = 0x3FF
    local vcount, inVBlank, inHBlank, vMatch = 0, false, false, false
    local biosLatch = 0xE129F000

    local save = makeSave(romStr, saveStr)
    local saveRead8, saveWrite8 = save.read8, save.write8
    local eepActive = save.eeprom -- function(addr) -> true when the address is the EEPROM port
    local ppu -- set after the bus exists

    local function updateIrq() irqLine = IME ~= 0 and band(IE, IF) ~= 0 end
    local function raise(bit) IF = bor(IF, bit); updateIrq() end

    ----------------------------------------------------------------------------
    -- timers
    ----------------------------------------------------------------------------
    local tReload, tCtrl, tCount, tAcc = { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 }
    local PRESCALE = { [0] = 1, 64, 256, 1024 }
    local timerLast = 0
    local timerAdd
    timerAdd = function(i, ticks)
        local c = tCount[i] + ticks
        if c < 0x10000 then tCount[i] = c; return end
        local period = 0x10000 - tReload[i]
        local over = 1 + (c - 0x10000) // period
        tCount[i] = tReload[i] + (c - 0x10000) % period
        if band(tCtrl[i], 0x40) ~= 0 then raise(lsh(8, i - 1)) end
        if i < 4 and band(tCtrl[i + 1], 0x84) == 0x84 then timerAdd(i + 1, over) end
    end
    local function timersUpdate()
        local el = cycles - timerLast
        timerLast = cycles
        if el <= 0 then return end
        for i = 1, 4 do
            local ct = tCtrl[i]
            if band(ct, 0x80) ~= 0 and (i == 1 or band(ct, 4) == 0) then
                local ps = PRESCALE[band(ct, 3)]
                local a = tAcc[i] + el
                local ticks = a // ps
                tAcc[i] = a - ticks * ps
                if ticks > 0 then timerAdd(i, ticks) end
            end
        end
    end
    -- cycles until the next timer interrupt (so a halted CPU wakes on time)
    local function timerHorizon()
        local best = math.huge
        for i = 1, 4 do
            local ct = tCtrl[i]
            if band(ct, 0xC0) == 0xC0 and (i == 1 or band(ct, 4) == 0) then
                local ps = PRESCALE[band(ct, 3)]
                local need = (0x10000 - tCount[i]) * ps - tAcc[i]
                if need < best then best = need end
            end
        end
        return best
    end
    local function timerRead(i)
        timersUpdate()
        return tCount[i]
    end
    local function timerWrite(off, v)
        timersUpdate()
        local i = (off - 0x100) // 4 + 1
        if band(off, 2) == 0 then
            tReload[i] = v
            wr16(io, off, v)
        else
            local was = band(tCtrl[i], 0x80) ~= 0
            tCtrl[i] = band(v, 0xC7)
            wr16(io, off, band(v, 0xC7))
            if not was and band(v, 0x80) ~= 0 then tCount[i] = tReload[i]; tAcc[i] = 0 end
        end
    end

    ----------------------------------------------------------------------------
    -- memory bus
    ----------------------------------------------------------------------------
    local ioRead16, ioWrite16, ioWrite8 -- forward
    local function romOpen16(o) return band(rsh(o, 1), 0xFFFF) end

    local function read8(a)
        local r = rsh(a, 24)
        if r == 3 then cycles += 1; return rd8(iwram, band(a, 0x7FFF))
        elseif r == 2 then cycles += 3; return rd8(ewram, band(a, 0x3FFFF))
        elseif r >= 8 then
            if r < 14 then
                cycles += 5
                local o = band(a, 0x1FFFFFF)
                if o < romSize then return rd8(rom, o) end
                return band(rsh(romOpen16(o), 8 * band(o, 1)), 0xFF)
            elseif r < 16 then cycles += 5; return saveRead8(a) end
            return 0
        elseif r == 4 then
            cycles += 1
            local off = band(a, 0xFFFFFF)
            if off < 0x400 then return band(rsh(ioRead16(band(off, 0x3FE)), 8 * band(off, 1)), 0xFF) end
            return 0
        elseif r == 5 then cycles += 1; return rd8(pram, band(a, 0x3FF))
        elseif r == 6 then
            cycles += 1
            local o = band(a, 0x1FFFF)
            if o >= 0x18000 then o -= 0x8000 end
            return rd8(vram, o)
        elseif r == 7 then cycles += 1; return rd8(oam, band(a, 0x3FF))
        elseif r == 0 then
            cycles += 1
            if a < 0x4000 then
                if pc < 0x4000 then return rd8(bios, a) end
                return band(rsh(biosLatch, 8 * band(a, 3)), 0xFF)
            end
        end
        return 0
    end
    local function read16(a) -- a is even
        local r = rsh(a, 24)
        if r == 3 then cycles += 1; return rd16(iwram, band(a, 0x7FFE))
        elseif r == 2 then cycles += 3; return rd16(ewram, band(a, 0x3FFFE))
        elseif r >= 8 then
            if r < 14 then
                cycles += 5
                if r == 13 and eepActive(a) then return save.eepRead() end
                local o = band(a, 0x1FFFFFE)
                if o < romSize then return rd16(rom, o) end
                return romOpen16(o)
            elseif r < 16 then cycles += 5; return saveRead8(a) * 0x101 end
            return 0
        elseif r == 4 then
            cycles += 1
            local off = band(a, 0xFFFFFE)
            if off < 0x400 then return ioRead16(off) end
            return 0
        elseif r == 5 then cycles += 1; return rd16(pram, band(a, 0x3FE))
        elseif r == 6 then
            cycles += 1
            local o = band(a, 0x1FFFE)
            if o >= 0x18000 then o -= 0x8000 end
            return rd16(vram, o)
        elseif r == 7 then cycles += 1; return rd16(oam, band(a, 0x3FE))
        elseif r == 0 then
            cycles += 1
            if a < 0x4000 then
                if pc < 0x4000 then return rd16(bios, a) end
                return band(rsh(biosLatch, 8 * band(a, 2)), 0xFFFF)
            end
        end
        return 0
    end
    local function read32(a) -- a is a multiple of 4
        local r = rsh(a, 24)
        if r == 3 then cycles += 1; return rd32(iwram, band(a, 0x7FFC))
        elseif r == 2 then cycles += 6; return rd32(ewram, band(a, 0x3FFFC))
        elseif r >= 8 then
            if r < 14 then
                cycles += 8
                local o = band(a, 0x1FFFFFC)
                if o < romSize then return rd32(rom, o) end
                return romOpen16(o) + romOpen16(o + 2) * 65536
            elseif r < 16 then cycles += 5; return saveRead8(a) * 0x01010101 end
            return 0
        elseif r == 4 then
            cycles += 1
            local off = band(a, 0xFFFFFC)
            if off < 0x400 then return ioRead16(off) + ioRead16(off + 2) * 65536 end
            return 0
        elseif r == 5 then cycles += 2; return rd32(pram, band(a, 0x3FC))
        elseif r == 6 then
            cycles += 2
            local o = band(a, 0x1FFFC)
            if o >= 0x18000 then o -= 0x8000 end
            return rd32(vram, o)
        elseif r == 7 then cycles += 1; return rd32(oam, band(a, 0x3FC))
        elseif r == 0 then
            cycles += 1
            if a < 0x4000 then
                if pc < 0x4000 then return rd32(bios, a) end
                return biosLatch
            end
        end
        return 0
    end

    local function bitmapMode() return band(rd16(io, 0), 7) >= 3 end
    local function write8(a, v)
        local r = rsh(a, 24)
        if r == 3 then cycles += 1; wr8(iwram, band(a, 0x7FFF), v)
        elseif r == 2 then cycles += 3; wr8(ewram, band(a, 0x3FFFF), v)
        elseif r == 4 then
            cycles += 1
            local off = band(a, 0xFFFFFF)
            if off < 0x400 then ioWrite8(off, band(v, 0xFF)) end
        elseif r == 5 then
            cycles += 1
            local o = band(a, 0x3FE)
            wr16(pram, o, band(v, 0xFF) * 0x101)
            pal15[o // 2 + 1] = band(band(v, 0xFF) * 0x101, 0x7FFF)
        elseif r == 6 then
            cycles += 1
            local o = band(a, 0x1FFFF)
            if o >= 0x18000 then o -= 0x8000 end
            -- byte writes reach only the background part of VRAM, as both bytes of the halfword
            if o < (bitmapMode() and 0x14000 or 0x10000) then wr16(vram, band(o, 0x1FFFE), band(v, 0xFF) * 0x101) end
        elseif r == 14 or r == 15 then cycles += 5; saveWrite8(a, band(v, 0xFF))
        else cycles += 1 end
    end
    local function write16(a, v) -- a is even
        local r = rsh(a, 24)
        if r == 3 then cycles += 1; wr16(iwram, band(a, 0x7FFE), v)
        elseif r == 2 then cycles += 3; wr16(ewram, band(a, 0x3FFFE), v)
        elseif r == 4 then
            cycles += 1
            local off = band(a, 0xFFFFFE)
            if off < 0x400 then ioWrite16(off, band(v, 0xFFFF)) end
        elseif r == 5 then
            cycles += 1
            local o = band(a, 0x3FE)
            wr16(pram, o, v)
            pal15[o // 2 + 1] = band(v, 0x7FFF)
        elseif r == 6 then
            cycles += 1
            local o = band(a, 0x1FFFE)
            if o >= 0x18000 then o -= 0x8000 end
            wr16(vram, o, v)
        elseif r == 7 then cycles += 1; wr16(oam, band(a, 0x3FE), v); vflags.oam = true
        elseif r == 13 then cycles += 5; if eepActive(a) then save.eepWrite(band(v, 1)) end
        elseif r == 14 or r == 15 then cycles += 5; saveWrite8(a, band(rsh(v, 8 * band(a, 1)), 0xFF))
        else cycles += 1 end
    end
    local function write32(a, v) -- a is a multiple of 4
        local r = rsh(a, 24)
        if r == 3 then cycles += 1; wr32(iwram, band(a, 0x7FFC), v)
        elseif r == 2 then cycles += 6; wr32(ewram, band(a, 0x3FFFC), v)
        elseif r == 4 then
            cycles += 1
            local off = band(a, 0xFFFFFC)
            if off < 0x400 then ioWrite16(off, band(v, 0xFFFF)); ioWrite16(off + 2, rsh(v, 16)) end
        elseif r == 5 then
            cycles += 2
            local o = band(a, 0x3FC)
            wr32(pram, o, v)
            pal15[o // 2 + 1] = band(v, 0x7FFF)
            pal15[o // 2 + 2] = band(rsh(v, 16), 0x7FFF)
        elseif r == 6 then
            cycles += 2
            local o = band(a, 0x1FFFC)
            if o >= 0x18000 then o -= 0x8000 end
            wr32(vram, o, v)
        elseif r == 7 then cycles += 1; wr32(oam, band(a, 0x3FC), v); vflags.oam = true
        elseif r == 13 then cycles += 5; if eepActive(a) then save.eepWrite(band(v, 1)) end
        elseif r == 14 or r == 15 then cycles += 5; saveWrite8(a, band(rsh(v, 8 * band(a, 3)), 0xFF))
        else cycles += 1 end
    end

    ----------------------------------------------------------------------------
    -- DMA
    ----------------------------------------------------------------------------
    local dmaSrc, dmaDst, dmaCount, dmaOn = { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { false, false, false, false }
    local SRC_MASK = { 0x07FFFFFF, 0x0FFFFFFF, 0x0FFFFFFF, 0x0FFFFFFF }
    local DST_MASK = { 0x07FFFFFF, 0x07FFFFFF, 0x07FFFFFF, 0x0FFFFFFF }
    local function dmaLatchCount(i)
        local base = 0xB0 + (i - 1) * 12
        local n = rd16(io, base + 8)
        if i == 4 then dmaCount[i] = n == 0 and 0x10000 or n
        else n = band(n, 0x3FFF); dmaCount[i] = n == 0 and 0x4000 or n end
    end
    local function dmaRun(i)
        local base = 0xB0 + (i - 1) * 12
        local ctl = rd16(io, base + 10)
        local word = band(ctl, 0x400) ~= 0
        local dmode, smode = band(rsh(ctl, 5), 3), band(rsh(ctl, 7), 3)
        local unit = word and 4 or 2
        local dstep = (dmode == 0 or dmode == 3) and unit or (dmode == 1 and -unit or 0)
        local sstep = smode == 0 and unit or (smode == 1 and -unit or 0)
        local s, d, n = dmaSrc[i], dmaDst[i], dmaCount[i]
        if i == 4 and rsh(d, 24) == 13 then save.eepSetBits(n) end
        if word then
            s, d = band(s, 0xFFFFFFFC), band(d, 0xFFFFFFFC)
            for _ = 1, n do
                write32(d, read32(s))
                s = band(s + sstep, 0xFFFFFFFF); d = band(d + dstep, 0xFFFFFFFF)
            end
        else
            s, d = band(s, 0xFFFFFFFE), band(d, 0xFFFFFFFE)
            for _ = 1, n do
                write16(d, read16(s))
                s = band(s + sstep, 0xFFFFFFFF); d = band(d + dstep, 0xFFFFFFFF)
            end
        end
        cycles += 2
        dmaSrc[i] = s
        dmaDst[i] = d
        local timing = band(rsh(ctl, 12), 3)
        if band(ctl, 0x200) ~= 0 and timing ~= 0 then
            dmaLatchCount(i)
            if dmode == 3 then dmaDst[i] = band(rd32(io, base + 4), DST_MASK[i]) end
        else
            dmaOn[i] = false
            wr16(io, base + 10, band(ctl, 0x7FFF))
        end
        if band(ctl, 0x4000) ~= 0 then raise(lsh(0x100, i - 1)) end
    end
    local function dmaControl(i, v)
        local base = 0xB0 + (i - 1) * 12
        local was = dmaOn[i]
        dmaOn[i] = band(v, 0x8000) ~= 0
        if dmaOn[i] and not was then
            dmaSrc[i] = band(rd32(io, base), SRC_MASK[i])
            dmaDst[i] = band(rd32(io, base + 4), DST_MASK[i])
            dmaLatchCount(i)
            if band(rsh(v, 12), 3) == 0 then dmaRun(i) end
        end
    end
    -- timing 1 = VBlank, 2 = HBlank (3 = sound FIFO / video capture: not run, there is no sound)
    local function dmaTrigger(timing)
        for i = 1, 4 do
            if dmaOn[i] and band(rsh(rd16(io, 0xB0 + (i - 1) * 12 + 10), 12), 3) == timing then dmaRun(i) end
        end
    end

    ----------------------------------------------------------------------------
    -- I/O registers
    ----------------------------------------------------------------------------
    ioRead16 = function(off)
        if off == 0x004 then
            local v = band(rd16(io, 4), 0xFFF8)
            if inVBlank then v += 1 end
            if inHBlank then v += 2 end
            if vMatch then v += 4 end
            return v
        elseif off == 0x006 then return vcount
        elseif off >= 0x100 and off <= 0x10E then
            if band(off, 2) == 0 then return timerRead((off - 0x100) // 4 + 1) end
            return rd16(io, off)
        elseif off == 0x130 then return band(bnot(keys), 0x3FF)
        elseif off == 0x200 then return IE
        elseif off == 0x202 then return IF
        elseif off == 0x208 then return IME
        end
        return rd16(io, off)
    end
    ioWrite16 = function(off, v)
        if off == 0x202 then IF = band(IF, bnot(v)); updateIrq()
        elseif off == 0x200 then IE = band(v, 0x3FFF); updateIrq()
        elseif off == 0x208 then IME = band(v, 1); updateIrq()
        elseif off == 0x004 then wr16(io, 4, band(v, 0xFFF8))
        elseif off == 0x006 or off == 0x130 then -- read only
        elseif off >= 0x100 and off <= 0x10E then timerWrite(off, v)
        elseif off >= 0xB0 and off <= 0xDE then
            wr16(io, off, v)
            local rel = off - 0xB0
            if rel % 12 == 10 then dmaControl(rel // 12 + 1, v) end
        elseif off == 0x300 then
            wr8(io, 0x300, band(v, 0xFF))
            halted = true
        else
            wr16(io, off, v)
            if off >= 0x28 and off <= 0x3E and ppu then ppu.refWritten(off) end
        end
    end
    ioWrite8 = function(off, v)
        if off == 0x301 then halted = true; return end
        if off == 0x300 then wr8(io, 0x300, v); return end
        if off == 0x202 then IF = band(IF, bnot(v)); updateIrq(); return end
        if off == 0x203 then IF = band(IF, bnot(v * 256)); updateIrq(); return end
        local h = off - band(off, 1)
        local old = ioRead16(h)
        if h == 0x202 then old = 0 end
        if band(off, 1) == 0 then ioWrite16(h, bor(band(old, 0xFF00), v)) else ioWrite16(h, bor(band(old, 0xFF), v * 256)) end
    end

    ----------------------------------------------------------------------------
    -- CPU helpers
    ----------------------------------------------------------------------------
    local bankSP, bankLR, bankSPSR = { 0, 0, 0, 0, 0, [0] = 0 }, { 0, 0, 0, 0, 0, [0] = 0 }, { 0, 0, 0, 0, 0, [0] = 0 }
    local fiqHi, usrHi = { 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }
    local function bankOf(m)
        if m == 0x12 then return 2 elseif m == 0x13 then return 3 elseif m == 0x11 then return 1
        elseif m == 0x17 then return 4 elseif m == 0x1B then return 5 end
        return 0
    end
    local function setMode(m)
        local ob, nb = bankOf(mode), bankOf(m)
        if ob ~= nb then
            bankSP[ob], bankLR[ob], bankSPSR[ob] = R[14], R[15], spsr
            R[14], R[15], spsr = bankSP[nb], bankLR[nb], bankSPSR[nb]
            if ob == 1 then
                for k = 1, 5 do fiqHi[k] = R[8 + k]; R[8 + k] = usrHi[k] end
            elseif nb == 1 then
                for k = 1, 5 do usrHi[k] = R[8 + k]; R[8 + k] = fiqHi[k] end
            end
        end
        mode = m
    end
    local function getCPSR()
        local v = mode
        if fN then v += 0x80000000 end
        if fZ then v += 0x40000000 end
        if fC then v += 0x20000000 end
        if fV then v += 0x10000000 end
        if iDis then v += 0x80 end
        if fDis then v += 0x40 end
        if thumb then v += 0x20 end
        return v
    end
    local function setFlags(v)
        fN = band(v, 0x80000000) ~= 0
        fZ = band(v, 0x40000000) ~= 0
        fC = band(v, 0x20000000) ~= 0
        fV = band(v, 0x10000000) ~= 0
    end
    local function setCPSR(v)
        setFlags(v)
        iDis = band(v, 0x80) ~= 0
        fDis = band(v, 0x40) ~= 0
        thumb = band(v, 0x20) ~= 0
        setMode(bor(band(v, 0x1F), 0x10))
        updateIrq()
    end
    local function hasSPSR() return mode ~= 0x10 and mode ~= 0x1F end
    -- What a read of BIOS memory returns while code runs outside it: the official BIOS's last
    -- prefetched opcode, which depends on how the BIOS was left (start-up, SWI, IRQ handler, IRQ return).
    local biosCtx, biosDepth, inBios = {}, 0, false
    local function leaveBios()
        inBios = false
        while biosDepth > 0 do
            local top = biosCtx[biosDepth]
            if top == 1 then biosLatch = 0xE3A02004; biosDepth -= 1; return       -- SWI returned
            elseif top == 2 then biosLatch = 0xE25EF004; biosCtx[biosDepth] = 3; return -- IRQ handler called
            elseif top == 3 then biosLatch = 0xE55EC002; biosDepth -= 1; return   -- IRQ returned
            elseif top == 4 then biosLatch = 0xE25EF004; biosCtx[biosDepth] = 5; return -- IRQ (taken inside the BIOS) handler called
            else biosDepth -= 1 end -- an IRQ taken inside the BIOS is over: carry on with the outer call
        end
    end
    local function exception(vector, newMode, lr)
        if biosDepth >= 8 then biosDepth = 0 end
        if vector == 0x08 then biosDepth += 1; biosCtx[biosDepth] = 1
        elseif vector == 0x18 then biosDepth += 1; biosCtx[biosDepth] = (pc < 0x4000) and 4 or 2 end
        local old = getCPSR()
        setMode(newMode)
        spsr = old
        R[15] = lr
        iDis = true
        thumb = false
        if newMode == 0x11 then fDis = true end
        pc = vector
        cycles += 3
    end

    local function condPass(c)
        if c == 0 then return fZ elseif c == 1 then return not fZ
        elseif c == 2 then return fC elseif c == 3 then return not fC
        elseif c == 4 then return fN elseif c == 5 then return not fN
        elseif c == 6 then return fV elseif c == 7 then return not fV
        elseif c == 8 then return fC and not fZ elseif c == 9 then return (not fC) or fZ
        elseif c == 10 then return fN == fV elseif c == 11 then return fN ~= fV
        elseif c == 12 then return (not fZ) and fN == fV elseif c == 13 then return fZ or fN ~= fV
        elseif c == 14 then return true end
        return false
    end

    -- barrel shifter: value, carry out
    local function shiftImm(typ, v, amt)
        if typ == 0 then
            if amt == 0 then return v, fC end
            return lsh(v, amt), band(v, lsh(1, 32 - amt)) ~= 0
        elseif typ == 1 then
            if amt == 0 then return 0, v >= 0x80000000 end
            return rsh(v, amt), band(v, lsh(1, amt - 1)) ~= 0
        elseif typ == 2 then
            if amt == 0 then
                if v >= 0x80000000 then return 0xFFFFFFFF, true end
                return 0, false
            end
            return arsh(v, amt), band(v, lsh(1, amt - 1)) ~= 0
        end
        if amt == 0 then return bor(rsh(v, 1), fC and 0x80000000 or 0), band(v, 1) ~= 0 end
        return rrot(v, amt), band(v, lsh(1, amt - 1)) ~= 0
    end
    local function shiftReg(typ, v, amt)
        if amt == 0 then return v, fC end
        if typ == 0 then
            if amt < 32 then return lsh(v, amt), band(v, lsh(1, 32 - amt)) ~= 0 end
            if amt == 32 then return 0, band(v, 1) ~= 0 end
            return 0, false
        elseif typ == 1 then
            if amt < 32 then return rsh(v, amt), band(v, lsh(1, amt - 1)) ~= 0 end
            if amt == 32 then return 0, v >= 0x80000000 end
            return 0, false
        elseif typ == 2 then
            if amt < 32 then return arsh(v, amt), band(v, lsh(1, amt - 1)) ~= 0 end
            if v >= 0x80000000 then return 0xFFFFFFFF, true end
            return 0, false
        end
        local a = band(amt, 31)
        if a == 0 then return v, v >= 0x80000000 end
        return rrot(v, a), band(v, lsh(1, a - 1)) ~= 0
    end

    local function addFlags(a, b, r) -- r = a + b (+ carry), unmasked
        local res = band(r, 0xFFFFFFFF)
        fN = res >= 0x80000000
        fZ = res == 0
        fC = r > 0xFFFFFFFF
        fV = band(band(bnot(bxor(a, b)), bxor(a, res)), 0x80000000) ~= 0
        return res
    end
    local function subFlags(a, b, r) -- r = a - b (- borrow), unmasked
        local res = band(r, 0xFFFFFFFF)
        fN = res >= 0x80000000
        fZ = res == 0
        fC = r >= 0
        fV = band(band(bxor(a, b), bxor(a, res)), 0x80000000) ~= 0
        return res
    end
    -- low 32 bits of a * b, and the full 64-bit product as lo, hi
    local function mul32(a, b)
        local al, ah = band(a, 0xFFFF), rsh(a, 16)
        return band(al * b + lsh(band(ah * b, 0xFFFF), 16), 0xFFFFFFFF)
    end
    local function mul64(a, b)
        local al, ah, bl, bh = band(a, 0xFFFF), rsh(a, 16), band(b, 0xFFFF), rsh(b, 16)
        local mid = al * bh + ah * bl
        local t = al * bl + band(mid, 0xFFFF) * 65536
        local lo = t % 4294967296
        local hi = (ah * bh + mid // 65536 + t // 4294967296) % 4294967296
        return lo, hi
    end
    local function mulCycles(v)
        if v >= 0x80000000 then v = band(bnot(v), 0xFFFFFFFF) end
        if v < 0x100 then return 1 elseif v < 0x10000 then return 2 elseif v < 0x1000000 then return 3 end
        return 4
    end

    local function writePC(v)
        if thumb then pc = band(v, 0xFFFFFFFE) else pc = band(v, 0xFFFFFFFC) end
        cycles += 2
    end

    ----------------------------------------------------------------------------
    -- ARM instructions: table indexed by bits 27-20 and 7-4 of the opcode
    ----------------------------------------------------------------------------
    local ARM = table.create(4096)

    local function op2Imm(op)
        local imm, rot = band(op, 0xFF), band(rsh(op, 7), 0x1E)
        if rot == 0 then return imm, fC end
        local v = rrot(imm, rot)
        return v, v >= 0x80000000
    end
    local function op2ShiftImm(op)
        return shiftImm(band(rsh(op, 5), 3), R[band(op, 15) + 1], band(rsh(op, 7), 31))
    end
    local function op2ShiftReg(op)
        local rm = band(op, 15)
        local v = R[rm + 1]
        if rm == 15 then v += 4 end
        cycles += 1
        return shiftReg(band(rsh(op, 5), 3), v, band(R[band(rsh(op, 8), 15) + 1], 0xFF))
    end

    local function makeALU(opc, S, getOp2, regShift)
        local function rnVal(op)
            local rn = band(rsh(op, 16), 15)
            local a = R[rn + 1]
            if regShift and rn == 15 then a += 4 end
            return a
        end
        local function finish(op, r)
            local rd = band(rsh(op, 12), 15)
            if rd == 15 then
                if S and hasSPSR() then setCPSR(spsr) end
                writePC(r)
            else
                R[rd + 1] = r
            end
        end
        local function logical(op, r, carry)
            if S then fN = r >= 0x80000000; fZ = r == 0; fC = carry end
            finish(op, r)
        end
        if opc == 0 then return function(op) local b, c = getOp2(op); logical(op, band(rnVal(op), b), c) end
        elseif opc == 1 then return function(op) local b, c = getOp2(op); logical(op, bxor(rnVal(op), b), c) end
        elseif opc == 2 then return function(op)
            local b = getOp2(op); local a = rnVal(op)
            if S then finish(op, subFlags(a, b, a - b)) else finish(op, band(a - b, 0xFFFFFFFF)) end
        end
        elseif opc == 3 then return function(op)
            local b = getOp2(op); local a = rnVal(op)
            if S then finish(op, subFlags(b, a, b - a)) else finish(op, band(b - a, 0xFFFFFFFF)) end
        end
        elseif opc == 4 then return function(op)
            local b = getOp2(op); local a = rnVal(op)
            if S then finish(op, addFlags(a, b, a + b)) else finish(op, band(a + b, 0xFFFFFFFF)) end
        end
        elseif opc == 5 then return function(op)
            local b = getOp2(op); local a = rnVal(op); local c = fC and 1 or 0
            if S then finish(op, addFlags(a, b, a + b + c)) else finish(op, band(a + b + c, 0xFFFFFFFF)) end
        end
        elseif opc == 6 then return function(op)
            local b = getOp2(op); local a = rnVal(op); local c = fC and 0 or 1
            if S then finish(op, subFlags(a, b, a - b - c)) else finish(op, band(a - b - c, 0xFFFFFFFF)) end
        end
        elseif opc == 7 then return function(op)
            local b = getOp2(op); local a = rnVal(op); local c = fC and 0 or 1
            if S then finish(op, subFlags(b, a, b - a - c)) else finish(op, band(b - a - c, 0xFFFFFFFF)) end
        end
        -- compares with Rd = 15 copy SPSR to CPSR (and do not branch)
        elseif opc == 8 then return function(op)
            local b, c = getOp2(op); local r = band(rnVal(op), b)
            fN = r >= 0x80000000; fZ = r == 0; fC = c
            if band(op, 0xF000) == 0xF000 and hasSPSR() then setCPSR(spsr) end
        end
        elseif opc == 9 then return function(op)
            local b, c = getOp2(op); local r = bxor(rnVal(op), b)
            fN = r >= 0x80000000; fZ = r == 0; fC = c
            if band(op, 0xF000) == 0xF000 and hasSPSR() then setCPSR(spsr) end
        end
        elseif opc == 10 then return function(op)
            local b = getOp2(op); local a = rnVal(op); subFlags(a, b, a - b)
            if band(op, 0xF000) == 0xF000 and hasSPSR() then setCPSR(spsr) end
        end
        elseif opc == 11 then return function(op)
            local b = getOp2(op); local a = rnVal(op); addFlags(a, b, a + b)
            if band(op, 0xF000) == 0xF000 and hasSPSR() then setCPSR(spsr) end
        end
        elseif opc == 12 then return function(op) local b, c = getOp2(op); logical(op, bor(rnVal(op), b), c) end
        elseif opc == 13 then return function(op) local b, c = getOp2(op); logical(op, b, c) end
        elseif opc == 14 then return function(op) local b, c = getOp2(op); logical(op, band(rnVal(op), bnot(b)), c) end
        end
        return function(op) local b, c = getOp2(op); logical(op, band(bnot(b), 0xFFFFFFFF), c) end
    end

    local function armUndefined()
        exception(0x04, 0x1B, pc)
    end

    local function armMRS(op)
        local rd = band(rsh(op, 12), 15)
        if band(op, 0x400000) ~= 0 then R[rd + 1] = hasSPSR() and spsr or getCPSR() else R[rd + 1] = getCPSR() end
    end
    local function armMSR(op)
        local v
        if band(op, 0x2000000) ~= 0 then v = rrot(band(op, 0xFF), band(rsh(op, 7), 0x1E)) else v = R[band(op, 15) + 1] end
        local mask = 0
        if band(op, 0x80000) ~= 0 then mask += 0xFF000000 end
        if band(op, 0x10000) ~= 0 then mask += 0xFF end
        if band(op, 0x400000) ~= 0 then
            if hasSPSR() then spsr = bor(band(spsr, bnot(mask)), band(v, mask)) end
        else
            if mode == 0x10 then mask = band(mask, 0xFF000000) end
            local cur = getCPSR()
            local nv = bor(band(cur, bnot(mask)), band(v, mask))
            nv = bor(band(nv, bnot(0x20)), band(cur, 0x20)) -- the T bit is not changed this way
            setCPSR(nv)
        end
    end
    local function armBX(op)
        local v = R[band(op, 15) + 1]
        if band(v, 1) ~= 0 then thumb = true; pc = band(v, 0xFFFFFFFE) else thumb = false; pc = band(v, 0xFFFFFFFC) end
        cycles += 2
    end
    local function armMUL(op)
        local rd, rn, rs, rm = band(rsh(op, 16), 15), band(rsh(op, 12), 15), band(rsh(op, 8), 15), band(op, 15)
        local s = R[rs + 1]
        local r = mul32(R[rm + 1], s)
        if band(op, 0x200000) ~= 0 then r = band(r + R[rn + 1], 0xFFFFFFFF); cycles += 1 end
        cycles += mulCycles(s)
        if band(op, 0x100000) ~= 0 then fN = r >= 0x80000000; fZ = r == 0 end
        R[rd + 1] = r
    end
    local function armMULL(op)
        local rdhi, rdlo, rs, rm = band(rsh(op, 16), 15), band(rsh(op, 12), 15), band(rsh(op, 8), 15), band(op, 15)
        local a, b = R[rm + 1], R[rs + 1]
        local lo, hi = mul64(a, b)
        local signed = band(op, 0x400000) ~= 0
        if signed then
            if a >= 0x80000000 then hi = (hi - b) % 4294967296 end
            if b >= 0x80000000 then hi = (hi - a) % 4294967296 end
        end
        if band(op, 0x200000) ~= 0 then
            local l = lo + R[rdlo + 1]
            lo = l % 4294967296
            hi = (hi + R[rdhi + 1] + l // 4294967296) % 4294967296
            cycles += 1
        end
        cycles += mulCycles(b) + 1
        R[rdlo + 1] = lo
        R[rdhi + 1] = hi
        if band(op, 0x100000) ~= 0 then fN = hi >= 0x80000000; fZ = hi == 0 and lo == 0 end
    end
    local function armSWP(op)
        local rn, rd, rm = band(rsh(op, 16), 15), band(rsh(op, 12), 15), band(op, 15)
        local addr = R[rn + 1]
        local v = R[rm + 1]
        if band(op, 0x400000) ~= 0 then
            local t = read8(addr)
            write8(addr, band(v, 0xFF))
            R[rd + 1] = t
        else
            local t = rrot(read32(band(addr, 0xFFFFFFFC)), 8 * band(addr, 3))
            write32(addr, v)
            R[rd + 1] = t
        end
        cycles += 1
    end

    -- LDRH / STRH / LDRSB / LDRSH
    local function makeHalf(P, U, I, W, L, sh)
        return function(op)
            local rn, rd = band(rsh(op, 16), 15), band(rsh(op, 12), 15)
            local off
            if I then off = bor(band(rsh(op, 4), 0xF0), band(op, 15)) else off = R[band(op, 15) + 1] end
            local base = R[rn + 1]
            local addr = base
            local moved = U and band(base + off, 0xFFFFFFFF) or band(base - off, 0xFFFFFFFF)
            if P then addr = moved end
            if L then
                local v
                if sh == 1 then
                    v = read16(band(addr, 0xFFFFFFFE))
                    if band(addr, 1) ~= 0 then v = rrot(v, 8) end
                elseif sh == 2 then
                    v = read8(addr)
                    if v >= 0x80 then v += 0xFFFFFF00 end
                else
                    if band(addr, 1) ~= 0 then
                        v = read8(addr)
                        if v >= 0x80 then v += 0xFFFFFF00 end
                    else
                        v = read16(addr)
                        if v >= 0x8000 then v += 0xFFFF0000 end
                    end
                end
                if (not P) or W then R[rn + 1] = moved end
                cycles += 1
                if rd == 15 then writePC(v) else R[rd + 1] = v end
            else
                local v = R[rd + 1]
                if rd == 15 then v += 4 end
                write16(addr, band(v, 0xFFFF))
                if (not P) or W then R[rn + 1] = moved end
            end
        end
    end

    -- LDR / STR / LDRB / STRB
    local function makeSingle(I, P, U, B, W, L)
        return function(op)
            local rn, rd = band(rsh(op, 16), 15), band(rsh(op, 12), 15)
            local off
            if I then
                off = (shiftImm(band(rsh(op, 5), 3), R[band(op, 15) + 1], band(rsh(op, 7), 31)))
            else
                off = band(op, 0xFFF)
            end
            local base = R[rn + 1]
            local moved = U and band(base + off, 0xFFFFFFFF) or band(base - off, 0xFFFFFFFF)
            local addr = P and moved or base
            if L then
                local v
                if B then v = read8(addr)
                else
                    v = read32(band(addr, 0xFFFFFFFC))
                    local rot = band(addr, 3)
                    if rot ~= 0 then v = rrot(v, 8 * rot) end
                end
                if (not P) or W then R[rn + 1] = moved end
                cycles += 1
                if rd == 15 then writePC(v) else R[rd + 1] = v end
            else
                local v = R[rd + 1]
                if rd == 15 then v += 4 end
                if B then write8(addr, band(v, 0xFF)) else write32(addr, v) end
                if (not P) or W then R[rn + 1] = moved end
            end
        end
    end

    -- LDM / STM
    local function makeBlock(P, U, S, W, L)
        return function(op)
            local rn = band(rsh(op, 16), 15)
            local list = band(op, 0xFFFF)
            local base = R[rn + 1]
            local n = 0
            for k = 0, 15 do if band(list, lsh(1, k)) ~= 0 then n += 1 end end
            local empty = n == 0
            if empty then list = 0x8000; n = 16 end -- ARMv4: an empty list moves r15 and the base by 0x40
            local size = n * 4
            local start
            if U then start = P and base + 4 or base else start = P and base - size or base - size + 4 end
            start = band(start, 0xFFFFFFFF)
            local newBase = U and band(base + size, 0xFFFFFFFF) or band(base - size, 0xFFFFFFFF)
            local addr = start
            local userBank = S and not (L and band(list, 0x8000) ~= 0)
            local oldMode = mode
            if userBank and mode ~= 0x10 and mode ~= 0x1F then setMode(0x1F) end
            if L then
                if W then R[rn + 1] = newBase end
                for k = 0, 15 do
                    if band(list, lsh(1, k)) ~= 0 then
                        local v = read32(band(addr, 0xFFFFFFFC))
                        if k == 15 then
                            if S and hasSPSR() then setCPSR(spsr) end
                            writePC(v)
                        else
                            R[k + 1] = v
                        end
                        addr += 4
                    end
                end
                cycles += 1
            else
                local first = true
                for k = 0, 15 do
                    if band(list, lsh(1, k)) ~= 0 then
                        local v = R[k + 1]
                        if k == 15 then v += 4 end
                        if k == rn and not first and W then v = newBase end
                        write32(addr, v)
                        addr += 4
                        first = false
                    end
                end
                if W then R[rn + 1] = newBase end
            end
            if userBank and oldMode ~= mode then setMode(oldMode) end
        end
    end

    local function armBranch(op)
        local off = band(op, 0xFFFFFF)
        if off >= 0x800000 then off -= 0x1000000 end
        if band(op, 0x1000000) ~= 0 then R[15] = band(R[16] - 4, 0xFFFFFFFF) end
        pc = band(R[16] + off * 4, 0xFFFFFFFC)
        cycles += 2
    end
    local function armSWI()
        exception(0x08, 0x13, pc)
    end

    local op2Fns = { op2Imm, op2ShiftImm, op2ShiftReg }
    for idx = 0, 4095 do
        local hi, lo = rsh(idx, 4), band(idx, 15) -- hi = bits 27-20, lo = bits 7-4
        local h = nil
        local top = rsh(hi, 5) -- bits 27-25
        if top == 0 then
            if band(idx, 0xFCF) == 0x009 then h = armMUL
            elseif band(idx, 0xF8F) == 0x089 then h = armMULL
            elseif band(idx, 0xFBF) == 0x109 then h = armSWP
            elseif band(lo, 9) == 9 and band(lo, 6) ~= 0 then
                h = makeHalf(band(hi, 0x10) ~= 0, band(hi, 8) ~= 0, band(hi, 4) ~= 0, band(hi, 2) ~= 0, band(hi, 1) ~= 0, band(rsh(lo, 1), 3))
            elseif idx == 0x121 then h = armBX
            elseif band(idx, 0xFBF) == 0x100 then h = armMRS
            elseif band(idx, 0xFBF) == 0x120 then h = armMSR
            else
                local opc, S = band(rsh(hi, 1), 15), band(hi, 1) ~= 0
                local regShift = band(lo, 1) ~= 0
                h = makeALU(opc, S, regShift and op2ShiftReg or op2ShiftImm, regShift)
            end
        elseif top == 1 then
            if band(idx, 0xFB0) == 0x320 then h = armMSR
            elseif band(idx, 0xFB0) == 0x300 then h = armUndefined
            else
                h = makeALU(band(rsh(hi, 1), 15), band(hi, 1) ~= 0, op2Imm, false)
            end
        elseif top == 2 or top == 3 then
            if top == 3 and band(lo, 1) ~= 0 then h = armUndefined
            else
                h = makeSingle(top == 3, band(hi, 0x10) ~= 0, band(hi, 8) ~= 0, band(hi, 4) ~= 0, band(hi, 2) ~= 0, band(hi, 1) ~= 0)
            end
        elseif top == 4 then
            h = makeBlock(band(hi, 0x10) ~= 0, band(hi, 8) ~= 0, band(hi, 4) ~= 0, band(hi, 2) ~= 0, band(hi, 1) ~= 0)
        elseif top == 5 then h = armBranch
        elseif top == 6 then h = armUndefined
        else
            if band(hi, 0x10) ~= 0 then h = armSWI else h = armUndefined end
        end
        ARM[idx + 1] = h
    end
    op2Fns = nil

    ----------------------------------------------------------------------------
    -- Thumb instructions: table indexed by bits 15-6 of the opcode
    ----------------------------------------------------------------------------
    local THUMB = table.create(1024)
    local function tShift(typ)
        return function(op)
            local rd, rs, amt = band(op, 7), band(rsh(op, 3), 7), band(rsh(op, 6), 31)
            local r, c = shiftImm(typ, R[rs + 1], amt)
            R[rd + 1] = r
            fN = r >= 0x80000000; fZ = r == 0; fC = c
        end
    end
    local function tAddSub(imm, sub)
        return function(op)
            local rd, rs, rn = band(op, 7), band(rsh(op, 3), 7), band(rsh(op, 6), 7)
            local a = R[rs + 1]
            local b = imm and rn or R[rn + 1]
            if sub then R[rd + 1] = subFlags(a, b, a - b) else R[rd + 1] = addFlags(a, b, a + b) end
        end
    end
    local function tImm(kind)
        return function(op)
            local rd, imm = band(rsh(op, 8), 7), band(op, 0xFF)
            local a = R[rd + 1]
            if kind == 0 then R[rd + 1] = imm; fN = false; fZ = imm == 0
            elseif kind == 1 then subFlags(a, imm, a - imm)
            elseif kind == 2 then R[rd + 1] = addFlags(a, imm, a + imm)
            else R[rd + 1] = subFlags(a, imm, a - imm) end
        end
    end
    local function tALU(op)
        local rd, rs = band(op, 7), band(rsh(op, 3), 7)
        local k = band(rsh(op, 6), 15)
        local a, b = R[rd + 1], R[rs + 1]
        local r
        if k == 0 then r = band(a, b)
        elseif k == 1 then r = bxor(a, b)
        elseif k == 2 then r, fC = shiftReg(0, a, band(b, 0xFF)); cycles += 1
        elseif k == 3 then r, fC = shiftReg(1, a, band(b, 0xFF)); cycles += 1
        elseif k == 4 then r, fC = shiftReg(2, a, band(b, 0xFF)); cycles += 1
        elseif k == 5 then R[rd + 1] = addFlags(a, b, a + b + (fC and 1 or 0)); return
        elseif k == 6 then R[rd + 1] = subFlags(a, b, a - b - (fC and 0 or 1)); return
        elseif k == 7 then r, fC = shiftReg(3, a, band(b, 0xFF)); cycles += 1
        elseif k == 8 then r = band(a, b); fN = r >= 0x80000000; fZ = r == 0; return
        elseif k == 9 then R[rd + 1] = subFlags(0, b, -b); return
        elseif k == 10 then subFlags(a, b, a - b); return
        elseif k == 11 then addFlags(a, b, a + b); return
        elseif k == 12 then r = bor(a, b)
        elseif k == 13 then r = mul32(a, b); cycles += mulCycles(a)
        elseif k == 14 then r = band(a, bnot(b))
        else r = band(bnot(b), 0xFFFFFFFF) end
        R[rd + 1] = r
        fN = r >= 0x80000000; fZ = r == 0
    end
    local function tHi(op)
        local k = band(rsh(op, 8), 3)
        local rd = bor(band(op, 7), band(rsh(op, 4), 8))
        local rs = band(rsh(op, 3), 15)
        local b = R[rs + 1]
        if k == 0 then
            local r = band(R[rd + 1] + b, 0xFFFFFFFF)
            if rd == 15 then writePC(r) else R[rd + 1] = r end
        elseif k == 1 then
            local a = R[rd + 1]
            subFlags(a, b, a - b)
        elseif k == 2 then
            if rd == 15 then writePC(b) else R[rd + 1] = b end
        else
            if band(b, 1) ~= 0 then pc = band(b, 0xFFFFFFFE) else thumb = false; pc = band(b, 0xFFFFFFFC) end
            cycles += 2
        end
    end
    local function tLdrPC(op)
        local rd = band(rsh(op, 8), 7)
        R[rd + 1] = read32(band(R[16], 0xFFFFFFFC) + band(op, 0xFF) * 4)
        cycles += 1
    end
    local function tMemReg(op)
        local rd, rb, ro = band(op, 7), band(rsh(op, 3), 7), band(rsh(op, 6), 7)
        local addr = band(R[rb + 1] + R[ro + 1], 0xFFFFFFFF)
        local k = band(rsh(op, 9), 7)
        if k == 0 then write32(addr, R[rd + 1])
        elseif k == 1 then write16(addr, band(R[rd + 1], 0xFFFF))
        elseif k == 2 then write8(addr, band(R[rd + 1], 0xFF))
        elseif k == 3 then
            local v = read8(addr); if v >= 0x80 then v += 0xFFFFFF00 end
            R[rd + 1] = v; cycles += 1
        elseif k == 4 then
            local v = read32(band(addr, 0xFFFFFFFC))
            local rot = band(addr, 3)
            if rot ~= 0 then v = rrot(v, 8 * rot) end
            R[rd + 1] = v; cycles += 1
        elseif k == 5 then
            local v = read16(band(addr, 0xFFFFFFFE))
            if band(addr, 1) ~= 0 then v = rrot(v, 8) end
            R[rd + 1] = v; cycles += 1
        elseif k == 6 then R[rd + 1] = read8(addr); cycles += 1
        else
            local v
            if band(addr, 1) ~= 0 then v = read8(addr); if v >= 0x80 then v += 0xFFFFFF00 end
            else v = read16(addr); if v >= 0x8000 then v += 0xFFFF0000 end end
            R[rd + 1] = v; cycles += 1
        end
    end
    local function tMemImm(byte, load)
        return function(op)
            local rd, rb, off = band(op, 7), band(rsh(op, 3), 7), band(rsh(op, 6), 31)
            if byte then
                local addr = band(R[rb + 1] + off, 0xFFFFFFFF)
                if load then R[rd + 1] = read8(addr); cycles += 1 else write8(addr, band(R[rd + 1], 0xFF)) end
            else
                local addr = band(R[rb + 1] + off * 4, 0xFFFFFFFF)
                if load then
                    local v = read32(band(addr, 0xFFFFFFFC))
                    local rot = band(addr, 3)
                    if rot ~= 0 then v = rrot(v, 8 * rot) end
                    R[rd + 1] = v; cycles += 1
                else write32(addr, R[rd + 1]) end
            end
        end
    end
    local function tMemHalf(load)
        return function(op)
            local rd, rb, off = band(op, 7), band(rsh(op, 3), 7), band(rsh(op, 6), 31)
            local addr = band(R[rb + 1] + off * 2, 0xFFFFFFFF)
            if load then
                local v = read16(band(addr, 0xFFFFFFFE))
                if band(addr, 1) ~= 0 then v = rrot(v, 8) end
                R[rd + 1] = v; cycles += 1
            else write16(addr, band(R[rd + 1], 0xFFFF)) end
        end
    end
    local function tMemSP(load)
        return function(op)
            local rd = band(rsh(op, 8), 7)
            local addr = band(R[14] + band(op, 0xFF) * 4, 0xFFFFFFFF)
            if load then
                local v = read32(band(addr, 0xFFFFFFFC))
                local rot = band(addr, 3)
                if rot ~= 0 then v = rrot(v, 8 * rot) end
                R[rd + 1] = v; cycles += 1
            else write32(addr, R[rd + 1]) end
        end
    end
    local function tAddr(sp)
        return function(op)
            local rd = band(rsh(op, 8), 7)
            if sp then R[rd + 1] = band(R[14] + band(op, 0xFF) * 4, 0xFFFFFFFF)
            else R[rd + 1] = band(R[16], 0xFFFFFFFC) + band(op, 0xFF) * 4 end
        end
    end
    local function tSPAdd(op)
        local off = band(op, 0x7F) * 4
        if band(op, 0x80) ~= 0 then R[14] = band(R[14] - off, 0xFFFFFFFF) else R[14] = band(R[14] + off, 0xFFFFFFFF) end
    end
    local function tPush(op)
        local list = band(op, 0xFF)
        local lr = band(op, 0x100) ~= 0
        local n = 0
        for k = 0, 7 do if band(list, lsh(1, k)) ~= 0 then n += 1 end end
        if lr then n += 1 end
        local sp = band(R[14] - n * 4, 0xFFFFFFFF)
        local addr = sp
        for k = 0, 7 do
            if band(list, lsh(1, k)) ~= 0 then write32(addr, R[k + 1]); addr += 4 end
        end
        if lr then write32(addr, R[15]) end
        if n == 0 then -- empty list: r15 is stored and sp moves by 0x40
            sp = band(R[14] - 0x40, 0xFFFFFFFF)
            write32(band(sp, 0xFFFFFFFC), R[16] + 2)
        end
        R[14] = sp
    end
    local function tPop(op)
        local list = band(op, 0xFF)
        local pcBit = band(op, 0x100) ~= 0
        local addr = R[14]
        if list == 0 and not pcBit then
            writePC(read32(band(addr, 0xFFFFFFFC)))
            R[14] = band(addr + 0x40, 0xFFFFFFFF)
            return
        end
        for k = 0, 7 do
            if band(list, lsh(1, k)) ~= 0 then R[k + 1] = read32(band(addr, 0xFFFFFFFC)); addr += 4 end
        end
        if pcBit then
            local v = read32(band(addr, 0xFFFFFFFC))
            addr += 4
            pc = band(v, 0xFFFFFFFE) -- ARMv4: POP {pc} stays in Thumb
            cycles += 2
        end
        R[14] = band(addr, 0xFFFFFFFF)
        cycles += 1
    end
    local function tBlock(load)
        return function(op)
            local rb = band(rsh(op, 8), 7)
            local list = band(op, 0xFF)
            local addr = R[rb + 1]
            if list == 0 then
                if load then writePC(read32(band(addr, 0xFFFFFFFC))) else write32(addr, R[16] + 2) end
                R[rb + 1] = band(addr + 0x40, 0xFFFFFFFF)
                return
            end
            local n = 0
            for k = 0, 7 do if band(list, lsh(1, k)) ~= 0 then n += 1 end end
            local final = band(addr + n * 4, 0xFFFFFFFF)
            if load then
                for k = 0, 7 do
                    if band(list, lsh(1, k)) ~= 0 then R[k + 1] = read32(band(addr, 0xFFFFFFFC)); addr += 4 end
                end
                if band(list, lsh(1, rb)) == 0 then R[rb + 1] = final end
                cycles += 1
            else
                local first = true
                for k = 0, 7 do
                    if band(list, lsh(1, k)) ~= 0 then
                        local v = R[k + 1]
                        if k == rb and not first then v = final end
                        write32(addr, v)
                        addr += 4
                        first = false
                    end
                end
                R[rb + 1] = final
            end
        end
    end
    local function tCondBranch(cond)
        return function(op)
            if condPass(cond) then
                local off = band(op, 0xFF)
                if off >= 0x80 then off -= 0x100 end
                pc = band(R[16] + off * 2, 0xFFFFFFFF)
                cycles += 2
            end
        end
    end
    local function tSWI() exception(0x08, 0x13, pc) end
    local function tB(op)
        local off = band(op, 0x7FF)
        if off >= 0x400 then off -= 0x800 end
        pc = band(R[16] + off * 2, 0xFFFFFFFF)
        cycles += 2
    end
    local function tBL1(op)
        local off = band(op, 0x7FF)
        if off >= 0x400 then off -= 0x800 end
        R[15] = band(R[16] + off * 4096, 0xFFFFFFFF)
    end
    local function tBL2(op)
        local target = band(R[15] + band(op, 0x7FF) * 2, 0xFFFFFFFF)
        R[15] = bor(pc, 1)
        pc = band(target, 0xFFFFFFFE)
        cycles += 2
    end
    local function tUndefined() exception(0x04, 0x1B, pc) end

    for idx = 0, 1023 do
        local op = idx * 64
        local h
        local t5 = rsh(op, 11)
        if t5 <= 2 then h = tShift(t5)
        elseif t5 == 3 then h = tAddSub(band(op, 0x400) ~= 0, band(op, 0x200) ~= 0)
        elseif t5 <= 7 then h = tImm(t5 - 4)
        elseif rsh(op, 10) == 0x10 then h = tALU
        elseif rsh(op, 10) == 0x11 then h = tHi
        elseif t5 == 9 then h = tLdrPC
        elseif rsh(op, 12) == 5 then h = tMemReg
        elseif rsh(op, 13) == 3 then h = tMemImm(band(op, 0x1000) ~= 0, band(op, 0x800) ~= 0)
        elseif rsh(op, 12) == 8 then h = tMemHalf(band(op, 0x800) ~= 0)
        elseif rsh(op, 12) == 9 then h = tMemSP(band(op, 0x800) ~= 0)
        elseif rsh(op, 12) == 10 then h = tAddr(band(op, 0x800) ~= 0)
        elseif rsh(op, 8) == 0xB0 then h = tSPAdd
        elseif band(rsh(op, 8), 0xF6) == 0xB4 then h = band(op, 0x800) ~= 0 and tPop or tPush
        elseif rsh(op, 12) == 12 then h = tBlock(band(op, 0x800) ~= 0)
        elseif rsh(op, 12) == 13 then
            local cond = band(rsh(op, 8), 15)
            if cond == 15 then h = tSWI elseif cond == 14 then h = tUndefined else h = tCondBranch(cond) end
        elseif t5 == 0x1C then h = tB
        elseif t5 == 0x1E then h = tBL1
        elseif t5 == 0x1F then h = tBL2
        else h = tUndefined end
        THUMB[idx + 1] = h
    end

    ----------------------------------------------------------------------------
    -- run loop
    ----------------------------------------------------------------------------
    local function runCycles(n)
        local stop = cycles + n
        while cycles < stop do
            local target = stop
            local horizon = timerHorizon()
            if cycles + horizon < target then target = cycles + math.max(1, horizon) end
            while cycles < target do
                if halted then
                    if band(IE, IF) ~= 0 then halted = false
                    else cycles = target; break end
                end
                if irqLine and not iDis then exception(0x18, 0x12, pc + 4) end
                local p = pc
                if inBios then
                    if p >= 0x4000 then leaveBios() end
                elseif p < 0x4000 then inBios = true end
                if thumb then
                    local op
                    local r = rsh(p, 24)
                    if r >= 8 and r < 14 then
                        local o = band(p, 0x1FFFFFE)
                        op = o < romSize and rd16(rom, o) or romOpen16(o)
                        cycles += 2
                    elseif r == 3 then op = rd16(iwram, band(p, 0x7FFE)); cycles += 1
                    elseif r == 2 then op = rd16(ewram, band(p, 0x3FFFE)); cycles += 3
                    else op = read16(p) end
                    R[16] = p + 4
                    pc = p + 2
                    THUMB[rsh(op, 6) + 1](op)
                else
                    local op
                    local r = rsh(p, 24)
                    if r >= 8 and r < 14 then
                        local o = band(p, 0x1FFFFFC)
                        op = o < romSize and rd32(rom, o) or (romOpen16(o) + romOpen16(o + 2) * 65536)
                        cycles += 4
                    elseif r == 3 then op = rd32(iwram, band(p, 0x7FFC)); cycles += 1
                    elseif r == 0 then
                        op = rd32(bios, band(p, 0x3FFC))
                        cycles += 1
                    elseif r == 2 then op = rd32(ewram, band(p, 0x3FFFC)); cycles += 6
                    else op = read32(p) end
                    R[16] = p + 8
                    pc = p + 4
                    local cond = rsh(op, 28)
                    if cond == 14 or condPass(cond) then
                        ARM[bor(band(rsh(op, 16), 0xFF0), band(rsh(op, 4), 15)) + 1](op)
                    end
                end
            end
            timersUpdate()
        end
    end

    ----------------------------------------------------------------------------
    -- video timing, start-up state and the outside interface
    ----------------------------------------------------------------------------
    local fb = buffer.create(240 * 160 * 4)
    ppu = makePPU(io, pram, vram, oam, fb, pal15, vflags)
    emu.fb = fb

    -- direct boot: the state the BIOS leaves behind before it jumps to the cartridge
    bankSP[3] = 0x03007FE0 -- SVC
    bankSP[2] = 0x03007FA0 -- IRQ
    mode = 0x1F
    R[14] = 0x03007F00
    pc = 0x08000000
    wr16(io, 0x88, 0x200) -- SOUNDBIAS
    -- the BIOS leaves the affine backgrounds at scale 1
    wr16(io, 0x20, 0x100); wr16(io, 0x26, 0x100); wr16(io, 0x30, 0x100); wr16(io, 0x36, 0x100)
    biosLatch = 0xE129F000

    function emu.runFrame(render)
        local dispstat
        for line = 0, 227 do
            vcount = line
            dispstat = rd16(io, 4)
            vMatch = rsh(dispstat, 8) == line
            if vMatch and band(dispstat, 0x20) ~= 0 then raise(4) end
            if line == 160 then
                inVBlank = true
                if band(dispstat, 8) ~= 0 then raise(1) end
                dmaTrigger(1)
                ppu.vblank()
            elseif line == 227 then
                inVBlank = false
            end
            inHBlank = false
            runCycles(960)
            if line < 160 then ppu.line(line, render) end
            inHBlank = true
            if band(rd16(io, 4), 0x10) ~= 0 then raise(2) end
            if line < 160 then dmaTrigger(2) end
            runCycles(272)
        end
        inHBlank = false
    end
    -- debugging: run single instructions, calling fn(pc, thumb, opcode) before each
    function emu.trace(count, fn)
        for _ = 1, count do
            if irqLine and not iDis then exception(0x18, 0x12, pc + 4) end
            local p = pc
            if thumb then
                local op = read16(p)
                fn(p, true, op)
                R[16] = p + 4; pc = p + 2
                THUMB[rsh(op, 6) + 1](op)
            else
                local op = read32(p)
                fn(p, false, op)
                R[16] = p + 8; pc = p + 4
                local cond = rsh(op, 28)
                if cond == 14 or condPass(cond) then ARM[bor(band(rsh(op, 16), 0xFF0), band(rsh(op, 4), 15)) + 1](op) end
            end
        end
    end
    function emu.setKeys(mask) keys = band(mask, 0x3FF) end
    function emu.reg(n) return R[n + 1] end
    function emu.io16(off) return ioRead16(off) end
    function emu.pc() return pc end
    function emu.cpsr() return getCPSR() end
    function emu.cycles() return cycles end
    emu.saveType = save.kind
    function emu.saveData() return save.data() end
    function emu.saveDirty() return save.dirty() end
    function emu.clearSaveDirty() save.clearDirty() end
    -- runs instructions until pc stays in place (a test ROM's idle loop) or the limit is reached
    function emu.runUntilIdle(maxFrames)
        for _ = 1, maxFrames do
            emu.runFrame(false)
            local p = pc
            local same = true
            for _ = 1, 4 do
                runCycles(8)
                if pc ~= p and pc ~= p + (thumb and 2 or 4) then same = false end
            end
            if same then return true end
        end
        return false
    end
    return emu
end

--------------------------------------------------------------------------------
-- video: one scanline at a time into fb (RGBA)
--------------------------------------------------------------------------------
-- 15-bit colour -> RGBA as a little-endian u32 (r, g, b, 255)
local RGBA = table.create(32768)
for c = 0, 32767 do
    local r, g, b = band(c, 31), band(rsh(c, 5), 31), band(rsh(c, 10), 31)
    RGBA[c + 1] = bor(lsh(r, 3), rsh(r, 2)) + bor(lsh(g, 3), rsh(g, 2)) * 256 + bor(lsh(b, 3), rsh(b, 2)) * 65536 + 0xFF000000
end
local OBJ_W = { [0] = { 8, 16, 32, 64 }, { 16, 32, 32, 64 }, { 8, 8, 16, 32 } }
local OBJ_H = { [0] = { 8, 16, 32, 64 }, { 8, 8, 16, 32 }, { 16, 32, 32, 64 } }

makePPU = function(io, pram, vram, oam, fb, pal15, vflags)
    local function s16(buf, off)
        local v = rd16(buf, off)
        if v >= 0x8000 then v -= 0x10000 end
        return v
    end
    local function s28(off)
        local v = band(rd32(io, off), 0x0FFFFFFF)
        if v >= 0x08000000 then v -= 0x10000000 end
        return v
    end
    local refX, refY = { [2] = 0, [3] = 0 }, { [2] = 0, [3] = 0 }
    local function latch(n)
        local base = n == 2 and 0x28 or 0x38
        refX[n] = s28(base)
        refY[n] = s28(base + 4)
    end

    local out = table.create(240, 0)
    local bgBuf = { [0] = table.create(240, -1), table.create(240, -1), table.create(240, -1), table.create(240, -1) }
    local objCol, objPrio, objSemi, objWin = table.create(240, -1), table.create(240, 4), table.create(240, false), table.create(240, false)
    local objPrioUsed, anySemi, objMin, objMax = 0, false, 241, 0
    local bgPrio = { [0] = 0, 0, 0, 0 }
    local topC, topL, secC, secL = table.create(240, 0), table.create(240, 5), table.create(240, 0), table.create(240, 5)
    local wmaskA = table.create(240, 0x3F)

    -- text background n, line y: opaque pixels into dst (1-based x)
    local function textBG(n, y, dst)
        local cnt = rd16(io, 8 + n * 2)
        local hofs = band(rd16(io, 0x10 + n * 4), 0x1FF)
        local vofs = band(rd16(io, 0x12 + n * 4), 0x1FF)
        local charBase = band(rsh(cnt, 2), 3) * 0x4000
        local screenBase = band(rsh(cnt, 8), 31) * 0x800
        local c256 = band(cnt, 0x80) ~= 0
        local size = rsh(cnt, 14)
        local wide, tall = size == 1 or size == 3, size >= 2
        local wmask = wide and 511 or 255
        local sy = band(y + vofs, tall and 511 or 255)
        local rowBase = screenBase + band(rsh(sy, 3), 31) * 64
        if sy >= 256 then rowBase += wide and 0x1000 or 0x800 end
        local fineY = band(sy, 7)
        local x = 0
        local sx = band(hofs, wmask)
        while x < 240 do
            local entryAddr = rowBase + rsh(band(sx, 255), 3) * 2
            if sx >= 256 then entryAddr += 0x800 end
            local entry = rd16(vram, band(entryAddr, 0xFFFF))
            local tile = band(entry, 0x3FF)
            local hflip = band(entry, 0x400) ~= 0
            local row = band(entry, 0x800) ~= 0 and (7 - fineY) or fineY
            local px = band(sx, 7)
            local count = 8 - px
            if count > 240 - x then count = 240 - x end
            local o = x + 1 - px -- dst index of tile pixel 0
            if c256 then
                local addr = charBase + tile * 64 + row * 8
                if addr < 0x10000 then
                    for k = px, px + count - 1 do
                        local idx = rd8(vram, addr + (hflip and 7 - k or k))
                        if idx ~= 0 then dst[o + k] = pal15[idx + 1] end
                    end
                end
            else
                local addr = charBase + tile * 32 + row * 4
                if addr < 0x10000 then
                    local bits = rd32(vram, addr)
                    if bits ~= 0 then
                        local pb = rsh(entry, 12) * 16 + 1
                        if hflip then
                            for k = px, px + count - 1 do
                                local idx = band(rsh(bits, (7 - k) * 4), 15)
                                if idx ~= 0 then dst[o + k] = pal15[pb + idx] end
                            end
                        else
                            for k = px, px + count - 1 do
                                local idx = band(rsh(bits, k * 4), 15)
                                if idx ~= 0 then dst[o + k] = pal15[pb + idx] end
                            end
                        end
                    end
                end
            end
            x += count
            sx = band(sx + count, wmask)
        end
    end

    local function affineBG(n, dst)
        local cnt = rd16(io, 8 + n * 2)
        local charBase = band(rsh(cnt, 2), 3) * 0x4000
        local screenBase = band(rsh(cnt, 8), 31) * 0x800
        local size = lsh(128, rsh(cnt, 14))
        local mask = size - 1
        local tilesPerRow = rsh(size, 3)
        local wrap = band(cnt, 0x2000) ~= 0
        local base = n == 2 and 0x20 or 0x30
        local pa, pc = s16(io, base), s16(io, base + 4)
        local fx, fy = refX[n], refY[n]
        for x = 1, 240 do
            local px, py = fx // 256, fy // 256
            fx += pa; fy += pc
            local inside = true
            if wrap then px = band(px, mask); py = band(py, mask)
            elseif px < 0 or py < 0 or px >= size or py >= size then inside = false end
            if inside then
                local tile = rd8(vram, band(screenBase + rsh(py, 3) * tilesPerRow + rsh(px, 3), 0xFFFF))
                local idx = rd8(vram, band(charBase + tile * 64 + band(py, 7) * 8 + band(px, 7), 0xFFFF))
                if idx ~= 0 then dst[x] = pal15[idx + 1] end
            end
        end
    end

    -- modes 3-5 (background 2 as a bitmap, with its affine transform)
    local function bitmapBG(bgMode, dst, dispcnt)
        local w, h = 240, 160
        local page = 0
        if bgMode == 5 then w, h = 160, 128 end
        if bgMode ~= 3 and band(dispcnt, 0x10) ~= 0 then page = 0xA000 end
        local pa, pc = s16(io, 0x20), s16(io, 0x24)
        local x0, y0 = refX[2], refY[2]
        if pa == 256 and pc == 0 and x0 % 256 == 0 and y0 % 256 == 0 then
            local py = y0 // 256
            if py < 0 or py >= h then return end
            local sx = x0 // 256
            local x1, x2 = math.max(0, -sx), math.min(239, w - 1 - sx)
            if bgMode == 4 then
                local rowA = page + py * 240 + sx
                for x = x1, x2 do
                    local idx = rd8(vram, rowA + x)
                    if idx ~= 0 then dst[x + 1] = pal15[idx + 1] end
                end
            else
                local rowA = page + (py * w + sx) * 2
                for x = x1, x2 do dst[x + 1] = band(rd16(vram, rowA + x * 2), 0x7FFF) end
            end
            return
        end
        local fx, fy = x0, y0
        for x = 1, 240 do
            local px, py = fx // 256, fy // 256
            fx += pa; fy += pc
            if px >= 0 and py >= 0 and px < w and py < h then
                if bgMode == 4 then
                    local idx = rd8(vram, page + py * 240 + px)
                    if idx ~= 0 then dst[x] = pal15[idx + 1] end
                else
                    dst[x] = band(rd16(vram, page + (py * w + px) * 2), 0x7FFF)
                end
            end
        end
    end

    -- sprites: OAM decoded once (again only after it changes)
    local spr = {}
    for i = 1, 128 do spr[i] = {} end
    local sprList, sprN = table.create(128, 0), 0
    local function decodeOAM()
        vflags.oam = false
        sprN = 0
        for i = 0, 127 do
            local base = i * 8
            local a0 = rd16(oam, base)
            local affine = band(a0, 0x100) ~= 0
            local omode = band(rsh(a0, 10), 3)
            local shape = rsh(a0, 14)
            if (affine or band(a0, 0x200) == 0) and omode ~= 3 and shape ~= 3 then
                local a1, a2 = rd16(oam, base + 2), rd16(oam, base + 4)
                local sz = rsh(a1, 14) + 1
                local w, h = OBJ_W[shape][sz], OBJ_H[shape][sz]
                local bw, bh = w, h
                if affine and band(a0, 0x200) ~= 0 then bw, bh = w * 2, h * 2 end
                local oy = band(a0, 0xFF)
                if oy >= 160 then oy -= 256 end
                local ox = band(a1, 0x1FF)
                if ox >= 240 then ox -= 512 end
                if ox < 240 and ox + bw > 0 and oy + bh > 0 then
                    local s = spr[i + 1]
                    s.oy, s.ox, s.w, s.h, s.bw, s.bh = oy, ox, w, h, bw, bh
                    s.affine, s.mode = affine, omode
                    s.c256 = band(a0, 0x2000) ~= 0
                    s.tile = band(a2, 0x3FF)
                    s.prio = band(rsh(a2, 10), 3)
                    s.pal = s.c256 and 257 or (257 + rsh(a2, 12) * 16)
                    s.hflip, s.vflip = band(a1, 0x1000) ~= 0, band(a1, 0x2000) ~= 0
                    if affine then
                        local p = rsh(band(a1, 0x3E00), 9) * 32
                        s.pa, s.pb, s.pc, s.pd = s16(oam, p + 6), s16(oam, p + 14), s16(oam, p + 22), s16(oam, p + 30)
                    end
                    sprN += 1
                    sprList[sprN] = s
                end
            end
        end
    end

    local function objLine(y, oneD, bitmap)
        if vflags.oam then decodeOAM() end
        for x = objMin, objMax do objCol[x] = -1; objPrio[x] = 4; objSemi[x] = false; objWin[x] = false end
        objPrioUsed, anySemi, objMin, objMax = 0, false, 241, 0
        for k = 1, sprN do
            local s = sprList[k]
            local dy = y - s.oy
            if dy >= 0 and dy < s.bh and not (bitmap and s.tile < 512) then
                local ox, w, h, bw, bh = s.ox, s.w, s.h, s.bw, s.bh
                local c256, tile, prio, pal = s.c256, s.tile, s.prio, s.pal
                local step = c256 and 2 or 1
                local rowTiles = oneD and rsh(w, 3) * step or 32
                local x1, x2 = math.max(0, -ox), math.min(bw, 240 - ox) - 1
                local winMode, semi = s.mode == 2, s.mode == 1
                if semi then anySemi = true end
                if ox + x1 + 1 < objMin then objMin = ox + x1 + 1 end
                if ox + x2 + 1 > objMax then objMax = ox + x2 + 1 end
                local affine = s.affine
                local pa, pb, pc, pd = s.pa, s.pb, s.pc, s.pd
                local tyFixed
                if not affine then tyFixed = s.vflip and (h - 1 - dy) or dy end
                local hflip = s.hflip
                local rowTileBase = 0
                if not affine then rowTileBase = tile + rsh(tyFixed, 3) * rowTiles end
                for px = x1, x2 do
                    local tx, ty
                    if affine then
                        local dx, dyy = px - bw // 2, dy - bh // 2
                        tx = (pa * dx + pb * dyy) // 256 + w // 2
                        ty = (pc * dx + pd * dyy) // 256 + h // 2
                    else
                        tx = hflip and (w - 1 - px) or px
                        ty = tyFixed
                    end
                    if tx >= 0 and tx < w and ty >= 0 and ty < h then
                        local t
                        if affine then t = band(tile + rsh(ty, 3) * rowTiles + rsh(tx, 3) * step, 0x3FF)
                        else t = band(rowTileBase + rsh(tx, 3) * step, 0x3FF) end
                        local idx
                        if c256 then
                            idx = rd8(vram, 0x10000 + band(t, 0x3FE) * 32 + band(ty, 7) * 8 + band(tx, 7))
                        else
                            local b = rd8(vram, 0x10000 + t * 32 + band(ty, 7) * 4 + rsh(band(tx, 7), 1))
                            idx = band(tx, 1) == 1 and rsh(b, 4) or band(b, 15)
                        end
                        if idx ~= 0 then
                            local x = ox + px + 1
                            if winMode then
                                objWin[x] = true
                            elseif prio < objPrio[x] then
                                objCol[x] = pal15[pal + idx]
                                objPrio[x] = prio
                                objSemi[x] = semi
                                objPrioUsed = bor(objPrioUsed, lsh(1, prio))
                            end
                        end
                    end
                end
            end
        end
    end

    local function blendA(a, b, eva, evb)
        local r = (band(a, 31) * eva + band(b, 31) * evb) // 16
        local g = (band(rsh(a, 5), 31) * eva + band(rsh(b, 5), 31) * evb) // 16
        local bl = (band(rsh(a, 10), 31) * eva + band(rsh(b, 10), 31) * evb) // 16
        if r > 31 then r = 31 end
        if g > 31 then g = 31 end
        if bl > 31 then bl = 31 end
        return r + g * 32 + bl * 1024
    end
    local function brighten(a, evy)
        local r, g, b = band(a, 31), band(rsh(a, 5), 31), band(rsh(a, 10), 31)
        r += (31 - r) * evy // 16; g += (31 - g) * evy // 16; b += (31 - b) * evy // 16
        return r + g * 32 + b * 1024
    end
    local function darken(a, evy)
        local r, g, b = band(a, 31), band(rsh(a, 5), 31), band(rsh(a, 10), 31)
        r -= r * evy // 16; g -= g * evy // 16; b -= b * evy // 16
        return r + g * 32 + b * 1024
    end

    local on = { [0] = false, false, false, false }
    local function drawLine(y)
        local dispcnt = rd16(io, 0)
        local row = y * 960
        if band(dispcnt, 0x80) ~= 0 then
            for x = 0, 239 do wr32(fb, row + x * 4, 0xFFFFFFFF) end
            return
        end
        local bgMode = band(dispcnt, 7)
        local bitmap = bgMode >= 3
        for n = 0, 3 do on[n] = false end
        if bgMode == 0 then for n = 0, 3 do on[n] = band(dispcnt, lsh(0x100, n)) ~= 0 end
        elseif bgMode == 1 then for n = 0, 2 do on[n] = band(dispcnt, lsh(0x100, n)) ~= 0 end
        elseif bgMode == 2 then on[2] = band(dispcnt, 0x400) ~= 0; on[3] = band(dispcnt, 0x800) ~= 0
        elseif bgMode <= 5 then on[2] = band(dispcnt, 0x400) ~= 0 end
        for n = 0, 3 do bgPrio[n] = band(rd16(io, 8 + n * 2), 3) end
        local objOn = band(dispcnt, 0x1000) ~= 0
        local winAny = band(dispcnt, 0xE000) ~= 0
        if objOn or band(dispcnt, 0x8000) ~= 0 then objLine(y, band(dispcnt, 0x40) ~= 0, bitmap)
        else
            for x = objMin, objMax do objCol[x] = -1; objPrio[x] = 4; objSemi[x] = false; objWin[x] = false end
            objPrioUsed, anySemi, objMin, objMax = 0, false, 241, 0
        end
        local bldcnt = rd16(io, 0x50)
        local effect = band(rsh(bldcnt, 6), 3)
        -- brighten / darken at strength 0 change nothing (games often leave them set)
        if effect >= 2 and band(rd16(io, 0x54), 31) == 0 then effect = 0 end
        local backdrop = pal15[1]

        if not winAny and effect == 0 and not anySemi then
            -- plain layering: paint from the back
            for x = 1, 240 do out[x] = backdrop end
            for prio = 3, 0, -1 do
                for n = 3, 0, -1 do
                    if on[n] and bgPrio[n] == prio then
                        if bgMode == 0 or (bgMode == 1 and n < 2) then textBG(n, y, out)
                        elseif bitmap then bitmapBG(bgMode, out, dispcnt)
                        else affineBG(n, out) end
                    end
                end
                if objOn and band(objPrioUsed, lsh(1, prio)) ~= 0 then
                    for x = objMin, objMax do
                        if objPrio[x] == prio then out[x] = objCol[x] end
                    end
                end
            end
            for x = 0, 239 do wr32(fb, row + x * 4, RGBA[out[x + 1] + 1]) end
            return
        end

        -- windows / colour effects: keep the top two layers of every pixel
        if winAny then
            local winin, winout = rd16(io, 0x48), rd16(io, 0x4A)
            local inside0, inside1 = band(winin, 0x3F), band(rsh(winin, 8), 0x3F)
            local outside, objIn = band(winout, 0x3F), band(rsh(winout, 8), 0x3F)
            for x = 1, 240 do wmaskA[x] = outside end
            if band(dispcnt, 0x8000) ~= 0 then
                for x = objMin, objMax do if objWin[x] then wmaskA[x] = objIn end end
            end
            for wi = 1, 0, -1 do -- window 1 first, so window 0 wins where they overlap
                if band(dispcnt, lsh(0x2000, wi)) ~= 0 then
                    local v = rd16(io, 0x44 + wi * 2)
                    local y1, y2 = rsh(v, 8), band(v, 0xFF)
                    if y2 > 160 then y2 = 160 end
                    local yin
                    if y1 <= y2 then yin = y >= y1 and y < y2 else yin = y >= y1 or y < y2 end
                    if yin then
                        local hv = rd16(io, 0x40 + wi * 2)
                        local x1, x2 = rsh(hv, 8), band(hv, 0xFF)
                        if x2 > 240 then x2 = 240 end
                        local m = wi == 0 and inside0 or inside1
                        if x1 <= x2 then
                            for x = x1 + 1, x2 do wmaskA[x] = m end
                        else
                            for x = x1 + 1, 240 do wmaskA[x] = m end
                            for x = 1, x2 do wmaskA[x] = m end
                        end
                    end
                end
            end
        end
        for x = 1, 240 do topC[x] = backdrop; topL[x] = 5; secC[x] = backdrop; secL[x] = 5 end
        for prio = 3, 0, -1 do
            for n = 3, 0, -1 do
                if on[n] and bgPrio[n] == prio then
                    local buf = bgBuf[n]
                    for x = 1, 240 do buf[x] = -1 end
                    if bgMode == 0 or (bgMode == 1 and n < 2) then textBG(n, y, buf)
                    elseif bitmap then bitmapBG(bgMode, buf, dispcnt)
                    else affineBG(n, buf) end
                    local bit = lsh(1, n)
                    for x = 1, 240 do
                        local c = buf[x]
                        if c >= 0 and (not winAny or band(wmaskA[x], bit) ~= 0) then
                            secC[x] = topC[x]; secL[x] = topL[x]; topC[x] = c; topL[x] = n
                        end
                    end
                end
            end
            if objOn and band(objPrioUsed, lsh(1, prio)) ~= 0 then
                for x = objMin, objMax do
                    if objPrio[x] == prio and (not winAny or band(wmaskA[x], 16) ~= 0) then
                        secC[x] = topC[x]; secL[x] = topL[x]; topC[x] = objCol[x]; topL[x] = 4
                    end
                end
            end
        end
        local bldalpha = rd16(io, 0x52)
        local eva, evb = math.min(band(bldalpha, 31), 16), math.min(band(rsh(bldalpha, 8), 31), 16)
        local evy = math.min(band(rd16(io, 0x54), 31), 16)
        local t1, t2 = band(bldcnt, 0x3F), band(rsh(bldcnt, 8), 0x3F)
        for x = 1, 240 do
            local c, l = topC[x], topL[x]
            if not winAny or band(wmaskA[x], 32) ~= 0 then
                if l == 4 and objSemi[x] and band(t2, lsh(1, secL[x])) ~= 0 then
                    c = blendA(c, secC[x], eva, evb)
                elseif effect ~= 0 and band(t1, lsh(1, l)) ~= 0 then
                    if effect == 1 then
                        if band(t2, lsh(1, secL[x])) ~= 0 then c = blendA(c, secC[x], eva, evb) end
                    elseif effect == 2 then c = brighten(c, evy)
                    else c = darken(c, evy) end
                end
            end
            wr32(fb, row + (x - 1) * 4, RGBA[c + 1])
        end
    end

    local ppu = {}
    function ppu.line(y, render)
        if render then drawLine(y) end
        -- the affine reference points move on by PB / PD every line
        refX[2] += s16(io, 0x22); refY[2] += s16(io, 0x26)
        refX[3] += s16(io, 0x32); refY[3] += s16(io, 0x36)
    end
    function ppu.vblank() latch(2); latch(3) end
    function ppu.refWritten(off)
        if off >= 0x28 and off <= 0x2E then latch(2) elseif off >= 0x38 and off <= 0x3E then latch(3) end
    end
    return ppu
end

--------------------------------------------------------------------------------
-- cartridge save memory: SRAM, Flash (64 / 128 KB) or EEPROM (512 B / 8 KB)
--------------------------------------------------------------------------------
makeSave = function(romStr, saveStr)
    local kind
    if romStr:find("EEPROM_V", 1, true) then kind = "eeprom"
    elseif romStr:find("FLASH1M_V", 1, true) then kind = "flash128"
    elseif romStr:find("FLASH512_V", 1, true) or romStr:find("FLASH_V", 1, true) then kind = "flash64"
    elseif romStr:find("SRAM_F_V", 1, true) or romStr:find("SRAM_V", 1, true) then kind = "sram"
    else kind = "unknown" end -- treated as SRAM, plus EEPROM once the game uses that port
    local romSize = #romStr
    local S = { kind = kind }
    local dirty = false
    local mem
    if kind == "flash128" then mem = buffer.create(0x20000); buffer.fill(mem, 0, 0xFF)
    elseif kind == "flash64" then mem = buffer.create(0x10000); buffer.fill(mem, 0, 0xFF)
    else mem = buffer.create(0x8000); buffer.fill(mem, 0, 0xFF) end
    local eep = buffer.create(0x2000)
    buffer.fill(eep, 0, 0xFF)
    local eepBits = 14
    local eepUsed, sramUsed = kind == "eeprom", kind == "sram"
    if type(saveStr) == "string" and #saveStr > 0 then
        if (kind == "eeprom" or kind == "unknown") and (#saveStr == 512 or #saveStr == 8192) then
            buffer.writestring(eep, 0, saveStr)
            eepBits = #saveStr == 512 and 6 or 14
            eepUsed = true
        else
            buffer.writestring(mem, 0, saveStr:sub(1, buffer.len(mem)))
            sramUsed = true
        end
    end

    -- Flash command state
    local fstate, idMode, eraseArmed, writeNext, bankNext, bank = 0, false, false, false, false, 0
    local ID = kind == "flash128" and { [0] = 0x62, 0x13 } or { [0] = 0x32, 0x1B }

    if kind == "flash64" or kind == "flash128" then
        function S.read8(a)
            local off = band(a, 0xFFFF)
            if idMode and off < 2 then return ID[off] end
            return rd8(mem, bank * 0x10000 + off)
        end
        function S.write8(a, v)
            local off = band(a, 0xFFFF)
            if writeNext then
                local p = bank * 0x10000 + off
                wr8(mem, p, band(rd8(mem, p), v))
                writeNext, dirty = false, true
                return
            end
            if bankNext then
                if off == 0 then bank = kind == "flash128" and band(v, 1) or 0 end
                bankNext = false
                return
            end
            if off == 0x5555 and v == 0xAA then fstate = 1; return end
            if fstate == 1 and off == 0x2AAA and v == 0x55 then fstate = 2; return end
            if fstate == 2 then
                fstate = 0
                if off == 0x5555 then
                    if v == 0x90 then idMode = true
                    elseif v == 0xF0 then idMode = false
                    elseif v == 0x80 then eraseArmed = true
                    elseif v == 0x10 and eraseArmed then buffer.fill(mem, 0, 0xFF); eraseArmed, dirty = false, true
                    elseif v == 0xA0 then writeNext = true
                    elseif v == 0xB0 then bankNext = true end
                elseif v == 0x30 and eraseArmed then
                    buffer.fill(mem, bank * 0x10000 + band(off, 0xF000), 0xFF, 0x1000)
                    eraseArmed, dirty = false, true
                end
                return
            end
            fstate = 0
        end
    else
        function S.read8(a) return rd8(mem, band(a, 0x7FFF)) end
        function S.write8(a, v)
            wr8(mem, band(a, 0x7FFF), v)
            dirty, sramUsed = true, true
        end
    end

    -- EEPROM: a serial port reached with DMA 3 at 0x0D000000 (bit 0 of each halfword)
    local inBits, nIn = table.create(81, 0), 0
    local outBits, nOut, outPos = table.create(68, 0), 0, 0
    local eepOn = kind == "eeprom" or kind == "unknown"
    function S.eeprom(a)
        if not eepOn or (kind == "unknown" and not eepUsed) then return false end
        return romSize <= 0x1000000 or a >= 0x0DFFFF00
    end
    function S.eepSetBits(count)
        if not eepOn then return end
        if count == 9 or count == 73 then eepBits = 6 elseif count == 17 or count == 81 then eepBits = 14 end
        eepUsed = true
    end
    local function bitsValue(from, n)
        local v = 0
        for k = from, from + n - 1 do v = v * 2 + inBits[k] end
        return v
    end
    function S.eepWrite(bit)
        nIn += 1
        inBits[nIn] = bit
        if nIn < 2 then return end
        local req = inBits[1] * 2 + inBits[2]
        if req == 3 and nIn == 2 + eepBits + 1 then
            local blk = band(bitsValue(3, eepBits), 0x3FF)
            local p = blk * 8
            nOut, outPos = 68, 0
            for k = 1, 4 do outBits[k] = 0 end
            for byteI = 0, 7 do
                local b = p + byteI < 0x2000 and rd8(eep, p + byteI) or 0xFF
                for bitI = 7, 0, -1 do outBits[5 + byteI * 8 + (7 - bitI)] = band(rsh(b, bitI), 1) end
            end
            nIn = 0
        elseif req == 2 and nIn == 2 + eepBits + 64 + 1 then
            local blk = band(bitsValue(3, eepBits), 0x3FF)
            local p = blk * 8
            for byteI = 0, 7 do
                if p + byteI < 0x2000 then wr8(eep, p + byteI, bitsValue(3 + eepBits + byteI * 8, 8)) end
            end
            nIn, nOut, outPos = 0, 0, 0
            dirty = true
        elseif nIn >= 2 + 14 + 64 + 1 or (req ~= 3 and req ~= 2) then
            nIn = 0
        end
    end
    function S.eepRead()
        if outPos < nOut then
            outPos += 1
            return outBits[outPos]
        end
        return 1
    end

    function S.data()
        if kind == "eeprom" or (kind == "unknown" and eepUsed) then
            return buffer.readstring(eep, 0, eepBits == 6 and 512 or 8192)
        end
        if kind == "unknown" and not sramUsed then return nil end
        return buffer.tostring(mem)
    end
    function S.dirty() return dirty end
    function S.clearDirty() dirty = false end
    return S
end

return GBA

end)()
local Zip = (function()
-- .zip reading for the GBA window: finds the first game file inside and unpacks it
-- (stored or deflate) into a buffer. Zip.extract(zipString, yieldFn?) -> romString, name | nil, error
local Zip = {}
do
    local band, bor, rsh, lsh = bit32.band, bit32.bor, bit32.rshift, bit32.lshift
    local byte = string.byte
    local rd8, wr8 = buffer.readu8, buffer.writeu8

    local function u16(s, p) local a, b = byte(s, p, p + 1); return a + b * 256 end
    local function u32(s, p) local a, b, c, d = byte(s, p, p + 3); return a + b * 256 + c * 65536 + d * 16777216 end

    local FAST = 9
    -- canonical Huffman table from code lengths: count / sym for the slow path, plus a
    -- lookup on the next 9 bits (symbol * 16 + length) for codes up to 9 bits long
    local function buildHuff(lengths, n)
        local count, sym, offs = {}, {}, {}
        for i = 0, 15 do count[i] = 0 end
        for i = 0, n - 1 do local l = lengths[i] or 0; count[l] += 1 end
        offs[1] = 0
        for i = 1, 14 do offs[i + 1] = offs[i] + count[i] end
        for i = 0, n - 1 do
            local l = lengths[i] or 0
            if l ~= 0 then sym[offs[l]] = i; offs[l] += 1 end
        end
        local fast = {}
        local nextCode, code = {}, 0
        count[0] = 0
        for b = 1, 15 do code = (code + count[b - 1]) * 2; nextCode[b] = code end
        for i = 0, n - 1 do
            local l = lengths[i] or 0
            if l ~= 0 then
                local c = nextCode[l]
                nextCode[l] = c + 1
                if l <= FAST then
                    local rev = 0
                    for k = 0, l - 1 do if band(c, lsh(1, k)) ~= 0 then rev = bor(rev, lsh(1, l - 1 - k)) end end
                    for f = 0, lsh(1, FAST - l) - 1 do fast[rev + f * lsh(1, l)] = i * 16 + l end
                end
            end
        end
        return { count = count, sym = sym, fast = fast }
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

    -- raw deflate from s (a string) at pos into a buffer of size `size` (grown if needed)
    local function inflate(s, pos, size, yieldFn)
        local src = buffer.fromstring(s)
        local srcLen = #s
        local p = pos - 1 -- 0-based read position
        local bitBuf, bitCnt = 0, 0
        local out = buffer.create(math.max(size, 1024))
        local cap = buffer.len(out)
        local n = 0
        local nextYield = 1048576
        local function refill(want)
            while bitCnt < want do
                local b = 0
                if p < srcLen then b = rd8(src, p) end
                p += 1
                bitBuf += lsh(b, bitCnt)
                bitCnt += 8
            end
        end
        local function bits(k)
            if k == 0 then return 0 end
            if bitCnt < k then refill(k) end
            local v = band(bitBuf, lsh(1, k) - 1)
            bitBuf = rsh(bitBuf, k)
            bitCnt -= k
            return v
        end
        local function decode(h)
            if bitCnt < 15 then refill(15) end
            local e = h.fast[band(bitBuf, 511)]
            if e then
                local l = e % 16
                bitBuf = rsh(bitBuf, l)
                bitCnt -= l
                return e // 16
            end
            local code, first, index = 0, 0, 0
            for len = 1, 15 do
                code += bits(1)
                local c = h.count[len]
                if code - c < first then return h.sym[index + (code - first)] end
                index += c
                first = (first + c) * 2
                code *= 2
            end
            error("bad zip data", 0)
        end
        local function grow(need)
            if need <= cap then return end
            local nc = math.max(need, cap * 2)
            local nb = buffer.create(nc)
            buffer.copy(nb, 0, out, 0, n)
            out, cap = nb, nc
        end
        repeat
            local last = bits(1)
            local kind = bits(2)
            if kind == 0 then
                -- stored block: drop to a byte boundary (bits already read ahead are given back)
                local back = bitCnt // 8
                p -= back
                bitBuf, bitCnt = 0, 0
                local len = rd8(src, p) + rd8(src, p + 1) * 256
                p += 4
                grow(n + len)
                buffer.copy(out, n, src, p, len)
                n += len
                p += len
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
                        if sym < 16 then lengths[i] = sym; i += 1
                        else
                            local rep, val = 0, 0
                            if sym == 16 then val = lengths[i - 1]; rep = 3 + bits(2)
                            elseif sym == 17 then rep = 3 + bits(3)
                            else rep = 11 + bits(7) end
                            for _ = 1, rep do lengths[i] = val; i += 1 end
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
                        if n >= cap then grow(n + 1) end
                        wr8(out, n, sym)
                        n += 1
                    elseif sym == 256 then
                        break
                    else
                        sym -= 257
                        local len = LBASE[sym] + bits(LEXT[sym])
                        local ds = decode(dh)
                        local dist = DBASE[ds] + bits(DEXT[ds])
                        if dist > n then error("bad zip data (distance)", 0) end
                        if n + len > cap then grow(n + len) end
                        if dist >= len then
                            buffer.copy(out, n, out, n - dist, len)
                        else
                            for k = 0, len - 1 do wr8(out, n + k, rd8(out, n - dist + k)) end
                        end
                        n += len
                    end
                    if yieldFn and n >= nextYield then nextYield = n + 1048576; yieldFn() end
                end
            else
                error("bad zip block", 0)
            end
        until last == 1
        return buffer.readstring(out, 0, n)
    end
    Zip.inflate = inflate

    local function describe(z)
        local head = z:sub(1, 8)
        if head:sub(1, 6) == "7z\188\175\39\28" then return "this is a .7z archive, not a .zip - unpack it and use the .gba file" end
        if head:sub(1, 4) == "Rar!" then return "this is a .rar archive, not a .zip - unpack it and use the .gba file" end
        if head:sub(1, 2) == "\31\139" then return "this is a .gz file, not a .zip - unpack it and use the .gba file" end
        local hex = {}
        for k = 1, #head do hex[k] = string.format("%02X", byte(head, k)) end
        local mangled = select(2, z:gsub("\239\191\189", "")) > 16
        return "not a zip file (" .. #z .. " bytes, starts " .. table.concat(hex, " ") .. ")"
            .. (mangled and " - the executor read it as text and changed the bytes" or "")
    end
    Zip.describe = describe

    function Zip.extract(z, yieldFn)
        if type(z) ~= "string" then return nil, "file read returned " .. type(z) .. ", not data" end
        local start = z:find("PK\3\4", 1, true)
        if not start then return nil, describe(z) end
        local base = start - 1
        local eocd
        for q = #z - 21, math.max(1, #z - 65557), -1 do
            if u32(z, q) == 0x06054b50 then eocd = q; break end
        end
        if not eocd then return nil, "zip directory not found (" .. #z .. " bytes - the file may be cut short)" end
        local count, q = u16(z, eocd + 10), u32(z, eocd + 16) + 1 + base
        for _ = 1, count do
            if u32(z, q) ~= 0x02014b50 then return nil, "bad zip directory" end
            local method, csize, usize = u16(z, q + 10), u32(z, q + 20), u32(z, q + 24)
            local nameLen, extraLen, commentLen = u16(z, q + 28), u16(z, q + 30), u16(z, q + 32)
            local local0 = u32(z, q + 42) + 1 + base
            local name = z:sub(q + 46, q + 45 + nameLen)
            local low = name:lower()
            if low:sub(-4) == ".gba" or low:sub(-4) == ".agb" or low:sub(-4) == ".bin" then
                local lnl, lel = u16(z, local0 + 26), u16(z, local0 + 28)
                local dataPos = local0 + 30 + lnl + lel
                if method == 0 then return z:sub(dataPos, dataPos + csize - 1), name end
                if method == 8 then
                    local ok, out = pcall(inflate, z, dataPos, usize, yieldFn)
                    if not ok then return nil, tostring(out) end
                    return out, name
                end
                return nil, "zip compression method " .. method .. " is not supported"
            end
            q += 46 + nameLen + extraLen + commentLen
        end
        return nil, "no .gba file inside the zip"
    end
end
return Zip

end)()
return { GBA = GBA, Zip = Zip }
