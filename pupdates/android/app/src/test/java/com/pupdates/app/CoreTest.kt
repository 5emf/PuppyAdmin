package com.pupdates.app

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class CoreTest {
    private val hook = "https://discord.com/api/webhooks/1575303315/abc-DEF_9"
    private val relay = "https://pupdates-relay.example.workers.dev"
    private val png = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3)

    private class Sent(val method: String, val url: String, val headers: Map<String, String>, val body: ByteArray?)

    private class Fake(val answers: MutableList<Core.Response>) : Core.Http {
        val sent = mutableListOf<Sent>()
        override fun request(method: String, url: String, headers: Map<String, String>, body: ByteArray?): Core.Response {
            sent.add(Sent(method, url, headers, body))
            return answers.removeAt(0)
        }
    }

    private inline fun <reified T : Throwable> fails(block: () -> Unit): T {
        try { block() } catch (e: Throwable) { if (e is T) return e; throw e }
        fail("expected ${T::class.simpleName}")
        throw IllegalStateException()
    }

    @Test fun webhookCheckAndRedact() {
        assertTrue(Core.validWebhook(hook))
        assertTrue(Core.validWebhook("https://discordapp.com/api/webhooks/1/x"))
        assertFalse(Core.validWebhook("https://evil.example/api/webhooks/1/x"))
        assertFalse(Core.validRelay("http://insecure.example"))
        assertFalse(Core.redact("failed for $hook").contains("abc-DEF_9"))
        assertEquals("key pup_*** leaked", Core.redact("key pup_abcdefghijkl leaked"))
    }

    @Test fun embedPayloadAndPings() {
        val b = Core.buildPayload(Core.Post("Hi", "Body", "Blue"))
        assertEquals(0, b.getJSONObject("allowed_mentions").getJSONArray("parse").length())
        assertFalse(b.has("content"))
        assertEquals(Core.COLORS["Blue"], b.getJSONArray("embeds").getJSONObject(0).getInt("color"))
        assertEquals("@here", Core.buildPayload(Core.Post("a", "b", ping = "@here")).getString("content"))
        val role = Core.buildPayload(Core.Post("a", "b", ping = "role", roleId = "42"))
        assertEquals("<@&42>", role.getString("content"))
        assertEquals("42", role.getJSONObject("allowed_mentions").getJSONArray("roles").getString(0))
        fails<Core.PupError> { Core.buildPayload(Core.Post("a", "b", ping = "role", roleId = "mods")) }
        val pic = Core.buildPayload(Core.Post("a", "b"), "pupdates.png")
        assertEquals("attachment://pupdates.png", pic.getJSONArray("embeds").getJSONObject(0).getJSONObject("image").getString("url"))
        val long = Core.buildPayload(Core.Post("t".repeat(999), "m".repeat(9999))).getJSONArray("embeds").getJSONObject(0)
        assertTrue(long.getString("title").length <= 256 && long.getString("description").length <= 4096)
    }

    @Test fun plainMessage() {
        assertEquals("just text", Core.buildPayload(Core.Post("", "just text", embed = false)).getString("content"))
        val b = Core.buildPayload(Core.Post("Head", "text", ping = "@everyone", loadstring = true, embed = false))
        assertTrue(b.getString("content").startsWith("@everyone\n**Head**\ntext\n```lua"))
        assertEquals("", Core.buildPayload(Core.Post("", "", embed = false), "pupdates.png").getString("content"))
        fails<Core.PupError> { Core.buildPayload(Core.Post("", "", embed = false)) }
    }

    @Test fun pictures() {
        assertEquals("image/png" to "png", Core.imageKind(png))
        assertEquals("image/jpeg" to "jpg", Core.imageKind(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0)))
        assertEquals("image/webp" to "webp", Core.imageKind("RIFF\u0000\u0000\u0000\u0000WEBPVP8 ".toByteArray(Charsets.ISO_8859_1)))
        assertNull(Core.imageKind("hello".toByteArray()))
        assertEquals("pupdates.png", Core.picture(png, "cat.png").name)
        fails<Core.PupError> { Core.picture("text".toByteArray(), "x.txt") }
        val (body, type) = Core.multipart(listOf("payload_json" to "{}"), listOf(Core.FilePart("files[0]", "pupdates.png", "image/png", png)))
        assertTrue(type.startsWith("multipart/form-data; boundary="))
        val text = String(body, Charsets.ISO_8859_1)
        assertTrue(text.contains("name=\"files[0]\"; filename=\"pupdates.png\""))
        assertTrue(text.endsWith(type.substringAfter("boundary=") + "--\r\n"))
    }

    @Test fun postWebhookRetriesAndHidesTheSecret() {
        val fake = Fake(mutableListOf(Core.Response(429, "{\"retry_after\":0.01}"), Core.Response(200, "{\"id\":\"999\"}")))
        assertEquals("999", Core.postWebhook(fake, hook, Core.buildPayload(Core.Post("a", "b")), null) { })
        assertEquals("$hook?wait=true", fake.sent[1].url)
        assertEquals("application/json", fake.sent[1].headers["Content-Type"])
        val withPic = Fake(mutableListOf(Core.Response(200, "{}")))
        Core.postWebhook(withPic, hook, Core.buildPayload(Core.Post("a", "b"), "pupdates.png"), Core.picture(png, "cat.png")) { }
        assertTrue(withPic.sent[0].headers.getValue("Content-Type").startsWith("multipart/form-data"))
        val gone = Fake(mutableListOf(Core.Response(404, "")))
        val e = fails<Core.PupError> { Core.postWebhook(gone, hook, JSONObject(), null) { } }
        assertTrue(e.message!!.contains("no longer exists"))
        assertFalse(e.message!!.contains("abc-DEF_9"))
        fails<Core.PupError> { Core.postWebhook(gone, "https://example.com/x", JSONObject(), null) { } }
    }

    @Test fun relayAndWhitelist() {
        val fake = Fake(mutableListOf(
            Core.Response(200, "{\"name\":\"Alt Pup\",\"key\":\"pup_newkey12345\"}"),
            Core.Response(200, JSONArray().put(JSONObject().put("name", "b").put("canPing", true)).put(JSONObject().put("name", "A")).toString()),
            Core.Response(200, "{\"ok\":true,\"pingDropped\":true}"),
            Core.Response(200, "{\"ok\":true}"),
            Core.Response(401, "{\"error\":\"Not on the whitelist (wrong or removed access key)\"}")))
        assertEquals("pup_newkey12345", Core.adminAdd(fake, relay, "admin", "Alt Pup", false).getString("key"))
        assertEquals("admin", fake.sent[0].headers["X-Admin-Key"])
        assertEquals(listOf("A", "b"), Core.adminList(fake, relay, "admin").map { it.name })
        val out = Core.postRelay(fake, relay, "pup_newkey12345", Core.relayFields(Core.Post("T", "M", ping = "@here")), Core.picture(png, "c.png"))
        assertTrue(out.getBoolean("pingDropped"))
        assertEquals("Bearer pup_newkey12345", fake.sent[2].headers["Authorization"])
        Core.adminRemove(fake, relay, "admin", "Alt Pup")
        assertEquals("$relay/admin/users/Alt%20Pup", fake.sent[3].url)
        val e = fails<Core.PupError> { Core.relayMe(fake, relay, "pup_newkey12345") }
        assertTrue(e.message!!.contains("Not on the whitelist"))
    }

    @Test fun githubTemplates() {
        val commits = JSONArray()
            .put(JSONObject().put("sha", "c3".repeat(20)).put("commit", JSONObject().put("message", "Mobile mode\n\nCo-Authored-By: x")))
            .put(JSONObject().put("sha", "c2".repeat(20)).put("commit", JSONObject().put("message", "SAO menu tweaks")))
            .put(JSONObject().put("sha", "c1".repeat(20)).put("commit", JSONObject().put("message", "Older change")))
        val fake = Fake(mutableListOf(Core.Response(200, commits.toString()),
            Core.Response(200, "local SCRIPT_BUILD = \"2026.11.25-86\" -- x"), Core.Response(200, "PAYLOAD_VERSION = \"1.7.1\"\n")))
        val info = Core.latest(fake)
        assertEquals("2026.11.25-86", info.build)
        assertEquals("1.7.1", info.version)
        val (title, text) = Core.scriptTemplate(info, null)
        assertEquals("Puppy Admin updated - build 2026.11.25-86", title)
        assertTrue(text.contains("- Older change\n- SAO menu tweaks\n- Mobile mode"))
        val (_, since) = Core.companionTemplate(info, "c2c2")
        assertTrue(since.startsWith("- Mobile mode\n\nRestart"))
    }
}
