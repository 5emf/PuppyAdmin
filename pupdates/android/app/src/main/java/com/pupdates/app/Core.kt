package com.pupdates.app

import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.UUID

/** Everything Pupdates does that is not the screen (the same rules as the desktop app's core.py). */
object Core {
    const val APP = "Pupdates"
    const val REPO = "5emf/PuppyAdmin"
    const val BRANCH = "ccr-3b4dfcff-nyfy0w"
    val LOADSTRING = "local H=game:GetService(\"HttpService\") local ok,sha=pcall(function() return H:JSONDecode(game:HttpGet(" +
        "\"https://api.github.com/repos/$REPO/commits/$BRANCH\")).sha end) loadstring(game:HttpGet(" +
        "\"https://raw.githubusercontent.com/$REPO/\"..(ok and sha or \"$BRANCH\")..\"/PuppyAdmin.lua\"))()"
    val COLORS = linkedMapOf("Orange" to 0xF59B28, "Blue" to 0x5AA9FF, "Green" to 0x6FDC8C, "Red" to 0xE84A5F,
        "Grey" to 0x9B9CA8, "Purple" to 0xA064F0)
    val PINGS = listOf("none", "@here", "@everyone", "role")
    const val MAX_DESC = 4096
    const val MAX_FIELD = 1024
    const val MAX_TITLE = 256
    const val MAX_CONTENT = 2000
    const val MAX_IMAGE = 8 * 1024 * 1024
    private val WEBHOOK_RE = Regex("^https://(?:ptb\\.|canary\\.)?discord(?:app)?\\.com/api/webhooks/\\d+/[\\w-]+$")

    class PupError(message: String) : Exception(message)

    data class Picture(val data: ByteArray, val mime: String, val name: String, val label: String)

    // ------------------------------------------------------------------ text helpers
    fun validWebhook(url: String?) = WEBHOOK_RE.matches((url ?: "").trim())

    fun validRelay(url: String?): Boolean {
        val u = (url ?: "").trim()
        return u.startsWith("https://") && !u.contains(" ") && u.length > 10
    }

    fun redact(text: String, vararg secrets: String?): String {
        var t = text.replace(Regex("(discord(?:app)?\\.com/api/webhooks/\\d+/)[\\w-]+"), "$1***")
        t = t.replace(Regex("pup_[\\w-]{8,}"), "pup_***")
        t = t.replace(Regex("[\\w-]{18,}\\.[\\w-]{4,}\\.[\\w-]{20,}"), "***")   // Discord bot tokens
        for (s in secrets) if (!s.isNullOrEmpty()) t = t.replace(s, "***")
        return t
    }

    fun cleanSubject(line: String?): String {
        val s = (line ?: "").trim()
        val low = s.lowercase()
        if (s.isEmpty() || low.startsWith("co-authored-by") || low.startsWith("claude-session") || low.startsWith("merge ")) return ""
        return s.trimEnd('.')
    }

    fun bullets(subjects: List<String>, limit: Int = 3500): String {
        val clean = subjects.map { cleanSubject(it) }.filter { it.isNotEmpty() }
        val out = mutableListOf<String>()
        var used = 0
        for ((i, s) in clean.withIndex()) {
            val line = "- " + if (s.length <= 300) s else s.substring(0, 297) + "..."
            val rest = clean.size - i
            if (used + line.length + 1 + "\n... and $rest more".length > limit && out.isNotEmpty()) {
                out.add("... and $rest more")
                break
            }
            out.add(line)
            used += line.length + 1
        }
        return out.joinToString("\n")
    }

    // ------------------------------------------------------------------ pictures
    fun imageKind(d: ByteArray): Pair<String, String>? {
        fun starts(vararg b: Int) = d.size >= b.size && b.indices.all { (d[it].toInt() and 0xFF) == b[it] }
        return when {
            starts(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) -> "image/png" to "png"
            starts(0xFF, 0xD8, 0xFF) -> "image/jpeg" to "jpg"
            starts(0x47, 0x49, 0x46, 0x38) -> "image/gif" to "gif"
            d.size > 12 && starts(0x52, 0x49, 0x46, 0x46) && String(d, 8, 4, Charsets.US_ASCII) == "WEBP" -> "image/webp" to "webp"
            else -> null
        }
    }

