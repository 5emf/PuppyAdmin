package com.pupdates.app

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.graphics.Typeface
import android.view.View

/** A rough look at a tag while you edit it (Roblox draws the real one): backdrop, picture spot, text and the line under it. */
class TagPreview(ctx: Context) : View(ctx) {
    private var text = "Tag"
    private var sub = ""
    private var color = Color.WHITE
    private var rainbow = false
    private var backdrop = false
    private var bdColor = Color.rgb(18, 18, 22)
    private var bdAlpha = 0.35f
    private var round = true
    private var pfp = "none"
    private var pfpRound = true
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER; typeface = Typeface.DEFAULT_BOLD }

    fun set(text: String, sub: String, color: Int, rainbow: Boolean, backdrop: Boolean, bdColor: Int, bdAlpha: Float, round: Boolean,
            pfp: String, pfpRound: Boolean) {
        this.text = text.take(40); this.sub = sub.take(40); this.color = color; this.rainbow = rainbow; this.backdrop = backdrop
        this.bdColor = bdColor; this.bdAlpha = bdAlpha; this.round = round; this.pfp = pfp; this.pfpRound = pfpRound
        invalidate()
    }

    override fun onDraw(c: Canvas) {
        paint.shader = null
        paint.color = Color.rgb(127, 135, 148)          // a sky-ish grey stands in for the game world
        c.drawRect(0f, 0f, width.toFloat(), height.toFloat(), paint)
        val h = height * 0.8f
        val w = minOf(width * 0.9f, h * 5.2f)
        val l = (width - w) / 2
        val t = (height - h) / 2
        if (backdrop && bdAlpha < 1f) {
            paint.color = bdColor
            paint.alpha = ((1f - bdAlpha) * 255).toInt()
            val r = if (round) h * 0.2f else 0f
            c.drawRoundRect(l, t, l + w, t + h, r, r, paint)
        }
        var cx = width / 2f
        if (pfp != "none") {
            val s = h * 0.7f
            val px = l + h * 0.15f
            val py = t + (h - s) / 2
            paint.color = Color.rgb(216, 219, 226); paint.alpha = 255
            if (pfpRound) c.drawOval(px, py, px + s, py + s, paint) else c.drawRect(px, py, px + s, py + s, paint)
            textPaint.shader = null; textPaint.color = Color.rgb(70, 70, 70); textPaint.textSize = s * 0.22f
            c.drawText(if (pfp == "avatar") "avatar" else "picture", px + s / 2, py + s / 2 + textPaint.textSize / 3, textPaint)
            cx += s / 2
        }
        textPaint.textSize = h * (if (sub.isEmpty()) 0.42f else 0.36f)
        val ty = if (sub.isEmpty()) t + h / 2 + textPaint.textSize / 3 else t + h * 0.48f
        if (rainbow) {
            val tw = textPaint.measureText(text)
            textPaint.shader = LinearGradient(cx - tw / 2, 0f, cx + tw / 2, 0f,
                intArrayOf(Color.rgb(255, 90, 90), Color.rgb(255, 164, 58), Color.rgb(255, 225, 77), Color.rgb(95, 220, 106),
                    Color.rgb(79, 180, 255), Color.rgb(155, 107, 255)), null, Shader.TileMode.CLAMP)
        } else { textPaint.shader = null; textPaint.color = color }
        c.drawText(text, cx, ty, textPaint)
        if (sub.isNotEmpty()) {
            textPaint.shader = null; textPaint.color = Color.rgb(221, 221, 221); textPaint.textSize = h * 0.22f
            c.drawText(sub, cx, t + h * 0.82f, textPaint)
        }
    }
}
