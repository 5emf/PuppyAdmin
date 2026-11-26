"""Puppy Announcer tests (no network): python -m unittest discover -s tests (from announcer/)."""
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
from puppy_announcer import core  # noqa: E402

HOOK = "https://discord.com/api/webhooks/1575303315/abc-DEF_9"


class Resp:
    def __init__(self, data, status=200):
        self.data, self.status = data, status

    def read(self):
        return self.data

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class FakeDiscord:
    def __init__(self, fail=None):
        self.sent, self.fail = [], list(fail or [])

    def __call__(self, req, timeout):
        if self.fail:
            code = self.fail.pop(0)
            raise urllib.error.HTTPError(req.full_url, code, "no", {}, io.BytesIO(json.dumps({"retry_after": 0.01}).encode()))
        self.sent.append((req.full_url, json.loads(req.data.decode())))
        return Resp(json.dumps({"id": "999"}).encode())


class FakeGitHub:
    def __call__(self, req, timeout):
        url = req.full_url
        if "/commits?" in url:
            return Resp(json.dumps([{"sha": "c3" * 20, "commit": {"message": "Mobile mode\n\nCo-Authored-By: x"}},
                                    {"sha": "c2" * 20, "commit": {"message": "SAO menu tweaks"}},
                                    {"sha": "c1" * 20, "commit": {"message": "Older change"}}]).encode())
        if url.endswith("PuppyAdmin.lua"):
            return Resp(b'local SCRIPT_BUILD = "2026.11.25-86" -- x')
        if url.endswith("_payload.py"):
            return Resp(b'PAYLOAD_VERSION = "1.7.1"\n')
        raise AssertionError(url)


class FakeProtector:
    def protect(self, b):
        return b"enc:" + b[::-1]

    def unprotect(self, b):
        assert b.startswith(b"enc:")
        return b[4:][::-1]


class CoreTest(unittest.TestCase):
    def test_webhook_check_and_redact(self):
        self.assertTrue(core.valid_webhook(HOOK))
        self.assertTrue(core.valid_webhook("https://discordapp.com/api/webhooks/1/x"))
        self.assertFalse(core.valid_webhook("https://evil.example/api/webhooks/1/x"))
        self.assertFalse(core.valid_webhook("discord.com/api/webhooks/1/x"))
        self.assertNotIn("abc-DEF_9", core.redact("failed for " + HOOK))

    def test_payload_and_pings(self):
        b = core.build_payload("Hi", "Body", "Blue")
        self.assertEqual(b["allowed_mentions"], {"parse": []})
        self.assertNotIn("content", b)
        self.assertEqual(b["embeds"][0]["color"], core.COLORS["Blue"])
        self.assertEqual(core.build_payload("a", "b", ping="@here")["content"], "@here")
        r = core.build_payload("a", "b", ping="role", role_id="42")
        self.assertEqual((r["content"], r["allowed_mentions"]), ("<@&42>", {"roles": ["42"]}))
        with self.assertRaises(ValueError):
            core.build_payload("a", "b", ping="role", role_id="moderators")
        ls = core.build_payload("a", "b", loadstring=True)
        self.assertIn("loadstring(game:HttpGet", ls["embeds"][0]["fields"][0]["value"])
        long = core.build_payload("t" * 999, "m" * 9999)
        self.assertLessEqual(len(long["embeds"][0]["title"]), 256)
        self.assertLessEqual(len(long["embeds"][0]["description"]), 4096)
        self.assertIn("HI", core.preview_text(b))

    def test_post(self):
        d = FakeDiscord()
        self.assertEqual(core.post(HOOK, core.build_payload("a", "b"), d), "999")
        self.assertTrue(d.sent[0][0].endswith("?wait=true"))
        retry = FakeDiscord(fail=[429])
        self.assertEqual(core.post(HOOK, core.build_payload("a", "b"), retry, sleep=lambda s: None), "999")
        with self.assertRaises(RuntimeError) as e:
            core.post(HOOK, core.build_payload("a", "b"), FakeDiscord(fail=[404]))
        self.assertIn("no longer exists", str(e.exception))
        with self.assertRaises(RuntimeError):
            core.post("https://example.com/x", {}, FakeDiscord())

    def test_github_templates(self):
        info = core.latest(FakeGitHub())
        self.assertEqual((info["build"], info["version"]), ("2026.11.25-86", "1.7.1"))
        title, text = core.script_template(info)
        self.assertEqual(title, "Puppy Admin updated - build 2026.11.25-86")
        self.assertIn("- Older change\n- SAO menu tweaks\n- Mobile mode", text, "oldest first")
        self.assertNotIn("Co-Authored", text)
        title, text = core.companion_template(info, last_sha="c2c2")
        self.assertEqual(title, "Puppy Companion updated - 1.7.1")
        self.assertTrue(text.startswith("- Mobile mode\n\nRestart"), "only changes after the last announced one")

    def test_settings_keep_the_webhook_encrypted(self):
        folder = tempfile.mkdtemp()
        try:
            s = core.Settings(folder, FakeProtector())
            s.set_webhook(HOOK)
            with open(os.path.join(folder, "settings.json"), encoding="utf-8") as f:
                self.assertNotIn("abc-DEF_9", f.read())
            self.assertEqual(core.Settings(folder, FakeProtector()).webhook(), HOOK)
            with self.assertRaises(ValueError):
                s.set_webhook("https://example.com/nope")
            s.set_webhook("")
            self.assertEqual(core.Settings(folder, FakeProtector()).webhook(), "")
        finally:
            shutil.rmtree(folder, ignore_errors=True)