    fun picture(data: ByteArray, label: String): Picture {
        if (data.size > MAX_IMAGE) throw PupError("That picture is bigger than 8 MB")
        val kind = imageKind(data) ?: throw PupError("Pictures must be PNG, JPG, GIF or WEBP")
        return Picture(data, kind.first, "pupdates.${kind.second}", label)
    }

    class FilePart(val field: String, val name: String, val mime: String, val data: ByteArray)

    fun multipart(fields: List<Pair<String, String>>, files: List<FilePart>): Pair<ByteArray, String> {
        val boundary = "pupdates" + UUID.randomUUID().toString().replace("-", "")
        val out = ByteArrayOutputStream()
        for ((name, value) in fields) {
            out.write("--$boundary\r\nContent-Disposition: form-data; name=\"$name\"\r\nContent-Type: application/json\r\n\r\n".toByteArray())
            out.write(value.toByteArray(Charsets.UTF_8))
            out.write("\r\n".toByteArray())
        }
        for (f in files) {
            out.write("--$boundary\r\nContent-Disposition: form-data; name=\"${f.field}\"; filename=\"${f.name}\"\r\nContent-Type: ${f.mime}\r\n\r\n".toByteArray())
            out.write(f.data)
            out.write("\r\n".toByteArray())
        }
        out.write("--$boundary--\r\n".toByteArray())
        return out.toByteArray() to "multipart/form-data; boundary=$boundary"
    }

    // ------------------------------------------------------------------ Discord payloads
    data class Post(val title: String, val message: String, val color: String = "Orange", val ping: String = "none",
                    val roleId: String = "", val loadstring: Boolean = false, val username: String = APP, val embed: Boolean = true,
                    val avatarUrl: String = "")

    fun validAvatarUrl(url: String?): Boolean {
        val u = (url ?: "").trim()
        return u.startsWith("https://") && !u.contains(" ") && u.length <= 2000
    }

    fun buildPayload(p: Post, imageName: String? = null): JSONObject {
        val body = JSONObject().put("username", p.username.ifBlank { APP }.take(80))
            .put("allowed_mentions", JSONObject().put("parse", JSONArray()))
        if (p.avatarUrl.isNotBlank()) {
            if (!validAvatarUrl(p.avatarUrl)) throw PupError("The post picture must be an https:// link to an image")
            body.put("avatar_url", p.avatarUrl.trim())
        }
        var mention = ""
        when (p.ping) {
            "@here", "@everyone" -> {
                mention = p.ping
                body.put("allowed_mentions", JSONObject().put("parse", JSONArray().put("everyone")))
            }
            "role" -> {
                val rid = p.roleId.trim()
                if (rid.isEmpty() || !rid.all { it.isDigit() }) throw PupError("A role ping needs the role's id (a number: long-press the role > Copy Role ID)")
                mention = "<@&$rid>"
                body.put("allowed_mentions", JSONObject().put("roles", JSONArray().put(rid)))
            }
        }
        val message = p.message.trim()
        val title = p.title.trim()
        if (!p.embed) {
            var text = listOf(mention, if (title.isNotEmpty()) "**$title**" else "", message).filter { it.isNotEmpty() }.joinToString("\n")
            if (p.loadstring) text += "\n```lua\n$LOADSTRING\n```"
            if (text.isEmpty() && imageName == null) throw PupError("Write a message or add a picture")
            return body.put("content", text.take(MAX_CONTENT))
        }
        val e = JSONObject().put("title", title.ifEmpty { APP }.take(MAX_TITLE))
            .put("color", COLORS[p.color] ?: COLORS.getValue("Orange"))
            .put("description", message.take(MAX_DESC).ifEmpty { "-" })
        if (p.loadstring) e.put("fields", JSONArray().put(JSONObject().put("name", "Loadstring").put("value", "```lua\n$LOADSTRING\n```".take(MAX_FIELD))))
        if (imageName != null) e.put("image", JSONObject().put("url", "attachment://$imageName"))
        body.put("embeds", JSONArray().put(e))
        if (mention.isNotEmpty()) body.put("content", mention)
        return body
    }

