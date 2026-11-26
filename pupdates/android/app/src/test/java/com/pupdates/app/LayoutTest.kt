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
        for (name in listOf("compose", "updates", "tags", "games", "pet", "whitelist", "settings")) {
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
}
