package com.pupdates.app

import org.json.JSONObject
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * How Puppy Admin draws a tag (Tags.build in PuppyAdmin.lua), as numbers and rules the preview
 * follows: the layout, the colours, the rainbow, the far view and where pictures come from. The
 * desktop app's tagpreview.py has the same rules. Pure (no Android drawing), so it is unit-tested.
 */
object TagLook {
    const val RAINBOW_PERIOD = 4.0
    const val FAR_STUDS = 30
    const val THUMB_ASSET = "https://thumbnails.roblox.com/v1/assets?assetIds=%s&returnPolicy=PlaceHolder&size=420x420&format=Png&isCircular=false"
    const val THUMB_HEAD = "https://thumbnails.roblox.com/v1/users/avatar-headshot?userIds=%s&size=150x150&format=Png&isCircular=false"
    const val ASSET_INFO = "https://economy.roblox.com/v2/assets/%s/details"

    /** tag font -> file in assets/tagfonts (free fonts; Gotham and SciFi are look-alikes, see tools/make_tag_fonts.py) */
    val FONT_FILES = mapOf(
        "GothamBold" to "Montserrat-Bold.ttf", "Gotham" to "Montserrat-Regular.ttf", "GothamSemibold" to "Montserrat-SemiBold.ttf",
        "Code" to "Inconsolata-Regular.ttf", "Arcade" to "PressStart2P-Regular.ttf", "SourceSansBold" to "SourceSans3-Bold.ttf",
        "FredokaOne" to "Fredoka-SemiBold.ttf", "Bangers" to "Bangers-Regular.ttf", "SciFi" to "Orbitron-Regular.ttf",
        "Fantasy" to "Balthazar-Regular.ttf")
    val STAND_INS = mapOf("GothamBold" to "Gotham SSm Bold", "Gotham" to "Gotham SSm", "GothamSemibold" to "Gotham SSm Semibold",
        "SciFi" to "Zekton")

    /** an unknown font name falls back to GothamBold, as Enum.Font does in Tags.build */
    fun fontFile(name: String?): String = FONT_FILES[name] ?: FONT_FILES.getValue("GothamBold")

    // ------------------------------------------------------------------ picture sources (resolveImageSource)
    data class Source(val kind: String, val value: String)   // url / asset / headshot, or unsupported / bad (value = reason)

    fun resolve(raw: String?): Source? {
        var s = (raw ?: "").trim()
        if (s.isEmpty()) return null
        Regex("^https://github\\.com/([^/]+)/([^/]+)/blob/(.+)$").find(s)?.let {
            s = "https://raw.githubusercontent.com/${it.groupValues[1]}/${it.groupValues[2]}/${it.groupValues[3]}"
        }
        if (s.startsWith("rbxthumb")) {
            val type = Regex("type=([A-Za-z]+)").find(s)?.groupValues?.get(1)
            val id = Regex("\\bid=(\\d+)").find(s)?.groupValues?.get(1)
            return when {
                type == "AvatarHeadShot" && id != null -> Source("headshot", id)
                type == "Asset" && id != null -> Source("asset", id)
                else -> Source("unsupported", "This Roblox thumbnail link shows in the game; the preview can only load head shots and assets")
            }
        }
        if (s.startsWith("rbxasset")) {
            val id = Regex("^rbxassetid://(\\d+)").find(s)?.groupValues?.get(1)
            return if (id != null) Source("asset", id) else Source("unsupported", "A file inside the Roblox app: it shows in the game, the preview cannot load it")
        }
        if (s.all { it.isDigit() }) return Source("asset", s)
        if (s.contains("roblox.com")) {
            val id = Regex("(\\d+)").find(s)?.groupValues?.get(1)
            return if (id != null) Source("asset", id) else Source("bad", "No asset id in that link")
        }
        if (s.startsWith("http://") || s.startsWith("https://")) return Source("url", s)
        return Source("bad", "Not an image id, asset or image URL")
    }

    fun thumbUrl(src: Source): String? = when (src.kind) {
        "asset" -> THUMB_ASSET.format(src.value)
        "headshot" -> THUMB_HEAD.format(src.value)
        else -> null
    }

    // ------------------------------------------------------------------ layout (Tags.build)
    class Box(val x: Float, val y: Float, val w: Float, val h: Float)

    class Layout(val size: Float, val subSize: Float, val cardW: Float, val cardH: Float, val pic: Float, val picBox: Box,
                 val mainBox: Box, val subBox: Box, val alignLeft: Boolean, val corner: Float, val far: Float?)