    fun relayFields(p: Post): JSONObject = JSONObject().put("title", p.title.trim()).put("message", p.message.trim())
        .put("color", COLORS[p.color] ?: COLORS.getValue("Orange")).put("ping", p.ping).put("roleId", p.roleId.trim())
        .put("loadstring", p.loadstring).put("username", p.username.ifBlank { APP }.take(80)).put("embed", p.embed)
        .put("avatarUrl", p.avatarUrl.trim())

    fun previewText(body: JSONObject, picture: Picture?): String {
        val lines = mutableListOf<String>()
        val embeds = body.optJSONArray("embeds")
        if (embeds != null && embeds.length() > 0) {
            val e = embeds.getJSONObject(0)
            if (body.has("content")) lines.add(body.getString("content"))
            lines += listOf(e.getString("title").uppercase(), "", e.getString("description"))
            val fields = e.optJSONArray("fields")
            if (fields != null) for (i in 0 until fields.length()) {
                val f = fields.getJSONObject(i)
                lines += listOf("", f.getString("name") + ":", f.getString("value"))
            }
        } else lines.add(body.optString("content"))
        if (picture != null) lines += listOf("", "[picture: ${picture.label}]")
        return lines.joinToString("\n")
    }

    // ------------------------------------------------------------------ HTTP
    class Response(val code: Int, val body: String)

    fun interface Http {
        fun request(method: String, url: String, headers: Map<String, String>, body: ByteArray?): Response
    }

    val NET = Http { method, url, headers, body ->
        val c = URL(url).openConnection() as HttpURLConnection
        try {
            try {
                c.requestMethod = method
            } catch (e: java.net.ProtocolException) {
                // the JDK's HttpURLConnection refuses PATCH (Android's allows it): set the field it checks
                var k: Class<*>? = c.javaClass
                var done = false
                while (k != null && !done) {
                    try { k.getDeclaredField("method").apply { isAccessible = true }.set(c, method); done = true }
                    catch (x: NoSuchFieldException) { k = k.superclass }
                    catch (x: Exception) { break }
                }
                if (!done) throw PupError("This phone cannot send a $method request")
            }
            c.connectTimeout = 20000
            c.readTimeout = 30000
            c.setRequestProperty("User-Agent", "Pupdates-Android/1")
            for ((k, v) in headers) c.setRequestProperty(k, v)
            if (body != null) {
                c.doOutput = true
                c.setFixedLengthStreamingMode(body.size)
                c.outputStream.use { it.write(body) }
            }
            val code = c.responseCode
            val stream = if (code in 200..299) c.inputStream else c.errorStream
            Response(code, stream?.use { String(it.readBytes(), Charsets.UTF_8) } ?: "")
        } catch (e: java.io.IOException) {
            throw PupError("Could not connect: ${e.message ?: e.javaClass.simpleName}")
        } finally {
            c.disconnect()
        }
    }

    private fun errorText(r: Response): String {
        val fromBody = try { JSONObject(r.body).optString("error") } catch (e: Exception) { "" }
        if (fromBody.isNotEmpty()) return fromBody
        return when (r.code) {
            401 -> "not allowed (the webhook was deleted, or your key is wrong / removed)"
            404 -> "it no longer exists"
            400 -> "the message was not accepted (too long, or empty)"
            429 -> "too many posts: wait a minute"
            else -> "HTTP ${r.code}"
        }
    }

