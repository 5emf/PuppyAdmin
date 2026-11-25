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

    def test_menu_item_and_clock(self):
        from puppy_companion import khmenu
        sel = khart.menu_item(BG, 1.0, "selected")
        self.assertTrue(close(sel[18][1], khart.SELECT_EDGE, 70))
        norm = khart.menu_item(BG, 1.0)
        self.assertTrue(close(norm[0][0], BG), "round top-left")
        self.assertGreater(sum(norm[1][-2]), sum(norm[1][1]) + 60, "top-right nearly square (rim shows), top-left round")
        self.assertEqual(khmenu.uptime_text(3725), "1:02")
        self.assertEqual(khmenu.uptime_text(-5), "0:00")
        line = khart.underline(100, BG, 1.0, reverse=True)
        self.assertTrue(close(line[len(line) // 2][0], BG, 3) and line[len(line) // 2][-5][0] > 200, "reversed line")

    def test_glove_sizes_and_bob(self):
        self.assertIn(khart.glove_size(1.0), kh_data.GLOVE)
        self.assertGreater(khart.glove_size(2.0), khart.glove_size(1.0))
        self.assertTrue(all(abs(khart.bob(t / 10)) <= 3 for t in range(100)))


class MenuSoundsTest(unittest.TestCase):
    def setUp(self):
        from puppy_companion import khmenu
        self.km = khmenu
        self.ws = tempfile.mkdtemp()
        os.makedirs(khmenu.sound_dir(self.ws))
        for name in ("Menu_Move.wav", "Menu_Select.wav"):
            open(os.path.join(khmenu.sound_dir(self.ws), name), "wb").close()

    def tearDown(self):
        shutil.rmtree(self.ws, ignore_errors=True)

    def test_paths_words_and_names(self):
        km = self.km
        self.assertTrue(km.sound_path(self.ws, "move").endswith(os.path.join("PuppyAdmin", "sounds", "Menu_Move.wav")))
        self.assertIsNone(km.own_sound_path(self.ws, "denied"), "no file of the player's own")
        self.assertEqual(km.sound_path(self.ws, "denied"), km.builtin_sound_path("denied"), "so the built-in one plays")
        self.assertIsNone(km.sound_path(self.ws, "denied", builtin=False))
        self.assertEqual(km.sound_path("", "move"), km.builtin_sound_path("move"))
        for kind in ("move", "select", "denied"):
            self.assertTrue(km.builtin_sound_path(kind), "built-in %s ships with the package" % kind)
        self.assertEqual(km.MenuSounds().found(self.ws), {"move": True, "denied": False, "select": True})
        # a download may add text to the name: still found
        open(os.path.join(km.sound_dir(self.ws), "860436d8-Menu_Denied.wav"), "wb").close()
        self.assertTrue(km.sound_path(self.ws, "denied").endswith("860436d8-Menu_Denied.wav"))
        other = tempfile.mkdtemp()
        try:
            open(os.path.join(other, "Menu_Denied.wav"), "wb").close()
            self.assertEqual(km.sound_path("", "denied", (other,)), os.path.join(other, "Menu_Denied.wav"), "extra folders too")
        finally:
            shutil.rmtree(other, ignore_errors=True)
        self.assertTrue(km.is_denied("Could not write the auto-execute file: x"))
        self.assertTrue(km.is_denied("Login check failed: 401"))
        self.assertFalse(km.is_denied("Theme: Midnight."))
        self.assertEqual([km.kind_for_file(n) for n in ("C:/x/Menu_Move.wav", "menu_denied.WAV", "Menu_Select.wav", "deny.wav", "song.wav")],
                         ["move", "denied", "select", "denied", None])

    def test_mp3_files(self):
        km = self.km
        d = km.sound_dir(self.ws)
        open(os.path.join(d, "c076e024-Menu_Denied.mp3"), "wb").close()
        self.assertTrue(km.own_sound_path(self.ws, "denied").endswith("c076e024-Menu_Denied.mp3"), "mp3 found, prefix and all")
        open(os.path.join(d, "Menu_Denied.mp3"), "wb").close()
        self.assertTrue(km.own_sound_path(self.ws, "denied").endswith(os.sep + "Menu_Denied.mp3"), "the exact name first")
        self.assertTrue(km.own_sound_path(self.ws, "move").endswith("Menu_Move.wav"), ".wav before .mp3 for the same name")
        cmds = km.mci_commands("pupmenu_menuselect", r'C:\x\Menu_Select.mp3')
        self.assertEqual(cmds, ["close pupmenu_menuselect", 'open "C:\\x\\Menu_Select.mp3" type mpegvideo alias pupmenu_menuselect',
                                "play pupmenu_menuselect from 0"])

    def test_throttle(self):
        played, t = [], [100.0]
        ms = self.km.MenuSounds(player=lambda p: played.append(p) or True, clock=lambda: t[0])
        self.assertTrue(ms.play(self.ws, "move"))
        self.assertFalse(ms.play(self.ws, "move"), "the same sound right away: skipped")
        t[0] += 0.2
        self.assertTrue(ms.play(self.ws, "move"))
        self.assertTrue(ms.play(self.ws, "select"))
        self.assertTrue(ms.play(self.ws, "denied"), "no own file: the built-in denied sound")
        self.assertTrue(played[-1].endswith("menu_denied.wav"))
        self.assertEqual(len(played), 4)
        refuse = self.km.MenuSounds(player=lambda p: (False, "Windows could not play it (error 2)"))
        self.assertFalse(refuse.play(self.ws, "move"))
        self.assertIn("error 2", refuse.why)
        self.assertTrue(ms.play(self.ws, "select", force=True), "the Test button skips the repeat gap")


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
        self.assertTrue(self.app.kh_title.winfo_ismapped(), "MENU capsule shown")
        menu = self.app.khmenu
        self.assertEqual(menu.pages, ["Accounts", "Launch", "Manage", "Look", "Settings"])
        self.assertTrue(menu.menu.winfo_ismapped() and menu.bottom.winfo_ismapped(), "menu list and bottom panels shown")
        self.assertNotIn("Notebook.label", self.element_names(self.style.layout("KHMenu.TNotebook.Tab")), "notebook tabs hidden")
        menu.buttons[3].invoke()
        self.assertEqual(self.app.nb.index("current"), 3, "a menu entry opens its page")
        self.assertIn("selected", menu.buttons[3].state())
        self.assertNotIn("selected", menu.buttons[0].state())
        self.assertIn("UI style", menu.desc.cget("text"))
        menu.set_hover("Launch")
        self.assertIn("Send your accounts", menu.desc.cget("text"))
        menu.set_hover(None, "Launch")
        self.assertIn("UI style", menu.desc.cget("text"), "description falls back to the open page")
        menu.select(0)
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
        sel = self.app.khmenu.selected_button()
        self.assertTrue(self.pump(lambda: abs(self.app.kh_glove.winfo_rootx() + self.app.kh_glove.winfo_width()
                                              - sel.winfo_rootx()) < 12), "the glove goes back to the menu choice")

        self.app.set_style("Standard")
        self.assertEqual(self.settings.get("ui_style"), "Standard")
        self.assertEqual(self.style.layout("TButton"), normal_button)
        self.assertEqual((self.settings.get("theme_preset"), self.settings.get("cursor")), ("Midnight", "Light"),
                         "the look from before the KH style comes back")
        self.root.update()
        self.assertTrue(self.app.title_lbl.winfo_ismapped())
        self.assertFalse(self.app.kh_title.winfo_ismapped())
        self.assertFalse(self.app.khmenu.menu.winfo_ismapped(), "standard layout: no menu list")
        self.assertTrue(self.app.version_lbl.winfo_ismapped())
        self.assertEqual(str(self.app.nb.cget("style")), "TNotebook")

    def test_menu_sounds_only_in_kh_and_toggleable(self):
        from puppy_companion import khmenu
        ws = os.path.join(self.tmp, "ws")
        os.makedirs(ws)
        self.settings.set("workspace", ws)
        src = os.path.join(self.tmp, "picked")
        os.makedirs(src)
        for name in ("Menu_Move.wav", "Menu_Select.wav", "Menu_Denied.wav", "other.wav", "5caca70e-Menu_Move.mp3"):
            with open(os.path.join(src, name), "wb") as f:
                f.write(b"RIFF")
        n = self.app.import_sounds([os.path.join(src, x) for x in ("Menu_Move.wav", "Menu_Select.wav", "Menu_Denied.wav", "other.wav")])
        self.assertEqual(n, 3)
        self.assertEqual(self.app.import_sounds([os.path.join(src, "5caca70e-Menu_Move.mp3")]), 1)
        self.assertEqual(sorted(os.listdir(khmenu.sound_dir(ws))), ["Menu_Denied.wav", "Menu_Move.mp3", "Menu_Select.wav"],
                         "an .mp3 replaces the .wav of the same sound, saved under the clean name")
        self.assertEqual(self.app.sounds.found(ws), {"move": True, "denied": True, "select": True})
        played = []
        self.app.sounds = khmenu.MenuSounds(player=lambda p: played.append(os.path.basename(p)) or True)
        played_test = []
        self.assertFalse(self.app.kh_sound("select"), "standard style: silent")
        self.assertTrue(self.app.test_sound(), "the Test button plays even in the standard style")
        self.assertIn("only play in the Kingdom Hearts style", self.app.log_text.get("1.0", "end"), "and says why menus are silent")
        self.app.set_style("Kingdom Hearts")
        self.app.sounds.last.clear()
        self.assertTrue(self.app.kh_sound("select"))
        self.app.log("Could not write the account list: disk full")
        self.assertIn("Menu_Denied.wav", played, "an error in the log plays 'denied'")
        self.app.set_menu_sounds(False)
        self.app.sounds.last.clear()
        self.assertFalse(self.app.kh_sound("move"), "menu sounds off: silent")
        self.app.set_menu_sounds(True)
        self.root.update()
        btn = next(w for w in self.all_widgets(self.root) if isinstance(w, ttk.Button) and w.winfo_ismapped())
        played.clear()
        self.app.sounds.last.clear()
        btn.event_generate("<Enter>", x=2, y=2)
        btn.event_generate("<ButtonRelease-1>", x=2, y=2)
        self.root.update()
        self.assertEqual(played, ["Menu_Move.mp3", "Menu_Select.wav"], "hover moves, click selects")

    def test_silent_reason_is_logged_once(self):
        from puppy_companion import khmenu
        self.app.sounds = khmenu.MenuSounds(player=lambda p: (False, "Windows could not play it (error 263)"))
        self.app.set_style("Kingdom Hearts")
        for _ in range(3):
            self.app.sounds.last.clear()
            self.app.kh_sound("move")
        log = self.app.log_text.get("1.0", "end")
        self.assertEqual(log.count("error 263"), 1, log)

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
