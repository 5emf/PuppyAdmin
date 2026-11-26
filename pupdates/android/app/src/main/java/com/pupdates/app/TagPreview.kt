package com.pupdates.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.view.View
import org.json.JSONObject
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * The tag drawn the way Puppy Admin's Tags.build draws it (TagLook has the numbers): backdrop at
 * its see-through level with its image cropped to fill, the picture (loaded by TagImages) round or
 * with 6 px corners, the text in the tag's font with Roblox's black outline, the line under it,
 * the moving rainbow, and beside it what the tag looks like past 30 studs (the picture only).
 */
class TagPreview(ctx: Context) : View(ctx) {
    private var tag: JSONObject? = null
    private var picture: Bitmap? = null
    private var backdropImage: Bitmap? = null
    private var hasPicture = false
    private val typefaces = HashMap<String, Typeface>()
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(28, 52, 92) }
    private val started = System.nanoTime()
    private val density = resources.displayMetrics.density

    fun show(tag: JSONObject?, picture: Bitmap?, backdropImage: Bitmap?, hasPicture: Boolean) {
        this.tag = tag
        this.picture = picture
        this.backdropImage = backdropImage
        this.hasPicture = hasPicture
        requestLayout()
        invalidate()
    }

    private fun typeface(font: String): Typeface = typefaces.getOrPut(font) {
        try { Typeface.createFromAsset(context.assets, "tagfonts/" + TagLook.fontFile(font)) } catch (e: Exception) { Typeface.DEFAULT_BOLD }
    }

    private fun measure(text: String, font: String, px: Float): Float {
        textPaint.typeface = typeface(font)
        textPaint.textSize = px
        return textPaint.measureText(text)
    }

    private fun currentLayout(): TagLook.Layout? = tag?.let { TagLook.layout(it, hasPicture) { s, f, px -> measure(s, f, px) } }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = MeasureSpec.getSize(widthMeasureSpec)
        val lay = currentLayout()
        val scale = if (lay != null) min(density, w * 0.66f / max(1f, lay.cardW)) else density
        val h = if (lay != null) max(lay.cardH * scale + 34 * density, 72 * density) else 72 * density
        setMeasuredDimension(w, h.roundToInt())
    }

    private fun roundRect(r: RectF, radius: Float) = Path().apply { addRoundRect(r, radius, radius, Path.Direction.CW) }

    /** ScaleType.Crop: the middle part of the bitmap with the box's shape */
    private fun coverSrc(b: Bitmap, w: Float, h: Float): Rect {
        val k = max(w / b.width, h / b.height)
        val sw = (w / k).roundToInt().coerceIn(1, b.width)
        val sh = (h / k).roundToInt().coerceIn(1, b.height)
        val x = (b.width - sw) / 2
        val y = (b.height - sh) / 2
        return Rect(x, y, x + sw, y + sh)
    }

    private fun drawPicture(c: Canvas, box: RectF, round: Boolean, scale: Float) {
        c.save()
        c.clipPath(if (round) Path().apply { addOval(box, Path.Direction.CW) } else roundRect(box, 6 * scale))
        val b = picture
        if (b != null) {
            paint.alpha = 255
            c.drawBitmap(b, coverSrc(b, box.width(), box.height()), box, paint)
        } else {   // no wearer / the default tag: a neutral head where an avatar would be
            paint.color = Color.rgb(196, 201, 210); c.drawRect(box, paint)
            paint.color = Color.rgb(238, 240, 244)
            val w = box.width()
            c.drawOval(box.left + w * 0.3f, box.top + w * 0.16f, box.left + w * 0.7f, box.top + w * 0.56f, paint)
            c.drawOval(box.left + w * 0.12f, box.top + w * 0.6f, box.left + w * 0.88f, box.top + w * 1.3f, paint)
        }
        c.restore()
    }

    private fun drawText(c: Canvas, box: TagLook.Box, ox: Float, oy: Float, text: String, font: String, px: Float, rgb: IntArray,
                         strokeAlpha: Float, left: Boolean, scale: Float) {
        if (text.isEmpty()) return
        textPaint.typeface = typeface(font)
        textPaint.textSize = px
        textPaint.textAlign = if (left) Paint.Align.LEFT else Paint.Align.CENTER
        val x = ox + (if (left) box.x * scale else (box.x + box.w / 2) * scale)
        val fm = textPaint.fontMetrics
        val y = oy + (box.y + box.h / 2) * scale - (fm.ascent + fm.descent) / 2
        textPaint.style = Paint.Style.STROKE
        textPaint.strokeWidth = 2f * max(1f, scale.roundToInt().toFloat())
        textPaint.strokeJoin = Paint.Join.ROUND
        textPaint.color = Color.argb((255 * strokeAlpha).roundToInt(), 0, 0, 0)
        c.drawText(text, x, y, textPaint)
        textPaint.style = Paint.Style.FILL
        textPaint.color = Color.rgb(rgb[0], rgb[1], rgb[2])
        c.drawText(text, x, y, textPaint)
    }

    override fun onDraw(c: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        paint.shader = LinearGradient(0f, 0f, 0f, h, Color.rgb(112, 166, 226), Color.rgb(196, 224, 250), Shader.TileMode.CLAMP)
        paint.alpha = 255
        c.drawRect(0f, 0f, w, h, paint)
        paint.shader = null
        labelPaint.textSize = 11 * density
        val t = tag
        val lay = currentLayout()
        if (t == null || lay == null) {
            c.drawText("Pick or add a tag to see it here", 8 * density, h / 2, labelPaint)
            return
        }
        val scale = min(density, w * 0.66f / max(1f, lay.cardW))
        val cw = lay.cardW * scale
        val ch = lay.cardH * scale
        val ox = w * 0.36f - cw / 2
        val oy = (h - ch) / 2 + 6 * density
        labelPaint.textAlign = Paint.Align.LEFT
        c.drawText("close up" + if (scale < density - 0.001f) "  (${(100 * scale / density).roundToInt()}% size)" else "", 8 * density, 16 * density, labelPaint)
        labelPaint.textAlign = Paint.Align.CENTER
        val fx = w * 0.8f
        c.drawText("past ${TagLook.FAR_STUDS} studs", fx, 16 * density, labelPaint)

        val bd = t.optJSONObject("backdrop") ?: JSONObject()
        val pf = t.optJSONObject("pfp") ?: JSONObject()
        val card = RectF(ox, oy, ox + cw, oy + ch)
        if (bd.optBoolean("on")) {
            val shape = roundRect(card, lay.corner * scale)
            val col = bd.optJSONArray("color")
            paint.color = Color.rgb(col?.optInt(0) ?: 18, col?.optInt(1) ?: 18, col?.optInt(2) ?: 22)
            paint.alpha = ((1 - bd.optDouble("transparency", 0.35)) * 255).roundToInt().coerceIn(0, 255)
            c.drawPath(shape, paint)
            backdropImage?.let { b ->
                c.save()
                c.clipPath(shape)
                paint.alpha = ((1 - bd.optDouble("imageTransparency", 0.15)) * 255).roundToInt().coerceIn(0, 255)
                c.drawBitmap(b, coverSrc(b, cw, ch), card, paint)
                c.restore()
            }
        }
        if (lay.pic > 0) {
            val pb = lay.picBox
            drawPicture(c, RectF(ox + pb.x * scale, oy + pb.y * scale, ox + (pb.x + pb.w) * scale, oy + (pb.y + pb.h) * scale),
                pf.optBoolean("round", true), scale)
        }
        val seconds = (System.nanoTime() - started) / 1e9
        val (main, sub) = TagLook.textColours(t, seconds)
        val font = t.optString("font").ifEmpty { "GothamBold" }
        drawText(c, lay.mainBox, ox, oy, t.optString("text"), font, lay.size * scale, main, 0.7f, lay.alignLeft, scale)
        drawText(c, lay.subBox, ox, oy, t.optString("sub"), font, lay.subSize * scale, sub, 0.6f, lay.alignLeft, scale)

        val far = lay.far
        if (far != null) {
            val box = far * scale
            val left = fx - box / 2
            val top = (h - box) / 2 + 6 * density
            drawPicture(c, RectF(left + 4 * scale, top + 4 * scale, left + 4 * scale + lay.pic * scale, top + 4 * scale + lay.pic * scale),
                pf.optBoolean("round", true), scale)
        } else c.drawText("(nothing shown)", fx, h / 2 + 6 * density, labelPaint)
        if (t.optBoolean("rainbow")) postInvalidateOnAnimation()
    }
}