    private fun send(http: Http, method: String, url: String, headers: Map<String, String>, body: ByteArray?,
                     secrets: List<String?>, tries: Int = 1, sleep: (Long) -> Unit = { Thread.sleep(it) }): String {
        repeat(tries) { attempt ->
            val r = http.request(method, url, headers, body)
            if (r.code in 200..299) return r.body
            if (r.code == 429 && attempt < tries - 1) {
                val wait = try { JSONObject(r.body).optDouble("retry_after", 2.0) } catch (e: Exception) { 2.0 }
                sleep((wait.coerceIn(0.0, 30.0) * 1000).toLong())
                return@repeat
            }
            throw PupError(redact(errorText(r), *secrets.toTypedArray()))
        }
        throw PupError("Still rate-limited: try again in a minute")
    }

    fun postWebhook(http: Http, url: String, body: JSONObject, picture: Picture?, sleep: (Long) -> Unit = { Thread.sleep(it) }): String {
        val u = url.trim()
        if (!validWebhook(u)) throw PupError("That is not a Discord webhook URL (channel > Edit Channel > Integrations > Webhooks > Copy Webhook URL)")
        val (data, type) = if (picture != null)
            multipart(listOf("payload_json" to body.toString()), listOf(FilePart("files[0]", picture.name, picture.mime, picture.data)))
        else body.toString().toByteArray(Charsets.UTF_8) to "application/json"
        try {
            val out = send(http, "POST", "$u?wait=true", mapOf("Content-Type" to type), data, listOf(u), tries = 3, sleep = sleep)
            return try { JSONObject(out).optString("id") } catch (e: Exception) { "" }
        } catch (e: PupError) {
            throw PupError("Discord refused the post: ${e.message}")
        }
    }

    private fun relayUrl(base: String, path: String) = base.trim().trimEnd('/') + path

    /** the webhook's saved picture as Discord wants it (PNG / JPG / GIF) */
    fun avatarDataUri(p: Picture): String {
        if (p.mime !in listOf("image/png", "image/jpeg", "image/gif")) throw PupError("The webhook picture must be PNG, JPG or GIF")
        return "data:${p.mime};base64," + java.util.Base64.getEncoder().encodeToString(p.data)
    }

    /** changes the webhook's own picture for good with only its URL (Discord's "modify webhook with token"); null removes it */
    fun setWebhookAvatar(http: Http, url: String, picture: Picture?) {
        val u = url.trim()
        if (!validWebhook(u)) throw PupError("Save your webhook first")
        val body = JSONObject().put("avatar", if (picture != null) avatarDataUri(picture) else JSONObject.NULL)
        try {
            send(http, "PATCH", u, mapOf("Content-Type" to "application/json"), body.toString().toByteArray(Charsets.UTF_8), listOf(u), tries = 2)
        } catch (e: PupError) {
            throw PupError("Discord did not change the picture: ${e.message}")
        }
    }

    /** owner, relay mode: the relay changes its webhook's picture */
    fun adminAvatar(http: Http, base: String, admin: String, picture: Picture?) {
        val body = JSONObject().put("avatar", if (picture != null) avatarDataUri(picture) else JSONObject.NULL)
        send(http, "POST", relayUrl(base, "/admin/avatar"), mapOf("X-Admin-Key" to admin, "Content-Type" to "application/json"),
            body.toString().toByteArray(Charsets.UTF_8), listOf(admin))
    }

    fun postRelay(http: Http, base: String, key: String, fields: JSONObject, picture: Picture?): JSONObject {
        if (!validRelay(base)) throw PupError("The relay address must start with https://")
        if (key.isBlank()) throw PupError("Enter your access key (ask the owner to whitelist you)")
        val files = if (picture != null) listOf(FilePart("image", picture.name, picture.mime, picture.data)) else emptyList()
        val (data, type) = multipart(listOf("payload" to fields.toString()), files)
        val out = send(http, "POST", relayUrl(base, "/post"), mapOf("Authorization" to "Bearer $key", "Content-Type" to type), data, listOf(key))
        return JSONObject(out.ifEmpty { "{}" })
    }

