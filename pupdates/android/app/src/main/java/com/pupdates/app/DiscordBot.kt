package com.pupdates.app

import org.json.JSONArray
import org.json.JSONObject

/**
 * Pupdates driving your own Discord bot (the desktop app's bot.py does the same): sign in with the
 * bot's token, list servers and channels, post (cards, text, pictures, pings), publish in
 * announcement channels, edit / delete the bot's posts, change the bot's name and picture.
 * Discord API v10; the token only goes to discord.com and is hidden in every message shown.
 */
object DiscordBot {
    const val API = "https://discord.com/api/v10"
    const val TEXT = 0
    const val ANNOUNCEMENT = 5
    const val CATEGORY = 4
    // View Channel, Send Messages, Embed Links, Attach Files, Read Message History, Mention Everyone
    const val PERMISSIONS = 1024 or 2048 or 16384 or 32768 or 65536 or 131072
    private val TOKEN_RE = Regex("^[\\w-]{18,}\\.[\\w-]{4,}\\.[\\w-]{20,}$")
    private val ERRORS = mapOf(
        10003 to "That channel no longer exists (or the bot cannot see it)",
        10008 to "That message no longer exists",
        50001 to "The bot cannot see that channel (give its role View Channel there)",
        50013 to "The bot is missing a permission in that channel: it needs View Channel, Send Messages, Embed Links and Attach Files (and Mention Everyone for @here / @everyone)",
        50035 to "Discord did not accept the message (too long or empty)",
        40005 to "The picture is too big for Discord")

    fun validToken(t: String?) = TOKEN_RE.matches((t ?: "").trim())

    fun appId(token: String?): String? {
        val part = (token ?: "").split(".").firstOrNull() ?: return null
        return try {
            val raw = String(java.util.Base64.getUrlDecoder().decode(part.padEnd((part.length + 3) / 4 * 4, '=')), Charsets.US_ASCII)
            raw.takeIf { it.isNotEmpty() && it.all { c -> c.isDigit() } }
        } catch (e: IllegalArgumentException) { null }
    }

    fun inviteUrl(appId: String?) = appId?.let { "https://discord.com/oauth2/authorize?client_id=$it&scope=bot&permissions=$PERMISSIONS" }

    fun jumpUrl(guild: String?, channel: String, message: String) = "https://discord.com/channels/${guild?.ifEmpty { null } ?: "@me"}/$channel/$message"

    data class Channel(val id: String, val name: String, val type: Int, val category: String)

    /** text and announcement channels in Discord's order (by category, then position) */
    fun sortChannels(arr: JSONArray): List<Channel> {
        val all = (0 until arr.length()).map { arr.getJSONObject(it) }
        val cats = all.filter { it.optInt("type") == CATEGORY }.associateBy { it.optString("id") }
        return all.filter { it.optInt("type") == TEXT || it.optInt("type") == ANNOUNCEMENT }
            .sortedWith(compareBy<JSONObject>({ cats[it.optString("parent_id")]?.optInt("position") ?: -1 },
                { cats[it.optString("parent_id")]?.optString("id") ?: "" }, { it.optInt("position") }, { it.optString("name") }))
            .map { Channel(it.optString("id"), it.optString("name", "?"), it.optInt("type"), cats[it.optString("parent_id")]?.optString("name") ?: "") }
    }

    /** a webhook body made fit for a bot: bots keep their own name and picture */
    fun botBody(body: JSONObject): JSONObject = JSONObject(body.toString()).apply { remove("username"); remove("avatar_url") }

    class Client(private val http: Core.Http, token: String, private val sleep: (Long) -> Unit = { Thread.sleep(it) }) {
        private val token = token.trim()

