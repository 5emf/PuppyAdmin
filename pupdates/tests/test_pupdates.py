"""Pupdates tests (no network): python -m unittest discover -s tests (from pupdates/)."""
import email.parser
import email.policy
import io
import json
import os
import shutil
import sys
import tempfile
import time
import unittest
import urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from pupdates_app import core  # noqa: E402
import run_pupdates  # noqa: E402

HOOK = "https://discord.com/api/webhooks/1575303315/abc-DEF_9"
RELAY = "https://pupdates-relay.example.workers.dev"


def parse_multipart(req):
    """[(name, filename, content type, bytes)] of a multipart request."""
    head = "Content-Type: %s\r\n\r\n" % req.headers["Content-type"]
    msg = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(head.encode() + req.data)
    return [(p.get_param("name", header="content-disposition"), p.get_filename(), p.get_content_type(),
             p.get_payload(decode=True)) for p in msg.iter_parts()]


class Resp:
    def __init__(self, data, status=200):
        self.data, self.status = data, status

    def read(self):
        return self.data

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def http_error(req, code, info):
    return urllib.error.HTTPError(req.full_url, code, "no", {}, io.BytesIO(json.dumps(info).encode()))


class FakeDiscord:
    def __init__(self, fail=None):
        self.sent, self.fail = [], list(fail or [])

    def __call__(self, req, timeout):
        if self.fail:
            raise http_error(req, self.fail.pop(0), {"retry_after": 0.01})
        if req.headers["Content-type"].startswith("multipart/"):
            parts = parse_multipart(req)
            self.sent.append((req.full_url, json.loads(parts[0][3]), parts[1:]))
        else:
            self.sent.append((req.full_url, json.loads(req.data.decode()), []))
        return Resp(json.dumps({"id": "999"}).encode())


class FakeRelay:
    """The relay's API, as in pupdates/relay/worker.js."""
    def __init__(self):
        self.users = {}   # key -> {name, canPing}
        self.posts = []

    def __call__(self, req, timeout):
        path = req.full_url[len(RELAY):]
        auth = req.headers.get("Authorization", "")
        admin = req.headers.get("X-admin-key")
        if path.startswith("/admin"):
            if admin != "admin-pass":
                raise http_error(req, 401, {"error": "Wrong admin key"})
            if req.get_method() == "GET":
                return Resp(json.dumps([{"name": u["name"], "canPing": u["canPing"]} for u in self.users.values()]).encode())
            if req.get_method() == "POST":
                body = json.loads(req.data.decode())
                key = "pup_key_for_" + body["name"].replace(" ", "_")
                self.users[key] = {"name": body["name"], "canPing": body["canPing"]}
                return Resp(json.dumps({"name": body["name"], "key": key}).encode())
            name = path.rsplit("/", 1)[1].replace("%20", " ")
            self.users = {k: u for k, u in self.users.items() if u["name"] != name}
            return Resp(b'{"ok": true}')
        user = self.users.get(auth[7:]) if auth.startswith("Bearer ") else None
        if not user:
            raise http_error(req, 401, {"error": "Not on the whitelist (wrong or removed access key)"})
        if path == "/me":
            return Resp(json.dumps(user).encode())
        parts = parse_multipart(req)
        fields = json.loads(parts[0][3])
        self.posts.append((user["name"], fields, parts[1:]))
        return Resp(json.dumps({"ok": True, "id": "7", "pingDropped": fields["ping"] != "none" and not user["canPing"]}).encode())


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


def png_file(folder, name="cat.png"):
    path = os.path.join(folder, name)
    with open(path, "wb") as f:
        f.write(run_pupdates.PNG)
    return path


class CoreTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.folder, ignore_errors=True)

    def test_webhook_check_and_redact(self):
        self.assertTrue(core.valid_webhook(HOOK))
        self.assertTrue(core.valid_webhook("https://discordapp.com/api/webhooks/1/x"))
        self.assertFalse(core.valid_webhook("https://evil.example/api/webhooks/1/x"))
        self.assertFalse(core.valid_webhook("discord.com/api/webhooks/1/x"))
        self.assertNotIn("abc-DEF_9", core.redact("failed for " + HOOK))
        self.assertEqual(core.redact("key pup_abcdefghijkl leaked"), "key pup_*** leaked")

    def test_embed_payload_and_pings(self):
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
        pic = core.build_payload("a", "b", image_name="pupdates.png")
        self.assertEqual(pic["embeds"][0]["image"], {"url": "attachment://pupdates.png"})

    def test_plain_message(self):
        b = core.build_payload("", "just text", embed=False)
        self.assertEqual(b["content"], "just text")
        self.assertNotIn("embeds", b)
        b = core.build_payload("Head", "text", embed=False, ping="@everyone", loadstring=True)
        self.assertTrue(b["content"].startswith("@everyone\n**Head**\ntext\n```lua"))
        self.assertEqual(b["allowed_mentions"], {"parse": ["everyone"]})
        self.assertEqual(core.build_payload("", "", embed=False, image_name="pupdates.png")["content"], "", "a picture alone is fine")
        with self.assertRaises(ValueError):
            core.build_payload("", "", embed=False)
        self.assertLessEqual(len(core.build_payload("", "x" * 5000, embed=False)["content"]), 2000)

    def test_pictures(self):
        img = core.load_image(png_file(self.folder))
        self.assertEqual((img["mime"], img["name"]), ("image/png", "pupdates.png"))
        self.assertEqual(core.image_kind(b"\xff\xd8\xff\xe0rest"), ("image/jpeg", "jpg"))
        self.assertEqual(core.image_kind(b"RIFF\x00\x00\x00\x00WEBPVP8 "), ("image/webp", "webp"))
        txt = os.path.join(self.folder, "x.txt")
        with open(txt, "w") as f:
            f.write("not a picture")
        with self.assertRaises(ValueError):
            core.load_image(txt)
        with self.assertRaises(ValueError):
            core.load_image(os.path.join(self.folder, "missing.png"))

    def test_post_webhook(self):
        d = FakeDiscord()
        self.assertEqual(core.post_webhook(HOOK, core.build_payload("a", "b"), opener=d), "999")
        self.assertTrue(d.sent[0][0].endswith("?wait=true"))
        retry = FakeDiscord(fail=[429])
        self.assertEqual(core.post_webhook(HOOK, core.build_payload("a", "b"), opener=retry, sleep=lambda s: None), "999")
        with self.assertRaises(RuntimeError) as e:
            core.post_webhook(HOOK, core.build_payload("a", "b"), opener=FakeDiscord(fail=[404]))
        self.assertIn("no longer exists", str(e.exception))
        self.assertNotIn("abc-DEF_9", str(e.exception))
        with self.assertRaises(RuntimeError):
            core.post_webhook("https://example.com/x", {}, opener=FakeDiscord())

    def test_post_webhook_with_picture(self):
        d = FakeDiscord()
        img = core.load_image(png_file(self.folder))
        core.post_webhook(HOOK, core.build_payload("a", "b", image_name=img["name"]), img, opener=d)
        url, body, files = d.sent[0]
        self.assertEqual(body["embeds"][0]["image"]["url"], "attachment://pupdates.png")
        self.assertEqual(files, [("files[0]", "pupdates.png", "image/png", run_pupdates.PNG)])

    def test_relay_and_whitelist(self):
        relay = FakeRelay()
        with self.assertRaises(RuntimeError) as e:
            core.admin_list(RELAY, "wrong", relay)
        self.assertIn("Wrong admin key", str(e.exception))
        added = core.admin_add(RELAY, "admin-pass", "Alt Pup", False, relay)
        self.assertTrue(added["key"].startswith("pup_"))
        self.assertEqual(core.admin_list(RELAY, "admin-pass", relay), [{"name": "Alt Pup", "canPing": False}])
        self.assertEqual(core.relay_me(RELAY, added["key"], relay)["name"], "Alt Pup")
        img = core.load_image(png_file(self.folder))
        out = core.post_relay(RELAY, added["key"], core.relay_fields("T", "M", ping="@here"), img, relay)
        self.assertTrue(out["pingDropped"])
        name, fields, files = relay.posts[0]
        self.assertEqual((name, fields["title"], fields["color"]), ("Alt Pup", "T", core.COLORS["Orange"]))
        self.assertEqual(files[0][:3], ("image", "pupdates.png", "image/png"))
        core.admin_remove(RELAY, "admin-pass", "Alt Pup", relay)
        with self.assertRaises(RuntimeError) as e:
            core.relay_me(RELAY, added["key"], relay)
        self.assertNotIn(added["key"], str(e.exception))
        with self.assertRaises(RuntimeError):
            core.post_relay("http://insecure", "k", {}, None, relay)

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

    def test_settings_keep_secrets_encrypted(self):
        s = core.Settings(self.folder, FakeProtector())
        s.set_webhook(HOOK)
        s.set_secret("relay_key", "pup_mykey12345")
        s.set_secret("admin_key", "admin-pass")
        with open(os.path.join(self.folder, "settings.json"), encoding="utf-8") as f:
            text = f.read()
        for secret in ("abc-DEF_9", "pup_mykey12345", "admin-pass"):
            self.assertNotIn(secret, text)
        again = core.Settings(self.folder, FakeProtector())
        self.assertEqual((again.webhook(), again.secret("relay_key"), again.secret("admin_key")),
                         (HOOK, "pup_mykey12345", "admin-pass"))
        with self.assertRaises(ValueError):
            s.set_webhook("https://example.com/nope")
        s.set_webhook("")
        self.assertEqual(core.Settings(self.folder, FakeProtector()).webhook(), "")
        with self.assertRaises(RuntimeError):
            core.Settings(self.folder, None).set_secret("relay_key", "x")

    def test_old_announcer_username_is_renamed(self):
        with open(os.path.join(self.folder, "settings.json"), "w", encoding="utf-8") as f:
            json.dump({"username": "Puppy Admin updates", "color": "Blue", "embed": "yes"}, f)
        s = core.Settings(self.folder, None)
        self.assertEqual((s.get("username"), s.get("color"), s.get("embed")), ("Pupdates", "Blue", True))


