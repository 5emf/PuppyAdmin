package com.pupdates.app

import java.util.Base64
import org.json.JSONArray
import org.json.JSONObject

/**
 * Puppy Admin's shared tags (tags.json on main), the same rules as the desktop app's tags.py and
 * Puppy Admin's TagSync.sanitize. Reading needs nothing; saving needs a GitHub token with
 * Contents: read and write on the repository.
 */
object Tags {
    const val API = "https://api.github.com/repos/5emf/PuppyAdmin/contents/tags.json"
    const val BRANCH = "main"
    val FONTS = listOf("GothamBold", "Gotham", "GothamSemibold", "Code", "Arcade", "SourceSansBold", "FredokaOne", "Bangers", "SciFi", "Fantasy")
    val PFP_MODES = listOf("none", "avatar", "custom")
    const val MAX_TAGS = 200
    const val MAX_MEMBERS = 500
    // Roblox user lookups (from memory, not checked against Roblox's docs here)
    const val ROBLOX_BY_NAME = "https://users.roblox.com/v1/usernames/users"
    const val ROBLOX_BY_ID = "https://users.roblox.com/v1/users"

    private fun str(o: JSONObject, k: String, n: Int): String = (o.opt(k) as? String)?.take(n) ?: ""
    private fun num(o: JSONObject, k: String, lo: Double, hi: Double, def: Double): Double {
        val v = o.opt(k)
        if (v !is Number || v is Boolean) return def
        val d = v.toDouble()
        return if (d.isNaN()) def else d.coerceIn(lo, hi)
    }
    private fun rgb(v: Any?, def: IntArray): JSONArray {
        val a = v as? JSONArray
        if (a != null && a.length() >= 3 && (0 until 3).all { a.opt(it) is Number }) {
            return JSONArray().apply { for (i in 0 until 3) put(a.getDouble(i).coerceIn(0.0, 255.0).toInt()) }
        }
        return JSONArray().apply { def.forEach { put(it) } }
    }
    private fun number(d: Double): Any = if (d == Math.floor(d)) d.toInt() else d

    fun newTag(name: String = "New tag"): JSONObject = clean(JSONObject().put("name", name).put("text", name))

    fun clean(d: JSONObject, allowDefault: Boolean = true): JSONObject {
        val bd = d.optJSONObject("backdrop") ?: JSONObject()
        val pf = d.optJSONObject("pfp") ?: JSONObject()
        val members = JSONArray()
        val seen = HashSet<String>()
        val src = d.optJSONArray("members") ?: JSONArray()
        for (i in 0 until minOf(src.length(), MAX_MEMBERS)) {
            val m = src.opt(i)?.let { if (it is Number) it.toLong().toString() else it.toString() } ?: continue
            if (m.isNotEmpty() && m.length <= 20 && m.all { it.isDigit() } && seen.add(m)) members.put(m)
        }
        val text = str(d, "text", 40)
        val out = JSONObject()
            .put("name", str(d, "name", 30).ifEmpty { text.ifEmpty { "Tag" } })
            .put("text", text).put("sub", str(d, "sub", 40))
            .put("color", rgb(d.opt("color"), intArrayOf(255, 255, 255)))
            .put("rainbow", d.opt("rainbow") == true)
            .put("size", number(num(d, "size", 8.0, 48.0, 22.0)))
            .put("offset", number(num(d, "offset", 0.0, 12.0, 3.0)))
            .put("font", str(d, "font", 40).ifEmpty { "GothamBold" })
            .put("backdrop", JSONObject().put("on", bd.opt("on") == true).put("color", rgb(bd.opt("color"), intArrayOf(18, 18, 22)))
                .put("transparency", num(bd, "transparency", 0.0, 1.0, 0.35)).put("image", str(bd, "image", 300))
                .put("imageTransparency", num(bd, "imageTransparency", 0.0, 1.0, 0.15)).put("round", bd.opt("round") != false))
            .put("pfp", JSONObject().put("mode", pf.optString("mode").takeIf { it == "avatar" || it == "custom" } ?: "none")
                .put("image", str(pf, "image", 300)).put("round", pf.opt("round") != false))
            .put("members", members)
        if (allowDefault && d.opt("isDefault") == true) out.put("isDefault", true)
        return out
    }

    fun sanitize(list: JSONArray): MutableList<JSONObject> {
        val out = mutableListOf<JSONObject>()
        var haveDefault = false
        for (i in 0 until minOf(list.length(), MAX_TAGS)) {
            val d = list.opt(i) as? JSONObject ?: continue
            if (d.opt("name") !is String) continue
            if (d.opt("isDefault") == true) {
                if (haveDefault) continue
                haveDefault = true
            }
            out.add(clean(d))
        }
        return out
    }

    fun members(t: JSONObject): MutableList<String> {
        val a = t.optJSONArray("members") ?: return mutableListOf()
        return (0 until a.length()).map { a.getString(it) }.toMutableList()
    }