    fun relayMe(http: Http, base: String, key: String): JSONObject =
        JSONObject(send(http, "GET", relayUrl(base, "/me"), mapOf("Authorization" to "Bearer $key"), null, listOf(key)))

    data class Member(val name: String, val canPing: Boolean)

    fun adminList(http: Http, base: String, admin: String): List<Member> {
        val arr = JSONArray(send(http, "GET", relayUrl(base, "/admin/users"), mapOf("X-Admin-Key" to admin), null, listOf(admin)))
        return (0 until arr.length()).map { arr.getJSONObject(it) }.map { Member(it.optString("name"), it.optBoolean("canPing")) }
            .sortedBy { it.name.lowercase() }
    }

    fun adminAdd(http: Http, base: String, admin: String, name: String, canPing: Boolean): JSONObject {
        val body = JSONObject().put("name", name).put("canPing", canPing).toString().toByteArray(Charsets.UTF_8)
        return JSONObject(send(http, "POST", relayUrl(base, "/admin/users"),
            mapOf("X-Admin-Key" to admin, "Content-Type" to "application/json"), body, listOf(admin)))
    }

    /** owner: the relay installs / updates the moderation slash commands -> {count, interactionsUrl, publicKeySet} */
    fun adminCommands(http: Http, base: String, admin: String): JSONObject = JSONObject(send(http, "POST", relayUrl(base, "/admin/commands"),
        mapOf("X-Admin-Key" to admin, "Content-Type" to "application/json"), "{}".toByteArray(Charsets.UTF_8), listOf(admin)))

    // ------------------------------------------------------------------ moderation (the relay's slash commands, owner only)
    data class ModServer(val guild: String, val name: String, val cases: Int, val log: Boolean, val autoWarns: Int,
                         val autoMinutes: Int, val staffUsers: Int, val staffRoles: Int)

    fun modServers(http: Http, base: String, admin: String): List<ModServer> {
        val arr = JSONArray(send(http, "GET", relayUrl(base, "/admin/mod"), mapOf("X-Admin-Key" to admin), null, listOf(admin)))
        return (0 until arr.length()).map { arr.getJSONObject(it) }.map {
            val st = it.optJSONObject("staff") ?: JSONObject()
            ModServer(it.optString("guild"), it.optString("name").ifEmpty { it.optString("guild") }, it.optInt("cases"),
                it.optString("log").isNotEmpty(), it.optInt("autoWarns"), it.optInt("autoMinutes", 60), st.optInt("users"), st.optInt("roles"))
        }
    }

    /** one page of cases, newest first; next = pass as before for more (null = no more) */
    fun modCases(http: Http, base: String, admin: String, guild: String, user: String = "", before: Int? = null, limit: Int = 25): Pair<List<JSONObject>, Int?> {
        var q = "limit=$limit"
        if (user.isNotEmpty()) q += "&user=" + URLEncoder.encode(user, "UTF-8")
        if (before != null) q += "&before=$before"
        val o = JSONObject(send(http, "GET", relayUrl(base, "/admin/mod/${URLEncoder.encode(guild, "UTF-8")}/cases?$q"), mapOf("X-Admin-Key" to admin), null, listOf(admin)))
        val arr = o.optJSONArray("cases") ?: JSONArray()
        return (0 until arr.length()).map { arr.getJSONObject(it) } to (if (o.isNull("next")) null else o.optInt("next"))
    }

    fun modClear(http: Http, base: String, admin: String, guild: String, number: Int) {
        send(http, "POST", relayUrl(base, "/admin/mod/${URLEncoder.encode(guild, "UTF-8")}/cases/$number/clear"),
            mapOf("X-Admin-Key" to admin, "Content-Type" to "application/json"), "{}".toByteArray(Charsets.UTF_8), listOf(admin))
    }

    fun minutesText(m: Int): String = when {
        m > 0 && m % 1440 == 0 -> "${m / 1440} day" + (if (m == 1440) "" else "s")
        m > 0 && m % 60 == 0 -> "${m / 60} hour" + (if (m == 60) "" else "s")
        else -> "$m minute" + (if (m == 1) "" else "s")
    }

