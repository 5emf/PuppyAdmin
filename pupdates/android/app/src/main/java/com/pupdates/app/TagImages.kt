package com.pupdates.app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/**
 * Loads tag pictures for the preview, once per source: image links directly, Roblox ids and head
 * shots through Roblox's thumbnail service (TagLook.resolve decides which). Callbacks run on the
 * main thread.
 */
class TagImages {
    class Picture(@Volatile var state: String = "loading", @Volatile var bitmap: Bitmap? = null,
                  @Volatile var note: String = "", @Volatile var error: String = "")

    private val cache = HashMap<TagLook.Source, Picture>()
    private val waiting = HashMap<TagLook.Source, MutableList<() -> Unit>>()
    private val pool = Executors.newFixedThreadPool(3)
    private val main = Handler(Looper.getMainLooper())

    fun get(src: TagLook.Source?, onReady: () -> Unit): Picture? {
        if (src == null) return null
        if (src.kind == "unsupported" || src.kind == "bad") return Picture("failed", error = src.value)
        synchronized(this) {
            cache[src]?.let { if (it.state == "loading") waiting.getOrPut(src) { mutableListOf() }.add(onReady); return it }
            val pic = Picture()
            cache[src] = pic
            waiting[src] = mutableListOf(onReady)
            pool.execute { load(src, pic) }
            return pic
        }
    }

    private fun fetch(url: String, limit: Int): ByteArray {
        val c = URL(url).openConnection() as HttpURLConnection
        try {
            c.connectTimeout = 15000
            c.readTimeout = 25000
            c.setRequestProperty("User-Agent", "Pupdates-TagPreview")
            val code = c.responseCode
            if (code !in 200..299) throw Core.PupError("the server answered HTTP $code")
            val out = ByteArrayOutputStream()
            c.inputStream.use { input ->
                val buf = ByteArray(32 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    if (out.size() > limit) throw Core.PupError("the picture is bigger than ${limit / (1024 * 1024)} MB")
                }
            }
            return out.toByteArray()
        } catch (e: java.io.IOException) {
            throw Core.PupError("could not connect (${e.message ?: e.javaClass.simpleName})")
        } finally {
            c.disconnect()
        }
    }

    private fun thumb(url: String, what: String): String {
        repeat(4) { attempt ->
            val entry = try {
                JSONObject(String(fetch(url, 256 * 1024), Charsets.UTF_8)).optJSONArray("data")?.optJSONObject(0)
            } catch (e: org.json.JSONException) { null } ?: throw Core.PupError("Roblox's thumbnail service sent something unexpected")
            val state = entry.optString("state")
            if (state == "Completed" && entry.optString("imageUrl").isNotEmpty()) return entry.optString("imageUrl")
            if (state == "Pending" && attempt < 3) { Thread.sleep(1500); return@repeat }
            if (state == "Blocked") throw Core.PupError("Roblox has blocked $what (moderated or private)")
            throw Core.PupError("Roblox has no picture for $what (${state.ifEmpty { "no answer" }})")
        }
        throw Core.PupError("Roblox is still making the picture for $what: try again in a moment")
    }

    private fun load(src: TagLook.Source, pic: Picture) {
        var note = ""
        try {
            val data = when (src.kind) {
                "url" -> fetch(src.value, 12 * 1024 * 1024)
                "headshot" -> fetch(thumb(TagLook.thumbUrl(src)!!, "user ${src.value}"), 12 * 1024 * 1024)
                else -> {
                    note = assetNote(src.value)
                    fetch(thumb(TagLook.thumbUrl(src)!!, "asset ${src.value}"), 12 * 1024 * 1024)
                }
            }
            val kind = Core.imageKind(data)
            if (kind == null) {
                val looks = if (String(data, 0, minOf(2048, data.size), Charsets.ISO_8859_1).lowercase().contains("<html")) "a web page" else "something else"
                throw Core.PupError("that link is not a picture (it sent $looks)")
            }
            val bmp = BitmapFactory.decodeByteArray(data, 0, data.size) ?: throw Core.PupError("the picture could not be read")
            if (src.kind == "url" && (kind.second == "webp" || kind.second == "gif")) {
                note = (if (note.isEmpty()) "" else "$note ") + "${kind.second.uppercase()} from a link: Roblox may not show this format (PNG or JPG is safe)."
            }
            pic.bitmap = bmp
            pic.note = note
            pic.state = "ok"
        } catch (e: Exception) {
            pic.error = if (e is Core.PupError) e.message ?: "failed" else e.toString()
            pic.state = "failed"
        }
        val todo = synchronized(this) { waiting.remove(src) ?: mutableListOf() }
        main.post { todo.forEach { it() } }
    }

    private fun assetNote(id: String): String = try {
        val type = JSONObject(String(fetch(TagLook.ASSET_INFO.format(id), 256 * 1024), Charsets.UTF_8)).optInt("AssetTypeId")
        if (type == 13) "Asset $id is a Decal: a script that sets a Decal id often shows nothing in the game; use the Image id behind it." else ""
    } catch (e: Exception) { "" }

    fun shutdown() = pool.shutdownNow()
}
