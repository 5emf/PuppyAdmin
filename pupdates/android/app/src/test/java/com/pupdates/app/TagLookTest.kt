package com.pupdates.app

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.ceil

/** The same checks as the desktop's TagPreviewTest: both apps follow Tags.build. */
class TagLookTest {
    private fun tag(on: Boolean, sub: String = "Script Owner"): JSONObject {
        val t = Tags.newTag("T").put("text", "Puppy Admin").put("sub", sub).put("size", 22)
        t.getJSONObject("backdrop").put("on", on).put("round", true)
        return Tags.clean(t)
    }
    private val measure = { text: String, _: String, px: Float -> text.length * px * 0.5f }

    @Test fun layoutMatchesTagsBuild() {
        val lay = TagLook.layout(tag(true), true, measure)
        assertEquals(ceil(24f + 49 + 8 + 131), lay.cardW)
        assertEquals(61f, lay.cardH)
        assertEquals(49f, lay.pic)
        assertEquals(12f, lay.picBox.x)
        assertEquals(6f, lay.picBox.y)
        assertEquals(14f, lay.corner)
        assertEquals(57f, lay.far)
        assertTrue(lay.alignLeft)
        val bare = TagLook.layout(tag(false, sub = ""), false, measure)
        assertEquals(139f, bare.cardW)
        assertEquals(38f, bare.cardH)
        assertEquals(0f, bare.corner)
        assertNull(bare.far)
    }

    @Test fun sourcesFollowPuppyAdminsRules() {
        assertNull(TagLook.resolve(" "))
        assertEquals(TagLook.Source("asset", "12345"), TagLook.resolve("12345"))
        assertEquals(TagLook.Source("asset", "777"), TagLook.resolve("rbxassetid://777"))
        assertEquals(TagLook.Source("asset", "4242"), TagLook.resolve("https://www.roblox.com/library/4242/Cool"))
        assertEquals(TagLook.Source("headshot", "99"), TagLook.resolve("rbxthumb://type=AvatarHeadShot&id=99&w=150&h=150"))
        assertEquals(TagLook.Source("url", "https://raw.githubusercontent.com/u/r/main/a.png"), TagLook.resolve("https://github.com/u/r/blob/main/a.png"))
        assertEquals("unsupported", TagLook.resolve("rbxasset://textures/face.png")!!.kind)
        assertEquals("bad", TagLook.resolve("what")!!.kind)
    }

    @Test fun coloursAndRainbow() {
        val t = tag(true).put("color", org.json.JSONArray(listOf(100, 0, 200)))
        val (m, s) = TagLook.textColours(t, 0.0)
        assertEquals(listOf(100, 0, 200), m.toList())
        assertEquals(listOf(162, 102, 222), s.toList())
        t.put("rainbow", true)
        assertEquals(listOf(255, 25, 25), TagLook.textColours(t, 0.0).first.toList())
        assertNotEquals(TagLook.textColours(t, 0.0).first.toList(), TagLook.textColours(t, 2.0).first.toList())
    }

    @Test fun planAndFonts() {
        val t = tag(true)
        t.getJSONObject("pfp").put("mode", "avatar")
        val p = TagLook.plan(t, "1", "pupone")
        assertEquals(TagLook.Source("headshot", "1"), p.picture)
        assertTrue(p.notes.any { it.contains("pupone") } && p.notes.any { it.contains("stand-in") })
        t.getJSONObject("pfp").put("mode", "custom").put("image", "")
        t.getJSONObject("backdrop").put("on", false).put("image", "123")
        t.put("font", "Arcade")
        val q = TagLook.plan(t, null, null)
        assertNull(q.picture)
        assertNull(q.backdrop)
        assertTrue(q.notes.any { it.contains("no image is set") } && q.notes.any { it.contains("backdrop is off") } && q.notes.none { it.contains("stand-in") })
        assertEquals("Montserrat-Bold.ttf", TagLook.fontFile("NoSuchFont"))
        val dir = fontsDir() ?: return   // (CI runs from pupdates/android/app and finds pupdates/tagfonts)
        val map = JSONObject(java.io.File(dir, "fonts.json").readText())
        for (f in Tags.FONTS) {
            assertTrue(f, java.io.File(dir, TagLook.fontFile(f)).isFile)
            assertEquals("fonts.json and TagLook agree on $f", map.getJSONObject(f).getString("file"), TagLook.fontFile(f))
            assertEquals(map.getJSONObject(f).getBoolean("standin"), TagLook.STAND_INS.containsKey(f))
        }
    }

    private fun fontsDir(): java.io.File? {
        var d: java.io.File? = java.io.File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (d != null) {
            for (c in listOf("tagfonts", "pupdates/tagfonts")) {
                val f = java.io.File(d, c)
                if (java.io.File(f, "fonts.json").isFile) return f
            }
            d = d.parentFile
        }
        return null
    }
}