try:
    import tkinter as tk
    from puppy_announcer.app import AnnouncerApp
except ImportError:  # pragma: no cover
    tk = None


class WindowTest(unittest.TestCase):
    def setUp(self):
        if tk is None:
            self.skipTest("no tkinter")
        try:
            self.root = tk.Tk()
        except tk.TclError as e:
            self.skipTest("no display: %s" % e)
        self.root.withdraw()
        self.folder = tempfile.mkdtemp()
        self.discord = FakeDiscord()
        self.settings = core.Settings(self.folder, FakeProtector())
        self.app = AnnouncerApp(self.root, self.settings, opener=self.discord, gh_opener=FakeGitHub())

    def tearDown(self):
        if hasattr(self, "app"):
            self.app.close()
        shutil.rmtree(self.folder, ignore_errors=True)

    def pump(self, until, seconds=3):
        end = time.time() + seconds
        while time.time() < end:
            self.root.update()
            if until():
                return True
            time.sleep(0.02)
        return False

    def test_fill_and_post(self):
        self.app.webhook_var.set(HOOK)
        self.assertTrue(self.app.save_webhook())
        self.assertEqual(self.app.webhook_var.get(), "", "the field is cleared after saving")
        self.app.fill("script")
        self.assertTrue(self.pump(lambda: self.app.title_var.get().startswith("Puppy Admin updated")))
        self.assertTrue(self.app.loadstring_var.get())
        self.assertTrue(self.app.post())
        self.assertTrue(self.pump(lambda: self.discord.sent))
        url, body = self.discord.sent[0]
        self.assertEqual(url, HOOK + "?wait=true")
        self.assertEqual(body["embeds"][0]["title"], "Puppy Admin updated - build 2026.11.25-86")
        self.assertTrue(self.pump(lambda: self.settings.get("last_script_sha") == "c3" * 20),
                        "the next fill-in starts after this announcement")

    def test_needs_a_webhook_and_text(self):
        self.assertFalse(self.app.post())
        self.assertIn("webhook", self.app.status.cget("text"))
        self.app.webhook_var.set("https://example.com/x")
        self.assertFalse(self.app.save_webhook())
        self.settings.set_webhook(HOOK)
        self.assertFalse(self.app.post())
        self.assertIn("title or a message", self.app.status.cget("text"))


if __name__ == "__main__":
    unittest.main()