    /** one case as a list row, like the desktop's core.case_line */
    fun caseLine(c: JSONObject, zone: java.util.TimeZone = java.util.TimeZone.getDefault()): String {
        var what = if (c.optString("type") == "timeout") "timeout " + minutesText(c.optInt("minutes")) else c.optString("type", "?")
        if (c.optBoolean("auto")) what += " (automatic)"
        if (c.optBoolean("cleared")) what += " (cleared)"
        val when_ = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).apply { timeZone = zone }.format(java.util.Date(c.optLong("at")))
        val reason = c.optString("reason").replace("\n", " ")
        return "#${c.optInt("n")}  $when_  $what  ${c.optString("userTag").ifEmpty { c.optString("user", "?") }}  by " +
            c.optString("modTag").ifEmpty { c.optString("mod", "?") } + (if (reason.isNotEmpty()) ": " + reason.take(120) else "")
    }

    fun adminRemove(http: Http, base: String, admin: String, name: String) {
        send(http, "DELETE", relayUrl(base, "/admin/users/" + URLEncoder.encode(name, "UTF-8").replace("+", "%20")),
            mapOf("X-Admin-Key" to admin), null, listOf(admin))
    }

    // ------------------------------------------------------------------ GitHub (public repo, no token)
    data class Latest(val sha: String, val build: String?, val version: String?, val commits: List<Pair<String, String>>)

    fun scriptBuild(text: String) = Regex("local\\s+SCRIPT_BUILD\\s*=\\s*\"([^\"]+)\"").find(text)?.groupValues?.get(1)
    fun payloadVersion(text: String) = Regex("PAYLOAD_VERSION\\s*=\\s*\"([^\"]+)\"").find(text)?.groupValues?.get(1)

    private fun get(http: Http, url: String): String {
        val r = http.request("GET", url, mapOf("Accept" to "application/vnd.github+json"), null)
        if (r.code !in 200..299) throw PupError("GitHub answered HTTP ${r.code}")
        return r.body
    }

    fun latest(http: Http): Latest {
        val arr = JSONArray(get(http, "https://api.github.com/repos/$REPO/commits?sha=$BRANCH&per_page=40"))
        if (arr.length() == 0) throw PupError("GitHub returned no commits")
        val commits = (0 until arr.length()).map { arr.getJSONObject(it) }.map {
            it.getString("sha") to (it.optJSONObject("commit")?.optString("message") ?: "").lineSequence().firstOrNull().orEmpty()
        }
        val sha = commits[0].first
        val raw = "https://raw.githubusercontent.com/$REPO/$sha/"
        return Latest(sha, scriptBuild(get(http, raw + "PuppyAdmin.lua")),
            payloadVersion(get(http, raw + "companion/puppy_companion/_payload.py")), commits)
    }

    fun subjectsSince(commits: List<Pair<String, String>>, lastSha: String?, cap: Int = 15): List<String> {
        val out = mutableListOf<String>()
        for ((sha, subject) in commits) {
            if (!lastSha.isNullOrEmpty() && sha.startsWith(lastSha)) break
            out.add(subject)
            if (out.size >= cap && lastSha.isNullOrEmpty()) break
        }
        return out.reversed()
    }

    fun scriptTemplate(info: Latest, lastSha: String?): Pair<String, String> {
        val text = bullets(subjectsSince(info.commits, lastSha)).ifEmpty { "- Small fixes" }
        return "Puppy Admin updated - build ${info.build ?: "?"}" to "$text\n\nExecute Puppy Admin again: a newer build replaces the running one."
    }

    fun companionTemplate(info: Latest, lastSha: String?): Pair<String, String> {
        val text = bullets(subjectsSince(info.commits, lastSha)).ifEmpty { "- Small fixes" }
        return "Puppy Companion updated - ${info.version ?: "?"}" to "$text\n\nRestart Puppy Companion: it downloads the update itself."
    }
}
