package com.pupdates.app

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** The same checks as the desktop's test_bot_client. */
class DiscordBotTest {
    // a made-up token, put together at run time so no token-shaped text sits in the repository
    private val token = listOf("MTIzNDU2Nzg5MDEyMzQ1Njc4", "Ga" + "BcDe", "abcdefghijklmnop" + "qrstuvwxyz012345").joinToString(".")
    private val png = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3)

    private class Sent(val method: String, val url: String, val headers: Map<String, String>, val body: ByteArray?)

    private inner class FakeDiscord : Core.Http {
        val sent = mutableListOf<Sent>()
        val messages = HashMap<String, JSONObject>()
        var next = 900
        override fun request(method: String, url: String, headers: Map<String, String>, body: ByteArray?): Core.Response {
            sent.add(Sent(method, url, headers, body))
            if (headers["Authorization"] != "Bot $token") return Core.Response(401, """{"message":"401: Unauthorized","code":0}""")
            val path = url.removePrefix(DiscordBot.API)
            Regex("^/channels/(\\d+)/messages(?:/(\\d+))?(/crosspost)?$").find(path)?.let { m ->
                val (ch, mid, cross) = m.destructured
                if (ch == "99") return Core.Response(403, """{"message":"Missing Permissions","code":50013}""")
                if (cross.isNotEmpty()) return Core.Response(200, messages[mid].toString())
                if (method == "POST") {
                    val id = (next++).toString()
                    val text = String(body!!, Charsets.ISO_8859_1)
                    val json = if (headers["Content-Type"]!!.startsWith("multipart")) JSONObject(text.substringAfter("\r\n\r\n").substringBefore("\r\n--"))
                               else JSONObject(text)
                    json.put("id", id).put("attachments", if (text.contains("filename=")) JSONArray().put(JSONObject().put("id", "a$id").put("filename", "pupdates.png")) else JSONArray())
                    messages[id] = json
                    return Core.Response(200, json.toString())
                }
                val msg = messages[mid] ?: return Core.Response(404, """{"message":"Unknown Message","code":10008}""")
                return when (method) {
                    "GET" -> Core.Response(200, msg.toString())
                    "PATCH" -> { val b = JSONObject(String(body!!)); b.keys().forEach { msg.put(it, b.get(it)) }; Core.Response(200, msg.toString()) }
                    else -> { messages.remove(mid); Core.Response(204, "") }
                }
            }
            return when (path) {
                "/users/@me" -> Core.Response(200, if (method == "GET") """{"id":"123456789012345678","username":"PupBot"}""" else String(body!!))
                "/users/@me/guilds" -> Core.Response(200, """[{"id":"2","name":"Zeta"},{"id":"1","name":"Puppy Server"}]""")
                "/guilds/1/channels" -> Core.Response(200, """[{"id":"10","type":4,"name":"INFO","position":0},
                    {"id":"11","type":5,"name":"announcements","position":0,"parent_id":"10"},{"id":"12","type":0,"name":"general","position":1,"parent_id":"10"},
                    {"id":"13","type":2,"name":"Voice","position":2},{"id":"14","type":0,"name":"lobby","position":0}]""")
                else -> throw AssertionError("$method $url")
            }
        }
    }

    @Test fun tokensAndLinks() {
        assertTrue(DiscordBot.validToken(token))
        assertFalse(DiscordBot.validToken("https://discord.com/api/webhooks/1/x"))
        assertEquals("123456789012345678", DiscordBot.appId(token))
        assertTrue(DiscordBot.inviteUrl("123456789012345678")!!.contains("client_id=123456789012345678&scope=bot"))
        assertFalse(Core.redact("failed: $token").contains(token))
    }

    @Test fun postEditDelete() {
        val d = FakeDiscord()
        val c = DiscordBot.Client(d, token) { }
        assertEquals("PupBot", c.me().getString("username"))
        assertEquals(listOf("Puppy Server", "Zeta"), c.guilds().map { it.getString("name") })
        val chans = c.channels("1")
        assertEquals(listOf("lobby", "announcements", "general"), chans.map { it.name })
        assertEquals("INFO", chans[1].category)
        val pic = Core.picture(png, "cat.png")
        val body = Core.buildPayload(Core.Post("Hi", "there", avatarUrl = "https://x.y/a.png"), pic.name)
        val msg = c.post("11", body, pic)
        assertFalse(msg.has("username"))
        assertFalse(msg.has("avatar_url"))
        c.publish("11", msg.getString("id"))
        assertTrue(d.sent.last().url.endsWith("/crosspost"))
        c.edit("11", msg.getString("id"), Core.buildPayload(Core.Post("Hi again", "changed"), "pupdates.png"))
        val patched = JSONObject(String(d.sent.last().body!!))
        assertEquals("a${msg.getString("id")}", patched.getJSONArray("attachments").getJSONObject(0).getString("id"))
        c.delete("11", msg.getString("id"))
        try { c.message("11", msg.getString("id")); fail() } catch (e: Core.PupError) { assertTrue(e.message!!.contains("no longer exists")) }
        try { c.post("99", Core.buildPayload(Core.Post("a", "b")), null); fail() } catch (e: Core.PupError) { assertTrue(e.message!!.contains("missing a permission")) }
        try { DiscordBot.Client(d, token.dropLast(3) + "zzz").me(); fail() } catch (e: Core.PupError) { assertTrue(e.message!!.contains("wrong or was reset")) }
        assertEquals("Pup News", c.setProfile(username = "Pup News").getString("username"))
        val recent = DiscordBot.remember(JSONArray().put(JSONObject().put("message", "1")).put(JSONObject().put("message", "2")), JSONObject().put("message", "2"))
        assertEquals(listOf("2", "1"), (0 until recent.length()).map { recent.getJSONObject(it).getString("message") })
    }
}
