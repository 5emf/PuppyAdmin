package com.pupdates.app

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.media.AudioAttributes
import android.media.SoundPool
import android.os.Bundle
import android.view.Choreographer
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Puppy Admin's mini games (Snake, Stack Drop, Treat Chase, Star Pup, Puppy Fighter): the rules
 * are the MiniGames block of PuppyAdmin.lua, unchanged, run in a Luau VM (libpupemu); this screen
 * draws the cells and sprites with the same sprite sheets and feeds the buttons, like Puppy
 * Admin's games window.
 */
class MiniGamesActivity : Activity(), Choreographer.FrameCallback {
    class Game(val id: String, val title: String, val tab: String, val cols: Int, val rows: Int, val help: String, val sheet: String,
               val hold: Boolean, val sprites: Boolean, val preview: Boolean, val pads: List<String>, val repeat: Set<String>,
               val backdrops: List<String>, val splash: String, val sfxBase: String, val sfxNames: List<String>)

    class Kind(val name: String, val col: Int, val row: Int)

    private var games = listOf<Game>()
    private var game: Game? = null
    private var status = "idle"          // idle | play | pause | over
    private val kinds = ArrayList<Kind>()
    private var cells = ""
    private var actors = ""
    private var popups = ""
    private var preview = ""
    private var hud = ""
    private var banner = ""
    private var score = 0
    private var stage = 1
    private var splash = 0f
    private val bitmaps = HashMap<String, Bitmap?>()
    private var sounds: SoundPool? = null
    private val soundIds = HashMap<String, Int>()
    private val held = HashMap<String, Long>()   // repeat keys: action -> next repeat time (ns)
    private var last = 0L
    private var running = false

    private lateinit var board: BoardView
    private lateinit var hudLbl: TextView
    private lateinit var bestLbl: TextView
    private lateinit var helpLbl: TextView
    private lateinit var startBtn: TextView
    private val tabs = ArrayList<Pair<TextView, Game>>()
    private val padButtons = ArrayList<Pair<TextView, String>>()
    private val prefs by lazy { getSharedPreferences("pupdates", MODE_PRIVATE) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val err = try {
            Native.gamesOpen(assets.open("games/minigames.lua").use { it.readBytes() })
        } catch (e: Throwable) { e.message ?: e.toString() }
        if (err != null) { setContentView(TextView(this).apply { text = "The mini games could not load: $err"; setPadding(40, 40, 40, 40) }); return }
        games = call("list")?.firstOrNull().orEmpty().split("\n").filter { it.isNotBlank() }.map { parse(it) }
        setContentView(buildUi())
        select(games.first())
    }

    private fun parse(line: String): Game {
        val f = line.split("\t")
        fun list(s: String) = if (s.isEmpty()) emptyList() else s.split(",")
        val sfx = f.getOrElse(14) { "" }
        return Game(f[0], f[1], f[2], f[3].toInt(), f[4].toInt(), f[5], f[6], f[7] == "1", f[8] == "1", f[9] == "1",
            list(f[10]).let { if (it.size == 6) it else List(6) { "" } }, list(f[11]).toSet(), list(f[12]), f[13],
            sfx.substringBefore("|", ""), list(sfx.substringAfter("|", "")))
    }

    private fun call(fn: String, vararg args: String): Array<String>? {
        val r = Native.gamesCall(fn, arrayOf(*args))
        if (r == null) { status = "over"; banner = "Error: " + Native.gamesError() }
        return r
    }

    // ------------------------------------------------------------------ layout
    private fun dp(v: Int) = (v * resources.displayMetrics.density + 0.5f).toInt()

