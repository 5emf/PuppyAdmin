"""The Kingdom Hearts UI style (Puppy Admin's KH menu look) in the companion."""
import os
import shutil
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from puppy_companion import kh_data, khart  # noqa: E402
from puppy_companion.store import AccountStore, Settings  # noqa: E402

try:
    from test_core import COOKIE, FakeProtector
    from test_manage import FakeLock
except ImportError:
    from tests.test_core import COOKIE, FakeProtector
    from tests.test_manage import FakeLock

try:
    import tkinter as tk
    from tkinter import ttk
    from puppy_companion import app as appmod
except ImportError:  # pragma: no cover
    tk = None

BG = (6, 10, 40)


def close(a, b, tol=2):
    return all(abs(a[i] - b[i]) <= tol for i in range(3))


class ShapesTest(unittest.TestCase):
    def test_shape_size_corners_and_edge(self):
        rows = khart.shape(40, 20, 8, (200, 200, 200), (100, 100, 100), (255, 0, 0), 2, BG)
        self.assertEqual((len(rows), len(rows[0])), (20, 40))
        self.assertTrue(close(rows[0][0], BG), "rounded corner shows the background")
        self.assertTrue(close(rows[10][0], (255, 0, 0), 40), "left edge is the outline colour")
        self.assertTrue(close(rows[10][20], (150, 150, 150), 8), "middle is the shaded fill")
        self.assertGreater(sum(rows[3][20]), sum(rows[16][20]), "lighter at the top, deeper below")

    def test_tab_has_square_bottom(self):
        rows = khart.tab((30, 40, 90), (60, 70, 120), BG, 1.0)
        self.assertTrue(close(rows[0][0], BG), "top corner rounded")
        self.assertFalse(close(rows[-1][0], BG), "bottom corner square")

    def test_hover_and_selected_are_puppy_admins_red(self):
        hover = khart.button((40, 50, 90), (60, 70, 120), BG, 1.0, "hover")
        mid = hover[len(hover) // 2]
        self.assertTrue(close(mid[0], khart.SELECT_EDGE, 60), "bright red outline")
        self.assertGreater(mid[len(mid) // 2][0], mid[len(mid) // 2][2] * 2, "deep red fill")
        sel = khart.tab((30, 40, 90), (60, 70, 120), BG, 1.0, "selected")
        self.assertTrue(close(sel[3][len(sel[0]) // 2], khart.SELECT, 30))

    def test_button_shade_matches_the_game(self):
        base = (100, 120, 200)
        rows = khart.button(base, base, BG, 1.0)
        bottom = rows[-3][len(rows[0]) // 2]
        want = khart.multiply(base, khart.BUTTON_SHADE)
        self.assertTrue(close(bottom, want, 12), (bottom, want))

    def test_capsule_underline_and_data(self):
        cap = khart.capsule(120, (60, 130, 255), BG, 1.0)
        self.assertEqual(len(cap), 34)
        self.assertTrue(close(cap[1][1], BG, 30), "capsule ends are round")
        line = khart.underline(100, BG, 1.0)
        self.assertGreater(line[len(line) // 2][5][0], 200, "orange at the start")
        self.assertTrue(close(line[len(line) // 2][-1], BG, 3), "fades out to the right")
        data = khart.rows_data([[(255, 0, 0), (0, 0, 255)]])
        self.assertEqual(data, "{#ff0000 #0000ff}")

    def test_glove_sizes_and_bob(self):
        self.assertIn(khart.glove_size(1.0), kh_data.GLOVE)
        self.assertGreater(khart.glove_size(2.0), khart.glove_size(1.0))
        self.assertTrue(all(abs(khart.bob(t / 10)) <= 3 for t in range(100)))


class KHWindowTest(unittest.TestCase):
    def setUp(self):
        if tk is None:
            self.skipTest("no tkinter")
        try:
            self.root = tk.Tk()
        except tk.TclError as e:
            self.skipTest("no display: %s" % e)
        self.tmp = tempfile.mkdtemp()
        self.store = AccountStore(FakeProtector(), os.path.join(self.tmp, "data"))
        self.store.add_or_update(COOKIE, {"id": 1, "name": "PupMain", "displayName": "PupMain"}, "main")
        self.settings = Settings(os.path.join(self.tmp, "data"))
        self.app = appmod.CompanionApp(self.root, self.store, self.settings, multi=FakeLock(),
                                       opener=lambda *a, **k: None, open_uri=lambda u: None, check_update=False)
        self.style = ttk.Style(self.root)

    def tearDown(self):
        if hasattr(self, "app"):
            self.app.close()
        if hasattr(self, "tmp"):
            shutil.rmtree(self.tmp, ignore_errors=True)

    def pump(self, until, seconds=3.0):
        end = time.time() + seconds
        while time.time() < end:
            self.root.update()
            if until():
                return True
            time.sleep(0.02)
        return False

    def element_names(self, layout):
        out = []
        for name, opts in layout:
            out.append(name)
            out.extend(self.element_names(opts.get("children", [])))
        return out

    def test_kingdom_hearts_on_and_off(self):
        normal_button = self.style.layout("TButton")
        self.app.set_preset("Midnight")
        self.app.set_cursor("Light")
        self.app.set_style("Kingdom Hearts")
        self.assertEqual(self.settings.get("ui_style"), "Kingdom Hearts")
        self.assertEqual(self.settings.get("kh_prev")["theme_preset"], "Midnight")
        self.assertIn("KHButton.bg", self.element_names(self.style.layout("TButton")))
        self.assertIn("KHAccent.bg", self.element_names(self.style.layout("Accent.TButton")))
        self.assertIn("KHTab.bg", self.element_names(self.style.layout("TNotebook.Tab")))
        self.assertIn("KHPanel.border", self.element_names(self.style.layout("TLabelframe")))
        self.assertEqual(self.style.lookup("TFrame", "background"), "#060a28")
        self.root.update()
        self.assertTrue(self.app.kh_title.winfo_ismapped(), "title capsule shown")
        self.assertFalse(self.app.title_lbl.winfo_ismapped(), "plain title hidden")

        # a theme change while in the style redraws the same images (no new ttk elements)
        before = dict(self.app._kh["imgs"])
        self.app.set_role_colour("accent", "#ff8800")
        self.assertEqual(before, self.app._kh["imgs"])

        # the glove points at the hovered button
        self.root.deiconify()
        self.root.geometry("900x700+0+0")
        self.app.nb.select(0)
        self.pump(lambda: self.root.winfo_ismapped())
        btn = next(w for w in self.all_widgets(self.root) if isinstance(w, ttk.Button) and w.winfo_ismapped())
        btn.event_generate("<Enter>", x=2, y=2)
        self.assertTrue(self.pump(lambda: self.app.kh_glove_shown()), "glove shown on hover")
        self.pump(lambda: False, 0.2)
        g = self.app.kh_glove
        gx = self.app.kh_glove.winfo_rootx() + self.app.kh_glove.winfo_width()
        self.assertLess(abs(gx - btn.winfo_rootx()), 12, "glove sits just left of the button")
        btn.event_generate("<Leave>")
        self.assertTrue(self.pump(lambda: not self.app.kh_glove_shown()), "glove hides on leave")

        self.app.set_style("Standard")
        self.assertEqual(self.settings.get("ui_style"), "Standard")
        self.assertEqual(self.style.layout("TButton"), normal_button)
        self.assertEqual((self.settings.get("theme_preset"), self.settings.get("cursor")), ("Midnight", "Light"),
                         "the look from before the KH style comes back")
        self.root.update()
        self.assertTrue(self.app.title_lbl.winfo_ismapped())
        self.assertFalse(self.app.kh_title.winfo_ismapped())

    def test_style_survives_a_restart(self):
        self.app.set_style("Kingdom Hearts")
        self.app.close()
        root2 = tk.Tk()
        try:
            app2 = appmod.CompanionApp(root2, self.store, Settings(os.path.join(self.tmp, "data")), multi=FakeLock(),
                                       opener=lambda *a, **k: None, open_uri=lambda u: None, check_update=False)
            self.assertIn("KHButton.bg", self.element_names(ttk.Style(root2).layout("TButton")))
            app2.close()
        finally:
            try:
                root2.destroy()
            except tk.TclError:
                pass
        del self.app

    def all_widgets(self, w):
        yield w
        for c in w.winfo_children():
            yield from self.all_widgets(c)


if __name__ == "__main__":
    unittest.main()
