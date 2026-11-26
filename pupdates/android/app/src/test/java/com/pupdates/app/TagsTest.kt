package com.pupdates.app

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class TagsTest {
    @Test fun cleaningMatchesPuppyAdmin() {
        val list = JSONArray("""[{"name":"${"x".repeat(50)}","text":"t","color":[300,-5,7.9],"size":99,"members":["12","ab",5,"12"],
            "pfp":{"mode":"weird"},"rainbow":"yes"},{"name":"D1","isDefault":true},{"name":"D2","isDefault":true},{"text":"no name"},7]""")
        val out = Tags.sanitize(list)
        assertEquals(2, out.size)
        val t = out[0]
        assertEquals(30, t.getString("name").length)
        assertEquals("[255,0,7]", t.getJSONArray("color").toString())
        assertEquals(48, t.getInt("size"))
        assertEquals(listOf("12", "5"), Tags.members(t))
        assertEquals("none", t.getJSONObject("pfp").getString("mode"))
        assertFalse(t.getBoolean("rainbow"))
        assertTrue(out[1].getBoolean("isDefault"))
        assertEquals("#f59b28", Tags.hex(Tags.parseHex("#F59B28")))
    }

    @Test fun loadAndSave() {
        val repoText = """[{"name":"Owner Tag","text":"Puppy Admin","members":["1","2"]}]"""
        var sha = "s1"
        val written = mutableListOf<String>()
        val http = Core.Http { method, url, headers, body ->
            when {
                url.startsWith(Tags.ROBLOX_BY_NAME) -> Core.Response(200, """{"data":[{"id":777,"name":"PupFriend"}]}""")
                method == "GET" -> Core.Response(200, JSONObject().put("sha", sha)
                    .put("content", Base64.getMimeEncoder().encodeToString(repoText.toByteArray())).toString())
                headers["Authorization"] != "Bearer ghp_good" -> Core.Response(401, "{}")
                else -> {
                    val b = JSONObject(String(body!!))
                    if (b.optString("sha") != sha) Core.Response(409, "{}") else {
                        written.add(String(Base64.getDecoder().decode(b.getString("content"))))
                        sha = "s2"
                        Core.Response(200, """{"content":{"sha":"s2"}}""")
                    }
                }
            }
        }
        val (list, s1) = Tags.load(http, null)
        assertEquals("s1", s1)
        Tags.setMembers(list[0], Tags.members(list[0]) + "3")
        try { Tags.save(http, list, s1, "ghp_bad"); throw AssertionError() } catch (e: Core.PupError) { assertTrue(e.message!!.contains("refused")) }
        assertEquals("s2", Tags.save(http, list, s1, "ghp_good"))
        assertTrue(written[0].contains("\"members\":[\"1\",\"2\",\"3\"]"))
        try { Tags.save(http, list, s1, "ghp_good"); throw AssertionError() } catch (e: Core.PupError) { assertTrue(e.message!!.contains("changed somewhere else")) }
        assertEquals("777" to "PupFriend", Tags.userId(http, "PupFriend"))
        assertEquals("123" to null, Tags.userId(http, " 123 "))
    }
}
