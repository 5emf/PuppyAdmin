"""Logic tests that run anywhere (Windows-only parts are faked or skipped)."""
import email.message
import io
import json
import os
import shutil
import sys
import tempfile
import threading
import time
import unittest
import urllib.error

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from puppy_companion import launch, workspace  # noqa: E402
from puppy_companion.launch_queue import LaunchJob, LaunchQueue  # noqa: E402
from puppy_companion.redact import redact  # noqa: E402
from puppy_companion.roblox import RobloxError, RobloxSession  # noqa: E402
from puppy_companion.store import AccountStore, Settings  # noqa: E402

COOKIE = "_|WARNING:-DO-NOT-SHARE-THIS.--Sharing-this-will-allow-someone-to-log-in-as-you|_" + "AB12" * 60


class FakeProtector:
    """Reversible stand-in for DPAPI (tests only)."""
    def protect(self, data):
        return bytes(b ^ 0x5A for b in data)[::-1]

    def unprotect(self, data):
        return bytes(b ^ 0x5A for b in data[::-1])


def headers(**kw):
    m = email.message.Message()
    for k, v in kw.items():
        m[k.replace("_", "-")] = v
    return m


class Response:
    def __init__(self, status, hdrs, body=b""):
        self.status, self.headers, self._body = status, hdrs, body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class FakeRoblox:
    """Answers like Roblox: CSRF challenge on POST, ticket, user, presence."""
    def __init__(self, valid=True):
        self.valid = valid
        self.requests = []
        self.token = "csrf-123"

    def __call__(self, req, timeout):
        self.requests.append(req)
        hdr = {k.lower(): v for k, v in req.header_items()}
        if not self.valid or hdr.get("cookie") != ".ROBLOSECURITY=" + COOKIE:
            raise urllib.error.HTTPError(req.full_url, 401, "Unauthorized", headers(),
                                         io.BytesIO(b'{"errors":[{"code":0,"message":"Authorization has been denied for this request."}]}'))
        if req.get_method() == "POST" and hdr.get("x-csrf-token") != self.token:
            raise urllib.error.HTTPError(req.full_url, 403, "Forbidden", headers(x_csrf_token=self.token),
                                         io.BytesIO(b'{"errors":[{"code":0,"message":"Token Validation Failed"}]}'))
        if "users/authenticated" in req.full_url:
            return Response(200, headers(), json.dumps({"id": 42, "name": "PupAlt", "displayName": "Pup"}).encode())
        if "authentication-ticket" in req.full_url:
            return Response(200, headers(rbx_authentication_ticket="TICKET-ABC"), b"")
        if "presence" in req.full_url:
            body = json.loads(req.data)
            return Response(200, headers(), json.dumps({"userPresences": [
                {"userPresenceType": 2, "placeId": 1818, "gameId": "1b2c3d4e-0000-4000-8000-000000000001", "userId": body["userIds"][0]}
            ]}).encode())
        raise AssertionError("unexpected url " + req.full_url)


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


class TempDirCase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)


class StoreTests(TempDirCase):
    def test_cookie_is_encrypted_and_round_trips(self):
        s = AccountStore(FakeProtector(), self.dir)
        s.add_or_update(COOKIE, {"id": 42, "name": "PupAlt", "displayName": "Pup"}, "alt", "Alt one")
        raw = read(os.path.join(self.dir, "accounts.json"))
        self.assertNotIn("DO-NOT-SHARE", raw)
        self.assertNotIn("AB12AB12", raw)
        s2 = AccountStore(FakeProtector(), self.dir)
        self.assertEqual(s2.cookie(42), COOKIE)
        self.assertEqual(s2.get(42).label, "Alt one")

    def test_single_main(self):
        s = AccountStore(FakeProtector(), self.dir)
        s.add_or_update(COOKIE, {"id": 1, "name": "A"}, "main")
        s.add_or_update(COOKIE, {"id": 2, "name": "B"}, "main")
        self.assertEqual([a.user_id for a in s.accounts() if a.role == "main"], [2])
        s.set_role(1, "main")
        self.assertEqual(s.main().user_id, 1)
        self.assertEqual([a.user_id for a in s.alts()], [2])
        s.remove(1)
        self.assertIsNone(s.main())

    def test_settings_persist(self):
        st = Settings(self.dir)
        self.assertEqual(st.get("launch_delay"), 8)
        st.set("workspace", "C:/x/workspace")
        self.assertEqual(Settings(self.dir).get("workspace"), "C:/x/workspace")


class RobloxTests(unittest.TestCase):
    def test_csrf_retry_then_ticket(self):
        fake = FakeRoblox()
        t = RobloxSession(COOKIE, opener=fake).auth_ticket()
        self.assertEqual(t, "TICKET-ABC")
        self.assertEqual(len(fake.requests), 2)
        second = {k.lower(): v for k, v in fake.requests[1].header_items()}
        self.assertEqual(second["x-csrf-token"], "csrf-123")
        self.assertEqual(second["referer"], "https://www.roblox.com/")
        self.assertTrue(all(r.full_url.startswith("https://") and ".roblox.com/" in r.full_url for r in fake.requests))

    def test_user_and_presence(self):
        fake = FakeRoblox()
        s = RobloxSession(COOKIE, opener=fake)
        self.assertEqual(s.authenticated_user(), {"id": 42, "name": "PupAlt", "displayName": "Pup"})
        p = s.presence([42])[0]
        self.assertEqual((p["placeId"], p["gameId"]), (1818, "1b2c3d4e-0000-4000-8000-000000000001"))

    def test_expired_cookie_message_has_no_cookie(self):
        with self.assertRaises(RobloxError) as cm:
            RobloxSession(COOKIE, opener=FakeRoblox(valid=False)).authenticated_user()
        self.assertEqual(cm.exception.status, 401)
        self.assertIn("no longer valid", str(cm.exception))
        self.assertNotIn("DO-NOT-SHARE", str(cm.exception))
        self.assertNotIn("WARNING", repr(RobloxSession(COOKIE)))


