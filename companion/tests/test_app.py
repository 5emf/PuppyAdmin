"""Window tests: they need Tk and a display (skipped without one)."""
import json
import os
import shutil
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

try:
    from test_core import COOKIE, FakeProtector, FakeRoblox
except ImportError:  # run as tests.test_app
    from tests.test_core import COOKIE, FakeProtector, FakeRoblox

from puppy_companion.store import AccountStore, Settings  # noqa: E402

try:
    import tkinter as tk
    from puppy_companion import app as appmod
except ImportError:
    tk = None

JOB = "1b2c3d4e-0000-4000-8000-00000000abcd"


class FakeLock:
    held = True

    def hold(self, names):
        return [(n, "mutex", "held") for n in names]

    def release(self):
        pass


class AgoTest(unittest.TestCase):
    def test_ago(self):
        if tk is None:
            self.skipTest("no tkinter")
        self.assertEqual(appmod.ago(3), "now")
        self.assertEqual(appmod.ago(42), "42 s ago")
        self.assertEqual(appmod.ago(600), "10 min ago")
        self.assertEqual(appmod.ago(7200), "2 h ago")
        self.assertEqual(appmod.ago(3 * 86400), "3 days ago")


class WindowTest(unittest.TestCase):
    def setUp(self):
        if tk is None:
            self.skipTest("no tkinter")
        try:
            self.root = tk.Tk()
        except tk.TclError as e:
            self.skipTest("no display: %s" % e)
        self.root.withdraw()
        self.tmp = tempfile.mkdtemp()
        self.store = AccountStore(FakeProtector(), os.path.join(self.tmp, "data"))
        for uid, name, role in ((1, "PupMain", "main"), (2, "PupAltA", "alt"), (3, "PupAltB", "alt")):
            self.store.add_or_update(COOKIE, {"id": uid, "name": name, "displayName": name}, role)
        self.ws = os.path.join(self.tmp, "workspace")
        os.makedirs(os.path.join(self.ws, "PuppyAdmin", "companion"))
        now = time.time()
        self.status(1, now, JOB)
        self.status(2, now, JOB)
        self.settings = Settings(os.path.join(self.tmp, "data"))
        self.settings.set("workspace", self.ws)
        self.settings.set("launch_delay", 0)
        self.uris = []
        self.roblox = FakeRoblox()
        self.app = appmod.CompanionApp(self.root, self.store, self.settings, multi=FakeLock(),
                                       opener=self.roblox, open_uri=self.uris.append)

    def tearDown(self):
        if hasattr(self, "app"):
            self.app.close()
        if hasattr(self, "tmp"):
            shutil.rmtree(self.tmp, ignore_errors=True)

    def status(self, uid, t, job, online=True):
        with open(os.path.join(self.ws, "PuppyAdmin", "companion", "%d.json" % uid), "w", encoding="utf-8") as f:
            json.dump({"userId": uid, "placeId": 1818, "jobId": job, "online": online, "time": t}, f)

    def pump(self, until, seconds=5.0):
        end = time.time() + seconds
        while time.time() < end:
            self.root.update()
            if until():
                return True
            time.sleep(0.02)
        return False

    def log_text(self):
        return self.app.log_text.get("1.0", "end")

    def test_rows_and_status(self):
        self.root.update()
        self.assertEqual(list(self.app.tree.get_children()), ["1", "2", "3"])  # main first
        self.assertEqual(self.app.tree.set("2", "status"), "In game, place 1818 (main's server)")
        self.assertEqual(self.app.tree.set("3", "status"), "Puppy Admin not seen")
        with open(os.path.join(self.ws, "PuppyAdmin", "companion", "roster.json"), encoding="utf-8") as f:
            roster = json.load(f)
        self.assertEqual(roster["main"]["userId"], 1)
        self.assertEqual([a["userId"] for a in roster["alts"]], [2, 3])

    def test_alts_to_main_skips_alts_already_there(self):
        self.app.alts_to_main()
        self.assertTrue(self.pump(lambda: len(self.uris) >= 1))
        self.pump(lambda: False, 0.3)
        self.assertEqual(len(self.uris), 1)  # PupAltA is already in that server
        uri = self.uris[0]
        self.assertIn("gameinfo:TICKET-ABC+", uri)
        self.assertIn("RequestGameJob", uri)
        self.assertIn(JOB, uri)
        self.assertIn("Already there: PupAltA", self.log_text())
        self.assertEqual(self.app.job_var.get(), JOB)

    def test_main_server_falls_back_to_presence(self):
        os.remove(os.path.join(self.ws, "PuppyAdmin", "companion", "1.json"))
        self.app.refresh_status(force=True)
        self.app.fill_main_server()
        self.assertTrue(self.pump(lambda: self.app.job_var.get() != ""))
        self.assertEqual(self.app.place_var.get(), "1818")
        self.assertEqual(self.app.job_var.get(), "1b2c3d4e-0000-4000-8000-000000000001")

    def test_launch_selected_needs_a_game(self):
        self.app.tree.selection_set(["3"])
        self.app.place_var.set("")
        self.app.launch_selected()
        self.assertIn("Enter a game first", self.log_text())
        self.app.place_var.set("https://www.roblox.com/games/1818/Crossroads")
        self.app.job_var.set("not-a-server")
        self.app.launch_selected()
        self.assertIn("does not look like one", self.log_text())
        self.app.job_var.set("")
        self.app.launch_selected()
        self.assertTrue(self.pump(lambda: len(self.uris) == 1))
        self.assertIn("RequestGame%26", self.uris[0])

    def test_launch_all_alts_skips_alts_in_that_game(self):
        self.app.place_var.set("1818")
        self.app.job_var.set("")
        self.app.launch_alts()
        self.assertTrue(self.pump(lambda: len(self.uris) >= 1))
        self.pump(lambda: False, 0.3)
        self.assertEqual(len(self.uris), 1)  # PupAltA is already in place 1818
        self.assertIn("Already there: PupAltA", self.log_text())

    def test_stale_and_offline_status(self):
        self.status(2, time.time() - 120, JOB)
        self.status(3, time.time(), JOB, online=False)
        self.app.refresh_status(force=True)
        self.assertEqual(self.app.tree.set("2", "status"), "Not running")
        self.assertEqual(self.app.tree.set("3", "status"), "Left the game")

    def test_cookie_never_in_log_or_screen(self):
        self.app.log("error text with " + COOKIE)
        self.assertNotIn("WARNING:-DO-NOT-SHARE", self.log_text())
        with open(os.path.join(self.store.folder, "companion.log"), encoding="utf-8") as f:
            self.assertNotIn("WARNING:-DO-NOT-SHARE", f.read())


if __name__ == "__main__":
    unittest.main()
