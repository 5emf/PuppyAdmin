package com.pupdates.app

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Bundle
import android.os.Process
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.hypot

/**
 * Plays a Game Boy / GBA ROM or Doom. Runs in its own process (":emu" in the manifest) so Doom,
 * which can only start once per process, starts clean every time; the process ends with the game.
 */
class EmuActivity : Activity() {
    private lateinit var kind: String
    private lateinit var screen: ScreenView
    private lateinit var pad: PadView
    private var bitmap: Bitmap? = null
    private var buffer: ByteBuffer? = null
    private val lock = Object()
    @Volatile private var running = false
    private var loop: Thread? = null
    private var audioThread: Thread? = null
    private var track: AudioTrack? = null
    private var savePath: File? = null
    private var started = false
    private var failed = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        kind = intent.getStringExtra(EXTRA_KIND) ?: "gb"
        screen = ScreenView(this)
        pad = PadView(this, kind) { down, button -> onButton(down, button) }
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        root.addView(screen, FrameLayout.LayoutParams(-1, -1))
        root.addView(pad, FrameLayout.LayoutParams(-1, -1))
        setContentView(root)
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
        val err = try { start() } catch (e: Throwable) { e.message ?: e.toString() }
        if (err != null) fail(err) else started = true
    }

    private fun start(): String? {
        val path = intent.getStringExtra(EXTRA_PATH) ?: return "No game was chosen"
        if (kind == "doom") {
            val dir = File(filesDir, "doom").apply { mkdirs() }
            Native.doomOpen(path, dir.absolutePath)?.let { return "Doom could not start: $it" }
            setup(320, 200)
            return null
        }
        val rom = File(path)
        if (!rom.isFile) return "The game file is missing"
        val module = assets.open(if (kind == "gba") "emu/gba.lua" else "emu/gameboy.lua").use { it.readBytes() }
        val bios = if (kind == "gba") assets.open("emu/cult_bios.bin").use { it.readBytes() } else null
        val saves = File(filesDir, "saves").apply { mkdirs() }
        savePath = File(saves, rom.name + ".sav")
        val save = savePath?.takeIf { it.isFile }?.readBytes()
        Native.luaOpen(if (kind == "gba") Native.GBA else Native.GB, module, rom.readBytes(), bios, save)?.let { return it }
        val size = Native.luaSize()
        setup(size shr 16, size and 0xFFFF)
        return null
    }

    private fun setup(w: Int, h: Int) {
        bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        buffer = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder())
        screen.source = bitmap
    }

    private fun fail(msg: String) {
        failed = true
        running = false
        runOnUiThread {
            if (isFinishing) return@runOnUiThread
            AlertDialog.Builder(this).setTitle("Pupdates").setMessage(msg).setCancelable(false)
                .setPositiveButton("OK") { _, _ -> finish() }.show()
        }
    }

    // ------------------------------------------------------------------ buttons
    private var mask = 0

    private fun onButton(down: Boolean, b: PadView.Button) {
        if (kind == "doom") {
            if (b.doomCycle) {
                if (down) { weapon = weapon % 7 + 1; Native.doomKey(true, '0'.code + weapon); Native.doomKey(false, '0'.code + weapon) }
            } else Native.doomKey(down, b.code)
            return
        }
        mask = if (down) mask or (1 shl b.code) else mask and (1 shl b.code).inv()
        Native.luaKeys(mask)
    }
    private var weapon = 1

    // ------------------------------------------------------------------ running
    override fun onResume() {
        super.onResume()
        if (started && !failed) resumeGame()
    }

    override fun onPause() {
        pauseGame()
        super.onPause()
    }

    override fun onDestroy() {
        pauseGame()
        if (kind != "doom") { writeSave(); Native.luaClose() }
        super.onDestroy()
        if (isFinishing) Process.killProcess(Process.myPid())   // this activity's own process: Doom starts clean next time
    }

    private fun resumeGame() {
        if (running) return
        running = true
        if (kind == "doom") startDoom() else startLua()
    }

    private fun pauseGame() {
        running = false
        loop?.join(1500)
        audioThread?.join(1500)
        loop = null
        audioThread = null
        track?.run { try { stop() } catch (e: Exception) {}; release() }
        track = null
        if (mask != 0) { mask = 0; if (kind != "doom") Native.luaKeys(0) }
        pad.releaseAll()
    }

    private fun newTrack(rate: Int, stereo: Boolean): AudioTrack {
        val channel = if (stereo) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
        val min = AudioTrack.getMinBufferSize(rate, channel, AudioFormat.ENCODING_PCM_16BIT)
        return AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_GAME).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(rate).setChannelMask(channel).setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setBufferSizeInBytes(maxOf(min, rate / 5 * (if (stereo) 4 else 2)))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build().also { it.play() }
    }

    private fun present() {
        val buf = buffer ?: return
        synchronized(lock) {
            buf.rewind()
            bitmap?.copyPixelsFromBuffer(buf)
        }
        screen.postInvalidate()
    }

    private fun startLua() {
        val gba = kind == "gba"
        if (gba) track = newTrack(16384, false)
        loop = Thread({
            val frameNs = (1e9 / 59.7275).toLong()
            val samples = ShortArray(8192)
            var next = System.nanoTime()
            var frames = 0
            while (running) {
                val now = System.nanoTime()
                val draw = now - next < frameNs   // behind by a frame or more: run it without drawing
                val err = Native.luaFrame(buffer!!, draw)
                if (err != null) { fail("The game stopped: $err"); break }
                if (draw) present()
                if (gba) {
                    val n = Native.luaAudio(samples)
                    if (n > 0) track?.write(samples, 0, n, AudioTrack.WRITE_NON_BLOCKING)
                }
                if (++frames % 300 == 0) writeSave()
                next += frameNs
                val wait = next - System.nanoTime()
                if (wait > 0) Thread.sleep(wait / 1_000_000, (wait % 1_000_000).toInt())
                else if (-wait > frameNs * 6) next = System.nanoTime()
            }
        }, "emu").apply { start() }
    }

    private fun startDoom() {
        track = newTrack(22050, true)
        audioThread = Thread({
            val out = ShortArray(2 * 512)
            while (running) {
                Native.doomAudio(out)
                track?.write(out, 0, out.size)   // blocking: paces this thread
            }
        }, "doom-audio").apply { start() }
        loop = Thread({
            while (running) {
                when (Native.doomTick(buffer!!)) {
                    1 -> present()
                    0 -> { running = false; runOnUiThread { finish() } }
                    else -> { fail("Doom stopped: " + Native.doomError().ifEmpty { "unknown error" }); break }
                }
            }
        }, "doom").apply { start() }
    }

    private fun writeSave() {
        val path = savePath ?: return
        val data = try { Native.luaSave() } catch (e: Throwable) { null } ?: return
        try {
            val tmp = File(path.path + ".tmp")
            tmp.writeBytes(data)
            tmp.renameTo(path)
        } catch (e: Exception) {
        }
    }

    // ------------------------------------------------------------------ views
    private inner class ScreenView(ctx: Context) : View(ctx) {
        var source: Bitmap? = null
        private val paint = Paint().apply { isFilterBitmap = false }
        private val dst = RectF()

        override fun onDraw(c: Canvas) {
            val b = source ?: return
            val portrait = resources.configuration.orientation == Configuration.ORIENTATION_PORTRAIT
            val areaH = if (portrait) height * 0.55f else height.toFloat()
            val scale = minOf(width / b.width.toFloat(), areaH / b.height)
            val w = b.width * scale
            val h = b.height * scale
            val left = (width - w) / 2
            val top = if (portrait) maxOf(0f, (areaH - h) / 2) else (height - h) / 2
            dst.set(left, top, left + w, top + h)
            synchronized(lock) { c.drawBitmap(b, null, dst, paint) }
        }
    }

    companion object {
        const val EXTRA_KIND = "kind"
        const val EXTRA_PATH = "path"
    }
}