class LaunchTests(unittest.TestCase):
    def test_launch_uri_format(self):
        url = launch.place_launcher_url("123456789012", 1818, "1b2c3d4e-0000-4000-8000-000000000001")
        self.assertEqual(url, "https://assetgame.roblox.com/game/PlaceLauncher.ashx?request=RequestGameJob"
                              "&browserTrackerId=123456789012&placeId=1818"
                              "&gameId=1b2c3d4e-0000-4000-8000-000000000001&isPlayTogetherGame=false")
        uri = launch.launch_uri("TICKET", url, "123456789012", 1700000000000)
        self.assertTrue(uri.startswith("roblox-player:1+launchmode:play+gameinfo:TICKET+launchtime:1700000000000+placelauncherurl:https%3A%2F%2Fassetgame.roblox.com%2Fgame%2FPlaceLauncher.ashx%3Frequest%3DRequestGameJob%26"))
        self.assertTrue(uri.endswith("+browsertrackerid:123456789012+robloxLocale:en_us+gameLocale:en_us+channel:+LaunchExp:InApp"))
        self.assertNotIn(" ", uri)
        self.assertIn("request%3DRequestGame%26", launch.launch_uri("T", launch.place_launcher_url("1", 5), "1", 1))
        self.assertIn("RequestFollowUser", launch.place_launcher_url("1", follow_user_id=99))

    def test_parsers(self):
        self.assertEqual(launch.parse_place("1818"), 1818)
        self.assertEqual(launch.parse_place("https://www.roblox.com/games/6872265039/Bed-Wars"), 6872265039)
        self.assertEqual(launch.parse_place("https://www.roblox.com/de/games/123/x"), 123)
        self.assertIsNone(launch.parse_place("hello"))
        g = "1B2C3D4E-0000-4000-8000-000000000001"
        self.assertEqual(launch.parse_job(g), g.lower())
        self.assertEqual(launch.parse_job("roblox://experiences/start?placeId=1&gameInstanceId=" + g), g.lower())
        self.assertIsNone(launch.parse_job("abc"))
        self.assertEqual(len(launch.new_tracker_id()), 12)


class WorkspaceTests(TempDirCase):
    def test_status_and_roster(self):
        ws = os.path.join(self.dir, "Exec", "workspace")
        d = workspace.status_dir(ws)
        os.makedirs(d)
        now = time.time()
        write(os.path.join(d, "42.json"), json.dumps({"userId": 42, "name": "PupAlt", "placeId": 1818, "jobId": "j1", "online": True, "time": now - 5}))
        write(os.path.join(d, "7.json"), json.dumps({"userId": 7, "name": "Old", "placeId": 1, "jobId": "j2", "time": now - 300}))
        write(os.path.join(d, "broken.json"), "{nope")
        st = workspace.read_statuses(ws, now)
        self.assertTrue(st[42]["fresh"] and st[42]["online"])
        self.assertFalse(st[7]["fresh"])
        s = AccountStore(FakeProtector(), self.dir)
        s.add_or_update(COOKIE, {"id": 1, "name": "Main"}, "main")
        s.add_or_update(COOKIE, {"id": 42, "name": "PupAlt"}, "alt")
        path = workspace.write_roster(ws, s)
        roster = read(path)
        self.assertNotIn("DO-NOT-SHARE", roster)
        self.assertEqual(json.loads(roster)["main"]["userId"], 1)
        os.makedirs(os.path.join(self.dir, "Exec", "AutoExec"))
        self.assertTrue(workspace.autoexec_dir(ws).endswith("AutoExec"))
        p = workspace.install_autoexec(ws, "print('hi')")
        self.assertEqual(read(p), "print('hi')\n")
        self.assertEqual(workspace.find_candidates([self.dir]), [ws])


class QueueTests(TempDirCase):
    def test_runs_in_order_and_survives_errors(self):
        s = AccountStore(FakeProtector(), self.dir)
        s.add_or_update(COOKIE, {"id": 1, "name": "A"}, "alt")
        s.add_or_update("_|WARNING:-DO-NOT-SHARE-THIS.--other|_FFFF", {"id": 2, "name": "B"}, "alt")
        opened, logs, done = [], [], threading.Event()

        def log(t):
            logs.append(t)
            if len(logs) == 3:
                done.set()
        q = LaunchQueue(s, lambda: 0.05, log, opener=FakeRoblox(), open_uri=opened.append)
        q.add([LaunchJob(1, "A", 1818), LaunchJob(2, "B", 1818), LaunchJob(1, "A again", 1818, "1b2c3d4e-0000-4000-8000-000000000001")])
        self.assertTrue(done.wait(10))
        self.assertEqual(len(opened), 2)  # B's cookie is refused
        self.assertIn("Launched A", logs[0])
        self.assertIn("no longer valid", logs[1])
        self.assertIn("server 1b2c3d4e", logs[2])
        self.assertTrue(all("DO-NOT-SHARE" not in t for t in logs))


class RedactTests(unittest.TestCase):
    def test_redact(self):
        self.assertEqual(redact("x " + COOKIE + " y"), "x [login cookie hidden] y")
        self.assertEqual(redact("A" * 100), "[hidden]")


if __name__ == "__main__":
    unittest.main()