    private fun plateButton(text: String, onDown: (Boolean) -> Unit): TextView = TextView(this).apply {
        this.text = text
        textSize = 13f
        gravity = Gravity.CENTER
        setTextColor(INK)
        setPadding(dp(8), dp(10), dp(8), dp(10))
        setBackgroundColor(PLATE)
        setOnTouchListener { v, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> { v.setBackgroundColor(ORANGE); (v as TextView).setTextColor(Color.WHITE); onDown(true) }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> { v.setBackgroundColor(PLATE); (v as TextView).setTextColor(INK); onDown(false) }
            }
            true
        }
    }

    private fun buildUi(): View {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.rgb(20, 21, 26))
            setPadding(dp(10), dp(10), dp(10), dp(10))
        }
        val tabRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        for (g in games) {
            val t = plateButton(g.tab) { if (it) select(g) }
            tabRow.addView(t, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).also { it.rightMargin = dp(6) })
            tabs.add(t to g)
        }
        root.addView(HorizontalScrollView(this).apply { addView(tabRow) })
        val hudRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setPadding(0, dp(8), 0, dp(4)) }
        hudLbl = TextView(this).apply { setTextColor(Color.WHITE); textSize = 13f }
        bestLbl = TextView(this).apply { setTextColor(DIM); textSize = 13f; gravity = Gravity.END }
        hudRow.addView(hudLbl, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        hudRow.addView(bestLbl)
        root.addView(hudRow)
        board = BoardView(this)
        root.addView(board, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        val ctl = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setPadding(0, dp(8), 0, 0) }
        startBtn = plateButton("Start") { if (it) startPause() }
        ctl.addView(startBtn, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).also { it.rightMargin = dp(6) })
        ctl.addView(plateButton("Restart") { if (it) newGame() }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).also { it.rightMargin = dp(6) })
        ctl.addView(plateButton("Close") { if (it) finish() }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        root.addView(ctl)

        // pad: Left Up Down Right / Rotate Drop (a game can rename them, e.g. Puppy Fighter)
        val pad = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setPadding(0, dp(6), 0, 0) }
        for ((label, action) in listOf("◀" to "left", "▲" to "up", "▼" to "down", "▶" to "right", "Rotate" to "rotate", "Drop" to "drop")) {
            val b = plateButton(label) { down -> act(action, down) }
            b.textSize = 15f
            pad.addView(b, LinearLayout.LayoutParams(0, dp(58), 1f).also { it.rightMargin = dp(4) })
            padButtons.add(b to action)
        }
        root.addView(pad)
        helpLbl = TextView(this).apply { setTextColor(DIM); textSize = 12f; setPadding(0, dp(6), 0, 0) }
        root.addView(helpLbl)
        return root
    }

    private fun select(g: Game) {
        if (status == "play") setStatus("pause")
        game = g
        call("select", g.id)
        kinds.clear()
        cells = ""; actors = ""; popups = ""; preview = ""; hud = g.title; banner = ""; splash = 0f; stage = 1
        for ((t, tg) in tabs) {
            t.setBackgroundColor(if (tg === g) ORANGE else PLATE)
            t.setTextColor(if (tg === g) Color.WHITE else INK)
        }
        val defaults = listOf("◀", "▲", "▼", "▶", "Rotate", "Drop")
        for ((i, pb) in padButtons.withIndex()) pb.first.text = g.pads[i].ifEmpty { defaults[i] }
        helpLbl.text = g.help
        loadSounds(g)
        setStatus("idle")
        render()
    }

    private fun bitmap(path: String): Bitmap? = bitmaps.getOrPut(path) {
        try {
            assets.open(path.removePrefix("assets/")).use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inScaled = false }) }
        } catch (e: Exception) { null }
    }

    private fun loadSounds(g: Game) {
        sounds?.release()
        sounds = null
        soundIds.clear()
        if (g.sfxNames.isEmpty()) return
        val pool = SoundPool.Builder().setMaxStreams(6)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_GAME).build()).build()
        for (n in g.sfxNames) {
            try { assets.openFd(g.sfxBase.removePrefix("assets/") + n + ".ogg").use { soundIds[n] = pool.load(it, 1) } } catch (e: Exception) {}
        }
        sounds = pool
    }

    // ------------------------------------------------------------------ play
    private fun setStatus(s: String) {
        status = s
        held.clear()
        call("release")
        startBtn.text = when (s) { "play" -> "Pause"; "pause" -> "Resume"; else -> "Start" }
        if (s == "over") {
            val g = game ?: return
            val best = prefs.getInt("best_" + g.id, 0)
            if (score > best) prefs.edit().putInt("best_" + g.id, score).apply()
        }
    }

    private fun startPause() {
        when (status) { "play" -> setStatus("pause"); "pause" -> setStatus("play"); else -> newGame() }
    }

    private fun newGame() {
        val g = game ?: return
        call("select", g.id)
        kinds.clear()
        call("new", System.nanoTime().toString())
        setStatus("play")
        render()
    }

    private fun act(action: String, down: Boolean) {
        val g = game ?: return
        if (status != "play") return
        if (g.hold) call("input", action, if (down) "1" else "0")
        else if (down) {
            call("input", action, "1")
            if (action in g.repeat) held[action] = System.nanoTime() + 170_000_000L
        } else held.remove(action)
        render()
    }

    override fun doFrame(now: Long) {
        if (!running) return
        val dt = if (last == 0L) 0f else ((now - last) / 1e9f).coerceAtMost(0.1f)
        last = now
        if (status == "play") {
            for ((a, t) in held.entries.toList()) if (now >= t) { held[a] = now + 50_000_000L; call("input", a, "1") }
            val ev = call("update", dt.toString())?.firstOrNull().orEmpty()
            if (ev.isNotEmpty()) for (n in ev.split(",")) soundIds[n]?.let { sounds?.play(it, 1f, 1f, 1, 0, 1f) }
            render()
        }
        Choreographer.getInstance().postFrameCallback(this)
    }

    private fun render() {
        val g = game ?: return
        val r = call("frame", if (g.sprites && g.sheet.isNotEmpty()) "1" else "0") ?: return
        cells = r[0]
        if (r[1].isNotEmpty()) for (k in r[1].split(";")) {
            val p = k.split(",")
            kinds.add(Kind(p[0], p.getOrNull(1)?.toIntOrNull() ?: -1, p.getOrNull(2)?.toIntOrNull() ?: -1))
        }
        actors = r[2]; hud = r[3]; banner = r[4]; score = r[6].toIntOrNull() ?: 0; popups = r[7]
        stage = r[8].toIntOrNull() ?: 1; splash = r[9].toFloatOrNull() ?: 0f; preview = r[10]
        if (r[5] == "1" && status == "play") setStatus("over")
        hudLbl.text = hud
        bestLbl.text = "Best " + prefs.getInt("best_" + g.id, 0)
        board.invalidate()
    }

    override fun onResume() {
        super.onResume()
        if (games.isEmpty()) return
        running = true
        last = 0L
        Choreographer.getInstance().postFrameCallback(this)
    }

    override fun onPause() {
        running = false
        if (status == "play") setStatus("pause")
        super.onPause()
    }

    override fun onDestroy() {
        sounds?.release()
        super.onDestroy()
    }

    // ------------------------------------------------------------------ drawing (the same looks as Puppy Admin's games window)
    private fun style(kind: String): Triple<Int, Float, Float> {   // colour, opacity, dot size (0 = whole cell)
        val g = game
        if (kind == "empty") return Triple(ELEVATED, if (g != null && g.backdrops.isNotEmpty()) 0f else if (g?.sprites == true) 0.12f else 0.45f, 0f)
        fun rgb(r: Int, gg: Int, b: Int) = Color.rgb(r, gg, b)
        return when {
            kind.startsWith("head_") -> Triple(ORANGE, 1f, 0f)
            kind.startsWith("body_") || kind.startsWith("tail_") || kind.startsWith("corner_") -> Triple(GOOD, 0.9f, 0f)
            kind == "food" -> Triple(rgb(255, 120, 180), 1f, 0.7f)
            kind == "ghost" -> Triple(DIM, 0.25f, 0f)
            kind == "wall" -> Triple(ORANGE, 0.55f, 0f)
            kind == "wallflash" -> Triple(Color.WHITE, 0.85f, 0f)
            kind == "shield" -> Triple(rgb(150, 210, 120), 0.95f, 0f)
            kind == "ground" -> Triple(rgb(120, 200, 110), 0.5f, 0f)
            kind == "flea1" -> Triple(rgb(120, 220, 110), 1f, 0f)
            kind == "flea2" -> Triple(rgb(230, 110, 210), 1f, 0f)
            kind == "flea3" -> Triple(rgb(110, 210, 240), 1f, 0f)
            kind == "pup" -> Triple(rgb(230, 70, 80), 1f, 0f)
            kind == "shot" -> Triple(rgb(255, 250, 200), 1f, 0.4f)
            kind == "bomb" -> Triple(rgb(255, 120, 60), 1f, 0.4f)
            kind == "saucer" -> Triple(rgb(240, 90, 160), 1f, 0f)
            kind == "snack" -> Triple(rgb(230, 140, 60), 1f, 0.7f)
            kind == "door" -> Triple(rgb(255, 200, 230), 0.7f, 0.35f)
            kind == "treat" -> Triple(rgb(255, 230, 180), 1f, 0.25f)
            kind == "bone" -> Triple(Color.WHITE, 1f, 0.6f)
            kind == "puppy" -> Triple(rgb(255, 176, 90), 1f, 0f)
            kind == "cat1" -> Triple(rgb(180, 120, 255), 1f, 0f)
            kind == "cat2" -> Triple(rgb(90, 200, 255), 1f, 0f)
            kind == "cat3" -> Triple(rgb(255, 110, 120), 1f, 0f)
            kind == "scared" -> Triple(rgb(70, 90, 210), 1f, 0f)
            kind == "scared2" -> Triple(rgb(235, 235, 255), 1f, 0f)
            kind == "eyes" -> Triple(Color.WHITE, 1f, 0.4f)
            kind.length == 2 && kind[0] == 'p' && kind[1].isDigit() -> Triple(PIECES.getOrElse(kind[1] - '1') { ORANGE }, 1f, 0f)
            else -> Triple(ELEVATED, 0.45f, 0f)
        }
    }

    private inner class BoardView(ctx: Context) : View(ctx) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val sprite = Paint().apply { isFilterBitmap = true }
        private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE; textAlign = Paint.Align.CENTER; typeface = Typeface.DEFAULT_BOLD }
        private val src = Rect()
        private val dst = RectF()

        private fun cell(c: Canvas, ch: Char, x: Float, y: Float, cs: Float, sheet: Bitmap?) {
            val k = kinds.getOrNull(ch.code - 35) ?: return
            val (ec, eo, _) = style("empty")
            if (k.col >= 0 && sheet != null) {
                if (eo > 0f) { paint.color = ec; paint.alpha = (eo * 255).toInt(); c.drawRect(x, y, x + cs - 1, y + cs - 1, paint) }
                src.set(k.col * 64, k.row * 64, k.col * 64 + 64, k.row * 64 + 64)
                dst.set(x, y, x + cs, y + cs)
                c.drawBitmap(sheet, src, dst, sprite)
                return
            }
            val (color, op, dot) = style(k.name)
            if (dot > 0f) {
                if (eo > 0f) { paint.color = ec; paint.alpha = (eo * 255).toInt(); c.drawRect(x, y, x + cs - 1, y + cs - 1, paint) }
                paint.color = color; paint.alpha = (op * 255).toInt()
                c.drawCircle(x + cs / 2, y + cs / 2, cs * dot / 2, paint)
            } else if (op > 0f) {
                paint.color = color; paint.alpha = (op * 255).toInt()
                c.drawRoundRect(x, y, x + cs - 1, y + cs - 1, cs / 4, cs / 4, paint)
            }
        }

        override fun onDraw(c: Canvas) {
            val g = game ?: return
            val previewW = if (g.preview) 0.22f else 0f
            val cs = minOf(width * (1 - previewW) / g.cols, height.toFloat() / g.rows)
            val bw = cs * g.cols
            val bh = cs * g.rows
            val left = (width * (1 - previewW) - bw) / 2
            val top = (height - bh) / 2
            paint.color = Color.argb(166, 8, 8, 8)
            c.drawRoundRect(left - 2, top - 2, left + bw + 2, top + bh + 2, 10f, 10f, paint)
            if (g.backdrops.isNotEmpty() && status != "idle") {
                bitmap(g.backdrops.getOrElse(stage - 1) { g.backdrops[0] })?.let { dst.set(left, top, left + bw, top + bh); c.drawBitmap(it, null, dst, sprite) }
            }
            val sheet = if (g.sheet.isNotEmpty()) bitmap(g.sheet) else null
            for (i in cells.indices) cell(c, cells[i], left + (i % g.cols) * cs, top + (i / g.cols) * cs, cs, sheet)
            if (sheet != null && actors.isNotEmpty()) for (a in actors.split(";")) {
                val p = a.split(",")
                if (p.size < 6) continue
                val col = p[0].toFloat().toInt(); val row = p[1].toFloat().toInt()
                if (col < 0) continue
                val dying = p[5].toFloat()
                var size = cs * 1.35f * p[4].toFloat()
                if (dying > 0f) size *= maxOf(0f, 1 - dying)
                val cx = left + (p[2].toFloat() - 0.5f) * cs
                val cy = top + (p[3].toFloat() - 0.5f) * cs
                src.set(col * 64, row * 64, col * 64 + 64, row * 64 + 64)
                dst.set(cx - size / 2, cy - size / 2, cx + size / 2, cy + size / 2)
                c.save()
                if (dying > 0f) c.rotate(dying * 720f, cx, cy)
                c.drawBitmap(sheet, src, dst, sprite)
                c.restore()
            }
            if (popups.isNotEmpty()) {
                text.textSize = cs * 0.8f
                for (pp in popups.split(";")) {
                    val p = pp.split(",")
                    if (p.size < 4) continue
                    val k = p[3].toFloat()
                    text.color = Color.rgb(255, 221, 150)
                    text.alpha = ((1 - maxOf(0f, k * 1.2f - 0.2f)).coerceIn(0f, 1f) * 255).toInt()
                    c.drawText(p[0], left + (p[1].toFloat() - 0.5f) * cs, top + (p[2].toFloat() - 0.5f - k) * cs, text)
                }
            }
            if (g.splash.isNotEmpty() && splash > 0f) bitmap(g.splash)?.let {
                sprite.alpha = ((if (splash < 0.4f) splash / 0.4f else 1f) * 255).toInt()
                dst.set(left, top, left + bw, top + bh)
                c.drawBitmap(it, null, dst, sprite)
                sprite.alpha = 255
            }
            if (g.preview && preview.length == 8) {
                val ps = cs * 0.9f
                val px = left + bw + cs
                text.color = DIM; text.textSize = cs * 0.8f; text.alpha = 255
                c.drawText("Next", px + ps * 2, top + cs, text)
                for (i in 0 until 8) cell(c, preview[i], px + (i % 4) * ps, top + cs * 1.5f + (i / 4) * ps, ps, sheet)
            }
            val msg = when (status) {
                "idle" -> "Press Start"
                "pause" -> "Paused"
                "over" -> if (score >= prefs.getInt("best_" + g.id, 0) && score > 0) "Game over - new best $score" else "Game over - score $score"
                else -> banner
            }
            if (msg.isNotEmpty()) {
                text.color = Color.WHITE; text.alpha = 255; text.textSize = minOf(cs * 1.1f, width / 18f)
                text.setShadowLayer(6f, 0f, 0f, Color.BLACK)
                c.drawText(msg, left + bw / 2, top + bh / 2, text)
                text.clearShadowLayer()
            }
        }
    }

    companion object {
        private val ORANGE = Color.rgb(245, 155, 40)
        private val GOOD = Color.rgb(111, 220, 140)
        private val ELEVATED = Color.rgb(60, 62, 74)
        private val DIM = Color.rgb(155, 156, 168)
        private val INK = Color.rgb(70, 70, 70)
        private val PLATE = Color.rgb(241, 242, 244)
        private val PIECES = listOf(Color.rgb(255, 140, 200), Color.rgb(255, 214, 110), Color.rgb(190, 140, 255), Color.rgb(120, 200, 255),
            Color.rgb(255, 160, 110), Color.rgb(130, 230, 170), Color.rgb(255, 120, 140))
    }
}