/** On-screen buttons, multi-touch: a d-pad (diagonals by angle) and round buttons. */
class PadView(ctx: Context, private val kind: String, private val onChange: (Boolean, Button) -> Unit) : View(ctx) {
    class Button(val label: String, val code: Int, val fx: Float, val fy: Float, val r: Float, val doomCycle: Boolean = false) {
        val box = RectF()
        var down = false
    }

    private val dpadCodes = if (kind == "doom") intArrayOf(0xad, 0xaf, 0xac, 0xae) else intArrayOf(6, 7, 5, 4)   // up, down, left, right
    private val dpad = dpadCodes.mapIndexed { i, c -> Button(arrayOf("▲", "▼", "◀", "▶")[i], c, 0f, 0f, 0f) }
    private val buttons: List<Button> = when (kind) {
        "doom" -> listOf(
            Button("FIRE", 0xa3, 0.86f, 0.62f, 0.085f), Button("USE", 0xa2, 0.70f, 0.70f, 0.07f),
            Button("RUN", 0xb6, 0.86f, 0.84f, 0.065f), Button("WPN", 0, 0.70f, 0.90f, 0.055f, doomCycle = true),
            Button("MAP", 9, 0.40f, 0.95f, 0.045f), Button("MENU", 27, 0.52f, 0.95f, 0.045f),
            Button("ENTER", 13, 0.64f, 0.95f, 0.045f), Button("Y", 'y'.code, 0.94f, 0.95f, 0.04f))
        "gba" -> listOf(
            Button("A", 0, 0.88f, 0.70f, 0.075f), Button("B", 1, 0.73f, 0.78f, 0.075f),
            Button("L", 9, 0.10f, 0.52f, 0.06f), Button("R", 8, 0.90f, 0.52f, 0.06f),
            Button("SELECT", 2, 0.40f, 0.95f, 0.05f), Button("START", 3, 0.60f, 0.95f, 0.05f))
        else -> listOf(
            Button("A", 0, 0.88f, 0.70f, 0.075f), Button("B", 1, 0.73f, 0.78f, 0.075f),
            Button("SELECT", 2, 0.40f, 0.95f, 0.05f), Button("START", 3, 0.60f, 0.95f, 0.05f))
    }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 3f }
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE; textAlign = Paint.Align.CENTER; isFakeBoldText = true }
    private var dcx = 0f
    private var dcy = 0f
    private var dr = 0f
    private val bounds = Rect()

    private fun unit() = minOf(width, height).toFloat()

    override fun onSizeChanged(w: Int, h: Int, ow: Int, oh: Int) {
        val u = unit()
        val portrait = h > w
        // portrait: the pad sits in the lower part under the picture; landscape: on both sides of it
        for (b in buttons) {
            val x = b.fx * w
            val y = if (portrait) h * 0.55f + (b.fy - 0.45f) / 0.55f * h * 0.45f else b.fy * h
            val r = b.r * u * (if (portrait) 1.25f else 1f)
            b.box.set(x - r, y - r, x + r, y + r)
        }
        dr = u * (if (portrait) 0.2f else 0.17f)
        dcx = if (portrait) w * 0.24f else w * 0.13f
        dcy = if (portrait) h * 0.55f + (0.72f - 0.45f) / 0.55f * h * 0.45f else h * 0.68f
        text.textSize = u * 0.04f
    }

    override fun onDraw(c: Canvas) {
        // d-pad
        fill.color = Color.argb(70, 255, 255, 255)
        c.drawCircle(dcx, dcy, dr, fill)
        ring.color = Color.argb(140, 200, 204, 212)
        c.drawCircle(dcx, dcy, dr, ring)
        val offs = arrayOf(0f to -1f, 0f to 1f, -1f to 0f, 1f to 0f)
        for ((i, b) in dpad.withIndex()) {
            val x = dcx + offs[i].first * dr * 0.6f
            val y = dcy + offs[i].second * dr * 0.6f
            fill.color = if (b.down) Color.argb(220, 245, 155, 40) else Color.argb(90, 255, 255, 255)
            c.drawCircle(x, y, dr * 0.3f, fill)
            text.getTextBounds(b.label, 0, b.label.length, bounds)
            c.drawText(b.label, x, y + bounds.height() / 2f, text)
        }
        for (b in buttons) {
            fill.color = if (b.down) Color.argb(220, 245, 155, 40) else Color.argb(80, 255, 255, 255)
            c.drawOval(b.box, fill)
            ring.color = if (b.down) Color.argb(255, 245, 155, 40) else Color.argb(150, 200, 204, 212)
            c.drawOval(b.box, ring)
            text.getTextBounds(b.label, 0, b.label.length, bounds)
            c.drawText(b.label, b.box.centerX(), b.box.centerY() + bounds.height() / 2f, text)
        }
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        val held = HashSet<Button>()
        val ending = e.actionMasked == MotionEvent.ACTION_UP || e.actionMasked == MotionEvent.ACTION_CANCEL
        for (i in 0 until e.pointerCount) {
            if (ending) break
            if (e.actionMasked == MotionEvent.ACTION_POINTER_UP && i == e.actionIndex) continue
            val x = e.getX(i)
            val y = e.getY(i)
            val dx = x - dcx
            val dy = y - dcy
            if (hypot(dx, dy) < dr * 1.25f) {
                if (hypot(dx, dy) > dr * 0.2f) {
                    if (abs(dy) > abs(dx) * 0.4f) held.add(if (dy < 0) dpad[0] else dpad[1])
                    if (abs(dx) > abs(dy) * 0.4f) held.add(if (dx < 0) dpad[2] else dpad[3])
                }
                continue
            }
            buttons.firstOrNull { hypot(x - it.box.centerX(), y - it.box.centerY()) < it.box.width() / 2 * 1.15f }?.let { held.add(it) }
        }
        var changed = false
        for (b in dpad + buttons) {
            val now = b in held
            if (now != b.down) { b.down = now; onChange(now, b); changed = true }
        }
        if (changed) invalidate()
        return true
    }

    fun releaseAll() {
        for (b in dpad + buttons) if (b.down) { b.down = false; onChange(false, b) }
        postInvalidate()
    }
}
