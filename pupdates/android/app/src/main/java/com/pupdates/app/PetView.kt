package com.pupdates.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View

/**
 * Draws the pet: it wanders left and right with the walk cycle (mirrored when it walks left),
 * idles, eats, cheers, sleeps or cries, from the owner's sheet (192 px cells, pixel art drawn
 * without smoothing). Tap the pet to pat it.
 */
class PetView(ctx: Context, private val onPat: () -> Unit) : View(ctx) {
    var pet: Pet? = null
    private val sheet: Bitmap? = try {
        ctx.assets.open("pet/cat_v1.png").use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inScaled = false }) }
    } catch (e: Exception) { null }
    private val cell = 192
    private val paint = Paint().apply { isFilterBitmap = false }
    private val ground = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(40, 0, 0, 0) }
    private val src = Rect()
    private val dst = RectF()
    private var action: List<Pair<Int, Int>>? = null
    private var actionUntil = 0L
    private var x = 0.5f            // 0..1 across the floor
    private var target = 0.5f
    private var facingLeft = false
    private var restUntil = 0L
    private var started = 0L
    private var lastFrame = 0L

    /** plays an animation for ms (eat, happy, ...) */
    fun play(frames: List<Pair<Int, Int>>, ms: Long) {
        action = frames
        actionUntil = System.currentTimeMillis() + ms
        postInvalidateOnAnimation()
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        if (e.actionMasked == MotionEvent.ACTION_UP) { performClick(); onPat() }
        return true
    }

    override fun performClick(): Boolean { super.performClick(); return true }

    override fun onDraw(c: Canvas) {
        val b = sheet ?: return
        val p = pet ?: return
        val now = System.currentTimeMillis()
        if (started == 0L) started = now
        val dt = if (lastFrame == 0L) 0f else ((now - lastFrame) / 1000f).coerceAtMost(0.1f)
        lastFrame = now
        val t = now - started
        val size = minOf(height * 0.9f, width * 0.45f)
        val floor = height * 0.95f

        var frames: List<Pair<Int, Int>>
        var fps = 5f
        var walking = false
        val act = action
        if (act != null && now < actionUntil) { frames = act; fps = 6f }
        else {
            action = null
            when {
                p.asleep -> { frames = Pet.Frames.SLEEP; fps = 2f }
                p.sad -> { frames = Pet.Frames.SAD; fps = 3f }
                else -> {
                    if (now >= restUntil && kotlin.math.abs(target - x) < 0.01f) {
                        target = 0.15f + (Math.random().toFloat() * 0.7f)
                        restUntil = now + 2500 + (Math.random() * 4000).toLong()
                    }
                    if (now >= restUntil - 1200 && kotlin.math.abs(target - x) >= 0.01f) {
                        walking = true
                        facingLeft = target < x
                        val step = 0.12f * dt
                        x = if (target > x) minOf(target, x + step) else maxOf(target, x - step)
                    }
                    frames = when {
                        walking -> Pet.Frames.WALK
                        (t / 7000) % 3 == 2L -> Pet.Frames.CAPE
                        (t / 7000) % 2 == 1L -> Pet.Frames.IDLE2
                        else -> Pet.Frames.IDLE
                    }
                    fps = if (walking) 8f else 3f
                }
            }
        }
        val (col, row) = frames[((t / 1000f * fps).toInt()) % frames.size]
        src.set(col * cell, row * cell, col * cell + cell, row * cell + cell)
        val cx = size / 2 + x * (width - size)
        c.drawOval(cx - size * 0.3f, floor - size * 0.05f, cx + size * 0.3f, floor + size * 0.03f, ground)
        dst.set(cx - size / 2, floor - size, cx + size / 2, floor)
        c.save()
        if (facingLeft && walking) c.scale(-1f, 1f, cx, floor)
        c.drawBitmap(b, src, dst, paint)
        c.restore()
        postInvalidateOnAnimation()
    }
}