try:
    import tkinter as tk
    from pupdates_app.app import PupdatesApp
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
        self.relay = FakeRelay()
        self.settings = core.Settings(self.folder, FakeProtector())
        self.app = PupdatesApp(self.root, self.settings, opener=self.discord, gh_opener=FakeGitHub(), floating=False)
        self.app.confirm = lambda text: True

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

    def test_sections_and_icons(self):
        for name in ("updates", "whitelist", "settings", "compose"):
            self.app.show(name)
            self.assertEqual(self.app.section, name)
            self.assertEqual(str(self.app.icons[name].cget("image")), str(self.app.img[name + "_chosen"]))
        self.app._hover("settings", True)
        self.assertIn("webhook", self.app.strip.cget("text"))
        self.app._hover("settings", False)
        self.assertIn("picture", self.app.strip.cget("text"), "back to the open section's description")

    def test_fill_and_post(self):
        self.app.webhook_var.set(HOOK)
        self.assertTrue(self.app.save_webhook())
        self.assertEqual(self.app.webhook_var.get(), "", "the field is cleared after saving")
        self.app.show("updates")
        self.app.fill("script")
        self.assertTrue(self.pump(lambda: self.app.title_var.get().startswith("Puppy Admin updated")))
        self.assertEqual(self.app.section, "compose", "the fill-in opens Compose")
        self.assertTrue(self.app.loadstring_var.get())
        self.assertTrue(self.app.post())
        self.assertTrue(self.pump(lambda: self.discord.sent))
        url, body, files = self.discord.sent[0]
        self.assertEqual(url, HOOK + "?wait=true")
        self.assertEqual(body["embeds"][0]["title"], "Puppy Admin updated - build 2026.11.25-86")
        self.assertEqual(files, [])
        self.assertTrue(self.pump(lambda: self.settings.get("last_script_sha") == "c3" * 20),
                        "the next fill-in starts after this announcement")

    def test_plain_message_with_picture(self):
        self.settings.set_webhook(HOOK)
        self.app.embed_var.set(False)
        self.assertTrue(self.app.set_image(png_file(self.folder)))
        self.assertIn("cat.png", self.app.image_lbl.cget("text"))
        self.assertTrue(self.app.post(), "a picture alone can be posted")
        self.assertTrue(self.pump(lambda: self.discord.sent))
        url, body, files = self.discord.sent[0]
        self.assertNotIn("embeds", body)
        self.assertEqual(files[0][1:3], ("pupdates.png", "image/png"))
        self.assertFalse(self.settings.get("embed"), "the choice is remembered")
        self.app.clear_image()
        self.assertIsNone(self.app.image)

    def test_needs_a_webhook_and_text(self):
        self.assertFalse(self.app.post())
        self.assertIn("webhook", self.app.status.cget("text"))
        self.app.webhook_var.set("https://example.com/x")
        self.assertFalse(self.app.save_webhook())
        self.settings.set_webhook(HOOK)
        self.assertFalse(self.app.post())
        self.assertIn("title or a message", self.app.status.cget("text"))
        txt = os.path.join(self.folder, "x.txt")
        with open(txt, "w") as f:
            f.write("text")
        self.assertFalse(self.app.set_image(txt))
        self.assertIn("PNG, JPG", self.app.status.cget("text"))

    def test_whitelist_and_relay_posting(self):
        self.app.opener = self.relay
        self.app.show("whitelist")
        self.app.wl_relay_var.set(RELAY)
        self.app.admin_var.set("admin-pass")
        self.assertTrue(self.app.save_admin())
        self.assertEqual(self.settings.secret("admin_key"), "admin-pass")
        self.app.new_name_var.set("Alt Pup")
        self.assertTrue(self.app.add_user())
        self.assertTrue(self.pump(lambda: self.app.new_key_var.get().startswith("pup_")))
        self.assertTrue(self.pump(lambda: self.app.users_list.size() == 1))
        key = self.app.new_key_var.get()

        # the whitelisted person, in relay mode
        self.app.show("settings")
        self.app.mode_var.set("relay")
        self.app.set_mode()
        self.assertEqual(self.app.relay_var.get(), RELAY, "the relay address is shared with Whitelist")
        self.app.key_var.set(key)
        self.assertTrue(self.app.check_relay())
        self.assertTrue(self.pump(lambda: "Alt Pup" in self.app.relay_lbl.cget("text")))
        self.app.message.insert("1.0", "hello from the alt")
        self.app.ping_var.set("@everyone")
        self.assertTrue(self.app.post())
        self.assertTrue(self.pump(lambda: self.relay.posts))
        self.assertEqual(self.relay.posts[0][1]["message"], "hello from the alt")
        self.assertTrue(self.pump(lambda: "ping was left out" in self.app.status.cget("text")))

        self.app.show("whitelist")
        self.app.users_list.selection_set(0)
        self.assertTrue(self.app.remove_user())
        self.assertTrue(self.pump(lambda: self.app.users_list.size() == 0))


class SelfTest(unittest.TestCase):
    def test_selftest_runs(self):
        if sys.platform != "win32":
            self.skipTest("the self-test checks Windows encryption")
        folder = tempfile.mkdtemp()
        try:
            self.assertEqual(run_pupdates.selftest(os.path.join(folder, "r.txt")), 0)
        finally:
            shutil.rmtree(folder, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
