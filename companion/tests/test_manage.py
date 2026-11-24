"""Account management: per-account prefs, roster, Roblox profile/privacy/sign-out, auto-rejoin, Manage tab."""
import io
import json
import os
import shutil
import sys
import tempfile
import time
import unittest
import urllib.error

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

try:
    from test_core import COOKIE, FakeProtector, Response, headers
except ImportError:
    from tests.test_core import COOKIE, FakeProtector, Response, headers

from puppy_companion import roblox, workspace  # noqa: E402
from puppy_companion.roblox import RobloxError, RobloxSession, cookie_from_headers, parse_user_settings  # noqa: E402
from puppy_companion.store import PREF_DEFAULTS, AccountStore, Settings, clean_prefs  # noqa: E402

NEW_COOKIE = "_|WARNING:-DO-NOT-SHARE-THIS.--Sharing-this-will-allow-someone-to-log-in-as-you|_" + "CD34" * 60
PNG_1PX = (b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89"
           b"\x00\x00\x00\rIDATx\x9cc\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99=\x1d\x00\x00\x00\x00IEND\xaeB`\x82")


class FakeAccountApi:
    """Roblox as the account-management calls expect it (CSRF on writes, cookie checked)."""
    def __init__(self):
        self.requests = []
        self.token = "csrf-9"
        self.cookies = {COOKIE: 42}
        self.display = "Pup"
        self.about = "hello"
        self.settings = {"whoCanJoinMeInExperiences": {"currentValue": "Friends", "options": [
            {"optionValue": "AllUsers", "label": "Everyone"}, {"optionValue": "Friends", "label": "Friends"},
            {"optionValue": "NoOne", "label": "No one"}]}}
        self.send_new_cookie = True

    def _err(self, req, code, hdrs=None, msg="nope"):
        raise urllib.error.HTTPError(req.full_url, code, msg, hdrs or headers(),
                                     io.BytesIO(json.dumps({"errors": [{"code": 0, "message": msg}]}).encode()))

    def __call__(self, req, timeout):
        self.requests.append(req)
        url = req.full_url
        hdr = {k.lower(): v for k, v in req.header_items()}
        if "thumbnails.roblox.com" in url:
            assert "cookie" not in hdr, "the login must not go to the thumbnail service"
            return Response(200, headers(), json.dumps({"data": [{"imageUrl": "https://tr.rbxcdn.com/abc/150/150/Png"}]}).encode())
        if "rbxcdn.com" in url:
            assert "cookie" not in hdr
            return Response(200, headers(), PNG_1PX)
        cookie = (hdr.get("cookie") or "").replace(".ROBLOSECURITY=", "")
        uid = self.cookies.get(cookie)
        if uid is None:
            self._err(req, 401, msg="Authorization has been denied for this request.")
        if req.get_method() != "GET" and hdr.get("x-csrf-token") != self.token:
            self._err(req, 403, headers(x_csrf_token=self.token), "Token Validation Failed")
        body = json.loads(req.data) if req.data else None
        if url.endswith("/v1/users/authenticated"):
            return Response(200, headers(), json.dumps({"id": uid, "name": "PupAlt", "displayName": self.display}).encode())
        if url.endswith("/v1/users/%d" % uid):
            return Response(200, headers(), json.dumps({"id": uid, "name": "PupAlt", "displayName": self.display,
                                                        "description": self.about}).encode())
        if url.endswith("/display-names") and req.get_method() == "PATCH":
            self.display = body["newDisplayName"]
            return Response(200, headers(), b"{}")
        if url.endswith("/v1/description") and req.get_method() == "POST":
            self.about = body["description"]
            return Response(200, headers(), json.dumps({"description": self.about}).encode())
        if url.endswith("settings-and-options"):
            return Response(200, headers(), json.dumps(self.settings).encode())
        if url.endswith("/user-settings") and req.get_method() == "POST":
            for k, v in body.items():
                self.settings[k]["currentValue"] = v
            return Response(200, headers(), b"{}")
        if "logoutfromallsessions" in url:
            del self.cookies[cookie]
            if not self.send_new_cookie:
                return Response(200, headers(), b"{}")
            self.cookies[NEW_COOKIE] = uid
            h = headers()
            h["Set-Cookie"] = ".ROBLOSECURITY=%s; domain=.roblox.com; HttpOnly; path=/; secure" % NEW_COOKIE
            h["Set-Cookie"] = "RBXEventTrackerV2=x; path=/"
            return Response(200, h, b"{}")
        raise AssertionError("unexpected " + req.get_method() + " " + url)