        private fun call(method: String, path: String, body: JSONObject? = null, picture: Core.Picture? = null, tries: Int = 3): String {
            if (!validToken(token)) throw Core.PupError("That is not a bot token (Developer Portal > your app > Bot > Reset Token)")
            val headers = mutableMapOf("Authorization" to "Bot $token", "User-Agent" to "DiscordBot (https://github.com/5emf/PuppyAdmin, 2) Pupdates")
            var data: ByteArray? = null
            if (picture != null) {
                val (d, type) = Core.multipart(listOf("payload_json" to (body ?: JSONObject()).toString()),
                    listOf(Core.FilePart("files[0]", picture.name, picture.mime, picture.data)))
                data = d
                headers["Content-Type"] = type
            } else if (body != null) {
                data = body.toString().toByteArray(Charsets.UTF_8)
                headers["Content-Type"] = "application/json"
            }
            repeat(tries) { attempt ->
                val r = http.request(method, API + path, headers, data)
                if (r.code in 200..299) return r.body
                val info = try { JSONObject(r.body) } catch (e: Exception) { JSONObject() }
                if (r.code == 429 && attempt < tries - 1) {
                    sleep((info.optDouble("retry_after", 1.5).coerceIn(0.0, 30.0) * 1000).toLong())
                    return@repeat
                }
                if (r.code == 401) throw Core.PupError("Discord refused the token: it is wrong or was reset (make a new one in the Developer Portal)")
                if (r.code == 429) throw Core.PupError("Discord says slow down: try again in a minute (a bot's name can change only twice an hour)")
                val msg = ERRORS[info.optInt("code", -1)] ?: info.optString("message").ifEmpty { "HTTP ${r.code}" }
                throw Core.PupError(Core.redact(msg, token))
            }
            throw Core.PupError("Discord is still rate-limiting: try again in a minute")
        }

        private fun obj(s: String) = if (s.isBlank()) JSONObject() else JSONObject(s)

        fun me(): JSONObject = obj(call("GET", "/users/@me"))
        fun guilds(): List<JSONObject> = JSONArray(call("GET", "/users/@me/guilds")).let { a -> (0 until a.length()).map { a.getJSONObject(it) } }
            .sortedBy { it.optString("name").lowercase() }
        fun channels(guild: String): List<Channel> = sortChannels(JSONArray(call("GET", "/guilds/$guild/channels")))
        fun post(channel: String, body: JSONObject, picture: Core.Picture?): JSONObject = obj(call("POST", "/channels/$channel/messages", botBody(body), picture))
        fun publish(channel: String, message: String): JSONObject = obj(call("POST", "/channels/$channel/messages/$message/crosspost"))
        fun message(channel: String, message: String): JSONObject = obj(call("GET", "/channels/$channel/messages/$message"))

        /** replaces the text / card; a picture already on the post stays (kept by its attachment id) */
        fun edit(channel: String, message: String, body: JSONObject): JSONObject {
            val old = message(channel, message)
            val new = botBody(body)
            val files = old.optJSONArray("attachments") ?: JSONArray()
            val embeds = new.optJSONArray("embeds")
            if (files.length() > 0) {
                new.put("attachments", JSONArray().apply { for (i in 0 until files.length()) put(JSONObject().put("id", files.getJSONObject(i).optString("id"))) })
                if (embeds != null) for (i in 0 until embeds.length()) {
                    val e = embeds.getJSONObject(i)
                    if (e.optJSONObject("image")?.optString("url")?.startsWith("attachment://") == true) {
                        e.put("image", JSONObject().put("url", "attachment://" + files.getJSONObject(0).optString("filename", "pupdates.png")))
                    }
                }
            } else if (embeds != null) for (i in 0 until embeds.length()) embeds.getJSONObject(i).remove("image")
            return obj(call("PATCH", "/channels/$channel/messages/$message", new))
        }

        fun delete(channel: String, message: String) { call("DELETE", "/channels/$channel/messages/$message") }

        fun setProfile(username: String? = null, avatar: Core.Picture? = null, clearAvatar: Boolean = false): JSONObject {
            val body = JSONObject()
            if (!username.isNullOrBlank()) body.put("username", username.take(32))
            if (avatar != null) body.put("avatar", Core.avatarDataUri(avatar)) else if (clearAvatar) body.put("avatar", JSONObject.NULL)
            if (body.length() == 0) throw Core.PupError("Nothing to change")
            return obj(call("PATCH", "/users/@me", body))
        }
    }

    /** adds a post to the recent list (newest first, at most keep) */
    fun remember(posts: JSONArray, entry: JSONObject, keep: Int = 20): JSONArray {
        val out = JSONArray().put(entry)
        for (i in 0 until posts.length()) {
            val p = posts.getJSONObject(i)
            if (p.optString("message") != entry.optString("message") && out.length() < keep) out.put(p)
        }
        return out
    }
}