    /** measure(text, fontName, px) -> width in px */
    fun layout(t: JSONObject, hasPicture: Boolean, measure: (String, String, Float) -> Float): Layout {
        val size = t.optDouble("size", 22.0).toFloat().coerceIn(8f, 48f)
        val subSize = max(12f, size - 8)
        val text = t.optString("text")
        val sub = t.optString("sub")
        val font = t.optString("font").ifEmpty { "GothamBold" }
        val bd = t.optJSONObject("backdrop") ?: JSONObject()
        val on = bd.optBoolean("on")
        val lineMain = ceil(size * 1.35f)
        val lineSub = if (sub.isNotEmpty()) ceil(subSize * 1.35f) else 0f
        val textH = lineMain + lineSub
        fun width(s: String, px: Float) = if (s.isEmpty()) 0f else measure(s, font, px)
        val textW = ceil(max(width(text, size), width(sub, subSize))) + 10
        val pic = if (hasPicture) floor(max(textH, size * 1.5f)) else 0f
        val gap = if (hasPicture && textW > 0) 8f else 0f
        val padX = if (on) 12f else 4f
        val padY = if (on) 6f else 4f
        val cardW = ceil(padX * 2 + pic + gap + textW)
        val cardH = ceil(padY * 2 + max(textH, pic))
        val ax = padX + pic + gap
        val aw = cardW - (padX * 2 + pic + gap)
        val ah = cardH - padY * 2
        val split = if (sub.isNotEmpty()) lineMain / textH else 1f
        return Layout(size, subSize, cardW, cardH, pic, Box(padX, floor((cardH - pic) / 2), pic, pic),
            Box(ax, padY, aw, ah * split), Box(ax, padY + ah * split, aw, ah * (1 - split)), hasPicture,
            if (on && bd.optBoolean("round", true)) min(14f, cardH / 2) else 0f, if (hasPicture) pic + 8 else null)
    }

    // ------------------------------------------------------------------ colours
    fun hsv(h: Double, s: Double, v: Double): IntArray {
        val i = (h * 6).toInt() % 6
        val f = h * 6 - (h * 6).toInt()
        val p = v * (1 - s)
        val q = v * (1 - f * s)
        val tt = v * (1 - (1 - f) * s)
        val (r, g, b) = when (i) { 0 -> Triple(v, tt, p); 1 -> Triple(q, v, p); 2 -> Triple(p, v, tt); 3 -> Triple(p, q, v); 4 -> Triple(tt, p, v); else -> Triple(v, p, q) }
        return intArrayOf(Math.round(r * 255).toInt(), Math.round(g * 255).toInt(), Math.round(b * 255).toInt())
    }

    /** (main, sub) as r,g,b: rainbow = one hue for the whole text, round in 4 s; the line under it 40 % toward white */
    fun textColours(t: JSONObject, seconds: Double): Pair<IntArray, IntArray> {
        val main = if (t.optBoolean("rainbow")) hsv((seconds / RAINBOW_PERIOD) % 1.0, 0.9, 1.0)
                   else t.optJSONArray("color")?.let { intArrayOf(it.optInt(0, 255), it.optInt(1, 255), it.optInt(2, 255)) } ?: intArrayOf(255, 255, 255)
        val sub = IntArray(3) { Math.round(main[it] + (255 - main[it]) * 0.4).toInt() }
        return main to sub
    }

    // ------------------------------------------------------------------ what to load
    class Plan(val picture: Source?, val backdrop: Source?, val notes: MutableList<String>)

    fun plan(t: JSONObject, firstWearer: String?, wearerName: String?): Plan {
        val pf = t.optJSONObject("pfp") ?: JSONObject()
        val bd = t.optJSONObject("backdrop") ?: JSONObject()
        val notes = mutableListOf<String>()
        var picture: Source? = null
        when (pf.optString("mode")) {
            "avatar" -> if (firstWearer != null) {
                picture = Source("headshot", firstWearer)
                notes.add("Picture: ${wearerName ?: "the first wearer"}'s avatar (each wearer sees their own).")
            } else notes.add("Picture: each player's own avatar (no wearer here, so a stand-in head).")
            "custom" -> {
                picture = resolve(pf.optString("image"))
                if (picture == null) notes.add("Picture: custom, but no image is set, so the game shows no picture.")
            }
        }
        var backdrop: Source? = null
        if (bd.optString("image").isNotBlank()) {
            if (bd.optBoolean("on")) backdrop = resolve(bd.optString("image"))
            else notes.add("Backdrop image: not shown while the backdrop is off.")
        }
        val font = t.optString("font").let { if (FONT_FILES.containsKey(it)) it else "GothamBold" }
        STAND_INS[font]?.let {
            notes.add("Font: ${fontFile(font).substringBefore(".")} is a free stand-in for Roblox's $it (close, not identical).")
        }
        return Plan(picture, backdrop, notes)
    }
}