class TempCase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)


class PrefsTest(TempCase):
    def test_clean_prefs(self):
        p = clean_prefs({"lite": "yes", "fps": 9999, "mute": False, "launch_order": -500, "extra_delay": 3.7,
                         "auto_rejoin": 1, "notes": "x" * 900, "evil": 1})
        self.assertIsNone(p["lite"])
        self.assertEqual(p["fps"], 240)
        self.assertIs(p["mute"], False)
        self.assertEqual(p["launch_order"], -99)
        self.assertEqual(p["extra_delay"], 3)
        self.assertFalse(p["auto_rejoin"])  # only a real True turns it on
        self.assertEqual(len(p["notes"]), 500)
        self.assertNotIn("evil", p)
        self.assertEqual(clean_prefs(None), PREF_DEFAULTS)

    def test_prefs_groups_persist_and_reach_roster(self):
        s = AccountStore(FakeProtector(), self.dir)
        s.add_or_update(COOKIE, {"id": 1, "name": "Main"}, "main")
        s.add_or_update(COOKIE, {"id": 42, "name": "PupAlt"}, "alt")
        s.add_or_update(COOKIE, {"id": 43, "name": "Plain"}, "alt")
        s.set_prefs(42, {"lite": False, "fps": 45, "mute": False, "vc_auto": True, "auto_rejoin": True})
        s.set_group(42, "  farm ")
        s.set_group(43, "farm")
        again = AccountStore(FakeProtector(), self.dir)
        a = again.get(42)
        self.assertEqual((a.prefs["fps"], a.prefs["lite"], a.group), (45, False, "farm"))
        self.assertEqual(again.groups(), ["farm"])
        ws = os.path.join(self.dir, "ws")
        os.makedirs(workspace.status_dir(ws))
        with open(workspace.write_roster(ws, again), encoding="utf-8") as f:
            roster = json.load(f)
        by_id = {x["userId"]: x for x in roster["alts"]}
        self.assertEqual(by_id[42]["prefs"], {"lite": False, "mute": False, "vcAuto": True, "fps": 45})
        self.assertNotIn("prefs", by_id[43])  # nothing set: Puppy Admin uses its own switches
        self.assertNotIn("auto_rejoin", json.dumps(roster))  # companion-only settings stay here
        self.assertNotIn("DO-NOT-SHARE", json.dumps(roster))

    def test_old_accounts_file_still_loads(self):
        os.makedirs(self.dir, exist_ok=True)
        with open(os.path.join(self.dir, "accounts.json"), "w", encoding="utf-8") as f:
            json.dump({"version": 1, "accounts": [{"user_id": 5, "name": "Old", "role": "alt", "secret": ""}]}, f)
        a = AccountStore(FakeProtector(), self.dir).get(5)
        self.assertEqual((a.group, a.prefs), ("", PREF_DEFAULTS))


class FontsTest(unittest.TestCase):
    def test_every_font_file_ships(self):
        from puppy_companion import fonts
        for label, (family, files) in fonts.FONTS.items():
            for f in files:
                path = os.path.join(fonts.FONT_DIR, f)
                self.assertTrue(os.path.isfile(path), path)
                with open(path, "rb") as fh:
                    self.assertEqual(fh.read(4), b"\x00\x01\x00\x00", f + " is TrueType")
        self.assertEqual(fonts.choices()[0], fonts.DEFAULT)

    def test_family_for_loads_privately(self):
        from puppy_companion import fonts
        calls = []
        adder = lambda path, flags, res: calls.append((os.path.basename(path), flags)) or 1
        fonts._loaded.clear()
        self.assertEqual(fonts.family_for("KH Menu", available=lambda: {"KHMenu"}, adder=adder), "KHMenu")
        self.assertEqual(sorted(c[0] for c in calls), sorted(fonts.FONTS["KH Menu"][1]))
        self.assertTrue(all(flags == fonts.FR_PRIVATE for _, flags in calls))
        self.assertEqual(fonts.family_for("KH Data", available=set(), adder=lambda *a: 0), fonts.default_family())
        self.assertEqual(fonts.family_for("nope"), fonts.default_family())
        fonts._loaded.clear()