    fun setMembers(t: JSONObject, ids: List<String>) { t.put("members", JSONArray(ids)) }

    fun ownerOf(list: List<JSONObject>, id: String): JSONObject? =
        list.firstOrNull { it.opt("isDefault") != true && members(it).contains(id) }

    fun hex(c: JSONArray) = String.format("#%02x%02x%02x", c.getInt(0), c.getInt(1), c.getInt(2))

    fun parseHex(text: String): JSONArray {
        val t = text.trim().removePrefix("#")
        if (t.length != 6 || !t.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }) throw Core.PupError("Colours are 6 hex digits, like #f59b28")
        return JSONArray().put(t.substring(0, 2).toInt(16)).put(t.substring(2, 4).toInt(16)).put(t.substring(4, 6).toInt(16))
    }

    fun encode(list: List<JSONObject>): String = JSONArray().apply { sanitize(JSONArray(list)).forEach { put(it) } }.toString()

    // ------------------------------------------------------------------ GitHub
    private fun headers(token: String?) = buildMap {
        put("Accept", "application/vnd.github+json")
        if (!token.isNullOrEmpty()) put("Authorization", "Bearer $token")
    }

    /** (tags, sha) */
    fun load(http: Core.Http, token: String?): Pair<MutableList<JSONObject>, String?> {
        val r = http.request("GET", "$API?ref=$BRANCH", headers(token), null)
        when {
            r.code == 404 -> return mutableListOf<JSONObject>() to null
            r.code in listOf(401, 403) && !token.isNullOrEmpty() -> throw Core.PupError("GitHub refused the token (${r.code})")
            r.code == 403 -> throw Core.PupError("GitHub's limit for reads without a token was reached: try later or save a token")
            r.code != 200 -> throw Core.PupError("GitHub answered HTTP ${r.code}")
        }
        val info = JSONObject(r.body)
        val text = String(Base64.getMimeDecoder().decode(info.optString("content")), Charsets.UTF_8)
        return sanitize(if (text.isBlank()) JSONArray() else JSONArray(text)) to info.optString("sha").ifEmpty { null }
    }

    /** writes the list; returns the new sha */
    fun save(http: Core.Http, list: List<JSONObject>, sha: String?, token: String?, message: String = "Pupdates: update tags"): String? {
        if (token.isNullOrEmpty()) throw Core.PupError("Saving tags needs a GitHub token (Contents: read and write on 5emf/PuppyAdmin)")
        val body = JSONObject().put("message", message).put("branch", BRANCH)
            .put("content", Base64.getEncoder().encodeToString(encode(list).toByteArray(Charsets.UTF_8)))
        if (sha != null) body.put("sha", sha)
        val r = http.request("PUT", API, headers(token) + ("Content-Type" to "application/json"), body.toString().toByteArray(Charsets.UTF_8))
        return when (r.code) {
            200, 201 -> JSONObject(r.body).optJSONObject("content")?.optString("sha")
            401, 403 -> throw Core.PupError("GitHub refused the token (${r.code}): it needs Contents: read and write on 5emf/PuppyAdmin")
            409, 422 -> throw Core.PupError("The tags changed somewhere else since you loaded them: press Load, then make your change again")
            else -> throw Core.PupError("GitHub answered HTTP ${r.code}")
        }
    }

    // ------------------------------------------------------------------ Roblox users
    private fun postJson(http: Core.Http, url: String, body: JSONObject): JSONArray {
        val r = http.request("POST", url, mapOf("Content-Type" to "application/json", "Accept" to "application/json"), body.toString().toByteArray())
        if (r.code != 200) throw Core.PupError("Roblox answered HTTP ${r.code}")
        return JSONObject(r.body).optJSONArray("data") ?: JSONArray()
    }

    /** (id, name or null) from a user id or a username */
    fun userId(http: Core.Http, text: String): Pair<String, String?> {
        val t = text.trim()
        if (t.isNotEmpty() && t.length <= 20 && t.all { it.isDigit() }) return t to null
        if (t.isEmpty()) throw Core.PupError("Type a username or a user id")
        val found = postJson(http, ROBLOX_BY_NAME, JSONObject().put("usernames", JSONArray().put(t)).put("excludeBannedUsers", false))
        if (found.length() == 0) throw Core.PupError("No Roblox user called $t")
        val u = found.getJSONObject(0)
        return u.get("id").toString() to u.optString("name", t)
    }

    fun userNames(http: Core.Http, ids: Collection<String>): Map<String, String> = try {
        val arr = JSONArray()
        ids.filter { s -> s.isNotEmpty() && s.all { it.isDigit() } }.take(100).forEach { arr.put(it.toLong()) }
        if (arr.length() == 0) emptyMap() else {
            val data = postJson(http, ROBLOX_BY_ID, JSONObject().put("userIds", arr).put("excludeBannedUsers", false))
            (0 until data.length()).associate { data.getJSONObject(it).get("id").toString() to data.getJSONObject(it).optString("name") }
        }
    } catch (e: Exception) { emptyMap() }
}
