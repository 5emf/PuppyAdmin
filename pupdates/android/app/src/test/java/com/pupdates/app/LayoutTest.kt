package com.pupdates.app

import android.view.View
import android.widget.ScrollView
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** Opens the app on Android's real framework (Robolectric) at phone size and checks that every section lays out its page. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp-xxhdpi")
class LayoutTest {
    private fun <T> field(a: Any, name: String): T {
        val f = a.javaClass.getDeclaredField(name)
        f.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        return f.get(a) as T
    }

    @Test fun everySectionShowsItsPage() {
        val activity = Robolectric.buildActivity(MainActivity::class.java).setup().get()
        val root = activity.window.decorView
        val show = MainActivity::class.java.getDeclaredMethod("show", String::class.java).apply { isAccessible = true }
        for (name in listOf("compose", "bot", "status", "updates", "tags", "games", "pet", "whitelist", "settings")) {
            show.invoke(activity, name)
            root.measure(View.MeasureSpec.makeMeasureSpec(1233, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(2673, View.MeasureSpec.EXACTLY))
            root.layout(0, 0, 1233, 2673)
            val scroll: ScrollView = field(activity, "scroll")
            val page = scroll.getChildAt(0)
            assertTrue("$name: the page area is only ${scroll.height} px tall", scroll.height > 1200)
            assertTrue("$name: the page is only ${page.height} px tall", page.height > 200)
            val head = (scroll.parent as android.view.ViewGroup).getChildAt(0)
            assertTrue("$name: the header is ${head.height} px tall", head.height in 1..400)
        }
    }

    @Test fun tagEditorKeepsEverySetting() {
        val activity = Robolectric.buildActivity(MainActivity::class.java).setup().get()
        val list: MutableList<org.json.JSONObject> = mutableListOf(Tags.newTag("Owner"))
        val f = MainActivity::class.java.getDeclaredField("tagList").apply { isAccessible = true }
        f.set(activity, list)
        MainActivity::class.java.getDeclaredMethod("showTag", Int::class.java).apply { isAccessible = true }.invoke(activity, 0)
        fun edit(name: String, v: String) = field<android.widget.EditText>(activity, name).setText(v)
        edit("tOffset", "7.5"); edit("tBdColor", "#203040"); edit("tBdAlpha", "0.6"); edit("tBdImage", "rbxassetid://123")
        edit("tBdImgAlpha", "0.3"); edit("tSize", "30")
        field<android.widget.CheckBox>(activity, "tBdRound").isChecked = false
        field<android.widget.CheckBox>(activity, "tPfpRound").isChecked = false
        field<android.widget.CheckBox>(activity, "tBackdrop").isChecked = true
        val ok = MainActivity::class.java.getDeclaredMethod("storeTag").apply { isAccessible = true }.invoke(activity) as Boolean
        assertTrue(ok)
        val t: MutableList<org.json.JSONObject> = field(activity, "tagList")
        val bd = t[0].getJSONObject("backdrop")
        assertTrue(t[0].getDouble("offset") == 7.5 && t[0].getDouble("size") == 30.0)
        assertTrue(bd.getBoolean("on") && !bd.getBoolean("round") && bd.getDouble("transparency") == 0.6 && bd.getDouble("imageTransparency") == 0.3)
        assertTrue(bd.getString("image") == "rbxassetid://123" && bd.getJSONArray("color").toString() == "[32,48,64]")
        assertTrue(!t[0].getJSONObject("pfp").getBoolean("round"))
    }

    @Test fun tagPreviewDrawsEverything() {
        val activity = Robolectric.buildActivity(MainActivity::class.java).setup().get()
        val t = Tags.newTag("Owner").put("text", "Puppy Admin").put("sub", "Script Owner").put("rainbow", true).put("font", "Arcade")
        t.getJSONObject("backdrop").put("on", true)
        t.getJSONObject("pfp").put("mode", "avatar")          // no wearers: the stand-in head, nothing to download
        MainActivity::class.java.getDeclaredField("tagList").apply { isAccessible = true }.set(activity, mutableListOf(Tags.clean(t)))
        MainActivity::class.java.getDeclaredMethod("showTag", Int::class.java).apply { isAccessible = true }.invoke(activity, 0)
        MainActivity::class.java.getDeclaredMethod("renderTagPreview").apply { isAccessible = true }.invoke(activity)
        val pv: TagPreview = field(activity, "tagPreview")
        pv.measure(View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
        pv.layout(0, 0, 1080, pv.measuredHeight)
        val bmp = android.graphics.Bitmap.createBitmap(1080, maxOf(1, pv.measuredHeight), android.graphics.Bitmap.Config.ARGB_8888)
        pv.draw(android.graphics.Canvas(bmp))
        assertTrue("preview height ${pv.measuredHeight}", pv.measuredHeight >= 72)
        val note: android.widget.TextView = field(activity, "tagPreviewNote")
        assertTrue(note.text.toString(), note.text.contains("stand-in head") && note.text.contains("studs above the head"))
    }
}