class RobloxAccountTest(unittest.TestCase):
    def setUp(self):
        self.api = FakeAccountApi()
        self.s = RobloxSession(COOKIE, opener=self.api)

    def test_profile_display_name_about(self):
        self.assertEqual(self.s.profile(42)["description"], "hello")
        self.s.set_display_name(42, "  NewPup ")
        self.assertEqual(self.api.display, "NewPup")
        self.assertEqual(self.s.set_description("about me"), "about me")
        with self.assertRaises(RobloxError):
            self.s.set_display_name(42, "   ")

    def test_privacy_from_roblox_options(self):
        items = self.s.privacy_settings()
        self.assertEqual(items[0]["key"], "whoCanJoinMeInExperiences")
        self.assertEqual(items[0]["current"], "Friends")
        self.assertEqual([o[0] for o in items[0]["options"]], ["AllUsers", "Friends", "NoOne"])
        self.s.update_privacy({"whoCanJoinMeInExperiences": "NoOne"})
        self.assertEqual(self.api.settings["whoCanJoinMeInExperiences"]["currentValue"], "NoOne")

    def test_parse_user_settings_shapes(self):
        flat = parse_user_settings({"privateMessagePrivacy": "Friends", "junk": [1, 2]})
        self.assertEqual(flat, [{"key": "privateMessagePrivacy", "label": "Private message privacy",
                                 "current": "Friends", "options": [("Friends", "Friends")]}])
        listed = parse_user_settings({"settings": [{"key": "a", "currentValue": 1, "options": [1, 2]}]})
        self.assertEqual(listed[0]["options"], [(1, "1"), (2, "2")])
        self.assertEqual(parse_user_settings("nonsense"), [])

    def test_sign_out_everywhere_keeps_new_cookie(self):
        fresh = self.s.logout_everywhere()
        self.assertEqual(fresh, NEW_COOKIE)
        self.assertEqual(self.s.authenticated_user()["id"], 42)  # the session now uses it
        self.assertNotIn(COOKIE, self.api.cookies)

    def test_cookie_from_headers(self):
        h = headers()
        h["Set-Cookie"] = "a=b; path=/"
        self.assertIsNone(cookie_from_headers(h))
        self.assertIsNone(cookie_from_headers(None))

    def test_headshot_sends_no_login(self):
        url = roblox.headshot_url(42, opener=self.api)
        self.assertTrue(url.startswith("https://tr.rbxcdn.com/"))
        self.assertEqual(roblox.fetch_image(url, opener=self.api), PNG_1PX)

    def test_errors_never_show_the_cookie(self):
        self.api.cookies = {}
        with self.assertRaises(RobloxError) as cm:
            self.s.profile(42)
        self.assertNotIn("DO-NOT-SHARE", str(cm.exception))
        self.assertEqual(cm.exception.status, 401)


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


class ManageWindowTest(unittest.TestCase):
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
        for uid, name, role in ((1, "PupMain", "main"), (42, "PupAlt", "alt")):
            self.store.add_or_update(COOKIE, {"id": uid, "name": name, "displayName": name}, role)
        self.ws = os.path.join(self.tmp, "workspace")
        os.makedirs(os.path.join(self.ws, "PuppyAdmin", "companion"))
        self.settings = Settings(os.path.join(self.tmp, "data"))
        self.settings.set("workspace", self.ws)
        self.settings.set("launch_delay", 0)
        self.api = FakeAccountApi()
        self.api.cookies = {COOKIE: 42}
        self.uris = []
        self.app = appmod.CompanionApp(self.root, self.store, self.settings, multi=FakeLock(),
                                       opener=self.api, open_uri=self.uris.append, check_update=False)
        self.m = self.app.manage

    def tearDown(self):
        if hasattr(self, "app"):
            self.app.close()
        if hasattr(self, "tmp"):
            shutil.rmtree(self.tmp, ignore_errors=True)

    def pump(self, until, seconds=5.0):
        end = time.time() + seconds
        while time.time() < end:
            self.root.update()
            if until():
                return True
            time.sleep(0.02)
        return False

    def status(self, uid, job, online=True, t=None):
        with open(os.path.join(self.ws, "PuppyAdmin", "companion", "%d.json" % uid), "w", encoding="utf-8") as f:
            json.dump({"userId": uid, "placeId": 1818, "jobId": job, "online": online, "time": t or time.time()}, f)

    def log_text(self):
        return self.app.log_text.get("1.0", "end")

    def test_font_setting(self):
        from tkinter import font as tkfont
        self.app.set_font("KH Menu")
        self.assertEqual(self.settings.get("font"), "KH Menu")
        fam = tkfont.nametofont("TkDefaultFont", root=self.root).cget("family")
        if "KHMenu" in tkfont.families(self.root):
            self.assertEqual(fam, "KHMenu")
        else:  # not installed on this test machine: falls back and says so
            self.assertIn("could not be loaded", self.log_text())
        self.app.set_font("Default")
        self.assertIn("App font: Default", self.log_text())

    def test_save_app_settings_writes_roster(self):
        self.m.select(42)
        self.m.lite_var.set("Off")
        self.m.fps_var.set("45")
        self.m.mute_var.set("Keep game sound")
        self.m.group_var.set("farm")
        self.m.rejoin_var.set(True)
        self.m.save_app()
        a = self.store.get(42)
        self.assertEqual((a.prefs["lite"], a.prefs["fps"], a.prefs["mute"], a.prefs["auto_rejoin"], a.group),
                         (False, 45, False, True, "farm"))
        with open(os.path.join(self.ws, "PuppyAdmin", "companion", "roster.json"), encoding="utf-8") as f:
            roster = json.load(f)
        self.assertEqual(roster["alts"][0]["prefs"], {"lite": False, "mute": False, "fps": 45})
        self.assertIn("farm", self.app.group_box.cget("values"))

    def test_profile_and_privacy_round_trip(self):
        self.m.select(42)
        self.m.load_profile()
        self.assertTrue(self.pump(lambda: "Loaded" in self.m.profile_msg.cget("text")))
        self.assertIsNotNone(self.m._photo)  # the headshot was shown
        self.assertEqual(self.m.about.get("1.0", "end").strip(), "hello")
        self.m.dn_var.set("Renamed")
        self.m.save_display_name()
        self.assertTrue(self.pump(lambda: "Renamed" in self.m.profile_msg.cget("text")))
        self.assertEqual(self.store.get(42).display_name, "Renamed")
        self.m.load_privacy()
        self.assertTrue(self.pump(lambda: len(self.m.privacy_rows) == 1))
        key, var, labels, cur = self.m.privacy_rows[0]
        self.assertEqual(cur, "Friends")
        var.set("No one")
        self.assertEqual(self.m.privacy_changes(), {"whoCanJoinMeInExperiences": "NoOne"})
        self.m.save_privacy()
        self.assertTrue(self.pump(lambda: self.api.settings["whoCanJoinMeInExperiences"]["currentValue"] == "NoOne"))

    def test_sign_out_everywhere_stores_new_login(self):
        self.m.select(42)
        self.m.sign_out_everywhere(confirm=lambda: True)
        self.assertTrue(self.pump(lambda: "new login is saved" in self.m.login_msg.cget("text")))
        self.assertEqual(self.store.cookie(42), NEW_COOKIE)
        self.assertNotIn("DO-NOT-SHARE", self.log_text())

    def test_sign_out_without_new_cookie_says_so(self):
        self.api.send_new_cookie = False
        self.m.select(42)
        self.m.sign_out_everywhere(confirm=lambda: True)
        self.assertTrue(self.pump(lambda: "Update login" in self.m.login_msg.cget("text")))
        self.assertEqual(self.store.cookie(42), COOKIE)  # nothing overwritten

    def test_auto_rejoin_sends_dropped_alt_back(self):
        self.store.set_prefs(42, {"auto_rejoin": True})
        self.status(1, JOB)
        self.status(42, JOB)
        self.app.refresh_status()
        self.status(42, JOB, online=False)  # it left
        now = time.time()
        self.app.refresh_status()
        self.app.auto_rejoin_tick(now + 10)
        self.assertEqual(self.app.launches.pending(), 0)  # not yet: waits REJOIN_AFTER
        self.app.auto_rejoin_tick(now + self.app.REJOIN_AFTER + 5)
        self.assertTrue(self.pump(lambda: "Auto-rejoin" in self.log_text()))
        self.app.auto_rejoin_tick(now + self.app.REJOIN_AFTER + 10)
        self.assertEqual(self.log_text().count("Auto-rejoin"), 1)  # waits REJOIN_WAIT before another try


if __name__ == "__main__":
    unittest.main()
