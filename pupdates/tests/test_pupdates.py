"""Pupdates tests (no network): python -m unittest discover -s tests (from pupdates/)."""
import base64
import email.parser
import hashlib
import email.policy
import io
import json
import math
import re
import threading
import os
import shutil
import sys
import tempfile
import time
import unittest
import urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from pupdates_app import bot, core, tagpreview, tags, update  # noqa: E402
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

    def read(self, n=-1):
        return self.data if n < 0 else self.data[:n]

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
            if path == "/admin/commands":
                return Resp(json.dumps({"ok": True, "count": 18, "application": "1", "publicKeySet": True,
                                        "interactionsUrl": RELAY + "/interactions"}).encode())
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


class FakeTagRepo:
    """GitHub's contents API for tags.json + Roblox's user lookups."""
    def __init__(self, tag_list):
        self.text = json.dumps(tag_list)
        self.sha = "s1"
        self.writes = []

    def __call__(self, req, timeout):
        url = req.full_url
        if url.startswith(tags.ROBLOX_BY_NAME):
            name = json.loads(req.data.decode())["usernames"][0]
            data = [{"id": 777, "name": "PupFriend", "requestedUsername": name}] if name.lower() == "pupfriend" else []
            return Resp(json.dumps({"data": data}).encode())
        if url.startswith(tags.ROBLOX_BY_ID):
            return Resp(json.dumps({"data": [{"id": i, "name": "user%d" % i} for i in json.loads(req.data.decode())["userIds"]]}).encode())
        assert url.startswith(tags.API), url
        if req.get_method() == "GET":
            return Resp(json.dumps({"sha": self.sha, "content": base64.b64encode(self.text.encode()).decode()}).encode())
        if req.headers.get("Authorization") != "Bearer ghp_good":
            raise http_error(req, 401, {"message": "Bad credentials"})
        body = json.loads(req.data.decode())
        if body.get("sha") != self.sha:
            raise http_error(req, 409, {"message": "conflict"})
        self.text = base64.b64decode(body["content"]).decode()
        self.sha = "s%d" % (int(self.sha[1:]) + 1)
        self.writes.append(json.loads(self.text))
        return Resp(json.dumps({"content": {"sha": self.sha}}).encode())


TAGS = [{"name": "Owner Tag", "text": "Puppy Admin", "sub": "Script Owner", "color": [255, 255, 255], "rainbow": True,
         "size": 22, "offset": 3, "font": "Code", "members": ["1", "2"],
         "backdrop": {"on": True, "color": [18, 18, 22], "transparency": 0.35, "image": "", "imageTransparency": 0.15, "round": True},
         "pfp": {"mode": "avatar", "image": "", "round": True}},
        {"name": "Default", "isDefault": True, "text": "Pup", "members": []}]


# a made-up token, put together at run time so no token-shaped text sits in the repository
BOT_TOKEN = ".".join(["MTIzNDU2Nzg5MDEyMzQ1Njc4", "Ga" + "BcDe", "abcdefghijklmnop" + "qrstuvwxyz012345"])


class FakeBotDiscord:
    """Discord's API v10 for a bot, as Pupdates uses it."""
    def __init__(self):
        self.calls = []
        self.messages = {}
        self.next_id = 900
        self.profile = {"id": "123456789012345678", "username": "PupBot", "avatar": None, "bot": True}

    def __call__(self, req, timeout):
        url, method = req.full_url, req.get_method()
        path = url[len(bot.API):]
        if req.headers.get("Authorization") != "Bot " + BOT_TOKEN:
            raise http_error(req, 401, {"message": "401: Unauthorized", "code": 0})
        body = None
        files = []
        if req.data:
            if req.headers["Content-type"].startswith("multipart/"):
                parts = parse_multipart(req)
                body, files = json.loads(parts[0][3]), parts[1:]
            else:
                body = json.loads(req.data.decode())
        self.calls.append((method, path, body, files))
        if path == "/users/@me" and method == "GET":
            return Resp(json.dumps(self.profile).encode())
        if path == "/users/@me" and method == "PATCH":
            self.profile.update({k: v for k, v in body.items() if k == "username"})
            if "avatar" in body:
                self.profile["avatar"] = "hash1" if body["avatar"] else None
            return Resp(json.dumps(self.profile).encode())
        if path == "/users/@me/guilds":
            return Resp(json.dumps([{"id": "2", "name": "Zeta"}, {"id": "1", "name": "Puppy Server"}]).encode())
        m = re.match(r"^/guilds/(\d+)/channels$", path)
        if m:
            return Resp(json.dumps([
                {"id": "10", "type": 4, "name": "INFO", "position": 0},
                {"id": "11", "type": 5, "name": "announcements", "position": 0, "parent_id": "10"},
                {"id": "12", "type": 0, "name": "general", "position": 1, "parent_id": "10"},
                {"id": "13", "type": 2, "name": "Voice", "position": 2},
                {"id": "14", "type": 0, "name": "lobby", "position": 0}]).encode())
        m = re.match(r"^/channels/(\d+)/messages(?:/(\d+))?(/crosspost)?$", path)
        if m:
            ch, mid, cross = m.groups()
            if ch == "99":
                raise http_error(req, 403, {"message": "Missing Permissions", "code": 50013})
            if cross:
                return Resp(json.dumps(self.messages[mid]).encode())
            if method == "POST":
                self.next_id += 1
                mid = str(self.next_id)
                atts = [{"id": "a" + mid, "filename": f[1]} for f in files]
                self.messages[mid] = dict(body, id=mid, channel_id=ch, attachments=atts)
                return Resp(json.dumps(self.messages[mid]).encode())
            if mid not in self.messages:
                raise http_error(req, 404, {"message": "Unknown Message", "code": 10008})
            if method == "GET":
                return Resp(json.dumps(self.messages[mid]).encode())
            if method == "PATCH":
                self.messages[mid].update(body)
                return Resp(json.dumps(self.messages[mid]).encode())
            if method == "DELETE":
                del self.messages[mid]
                return Resp(b"")
        raise AssertionError((method, url))


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


def solid_png(rgb, w=40, h=30):
    from PIL import Image
    buf = io.BytesIO()
    Image.new("RGB", (w, h), rgb).save(buf, "PNG")
    return buf.getvalue()


class FakeRoblox:
    """Roblox's thumbnail service + an image host, as the preview's loader sees them."""
    def __init__(self, thumb_states=None, asset_type=1):
        self.thumb_states = list(thumb_states or ["Completed"])
        self.asset_type = asset_type
        self.asked = []

    def __call__(self, req, timeout):
        url = req.full_url
        self.asked.append(url)
        if url.startswith("https://thumbnails.roblox.com/"):
            state = self.thumb_states.pop(0) if len(self.thumb_states) > 1 else self.thumb_states[0]
            ident = re.search(r"(?:assetIds|userIds)=(\d+)", url).group(1)
            return Resp(json.dumps({"data": [{"targetId": int(ident), "state": state,
                                              "imageUrl": "https://tr.rbxcdn.com/pic/%s.png" % ident if state == "Completed" else ""}]}).encode())
        if url.startswith("https://economy.roblox.com/"):
            return Resp(json.dumps({"AssetTypeId": self.asset_type}).encode())
        if url.startswith("https://tr.rbxcdn.com/"):
            return Resp(solid_png((40, 200, 90)))
        if url.endswith("/page.html"):
            return Resp(b"<!doctype html><html><body>hi</body></html>")
        if url.endswith(".png"):
            return Resp(solid_png((230, 30, 30)))
        raise urllib.error.URLError("no route to " + url)


@unittest.skipUnless(tagpreview.available(), "needs Pillow")
class TagPreviewTest(unittest.TestCase):
    def tag(self, **kw):
        d = tags.clean_tag({"name": "T", "text": "Puppy Admin", "sub": "Script Owner", "members": ["1"]})
        for k, v in kw.items():
            if k in ("backdrop", "pfp"):
                d[k].update(v)
            else:
                d[k] = v
        return tags.clean_tag(d)

    def test_sources_follow_puppy_admins_rules(self):
        r = tagpreview.resolve
        self.assertIsNone(r("  "))
        self.assertEqual(r("12345"), ("asset", "12345"))
        self.assertEqual(r("rbxassetid://777"), ("asset", "777"))
        self.assertEqual(r("https://www.roblox.com/library/4242/Cool-Decal"), ("asset", "4242"))
        self.assertEqual(r("rbxthumb://type=AvatarHeadShot&id=99&w=150&h=150"), ("headshot", "99"))
        self.assertEqual(r("rbxthumb://type=Asset&id=55&w=420&h=420"), ("asset", "55"))
        self.assertEqual(r("https://github.com/u/r/blob/main/a/b.png"), ("url", "https://raw.githubusercontent.com/u/r/main/a/b.png"))
        self.assertEqual(r("https://example.com/x.jpg"), ("url", "https://example.com/x.jpg"))
        self.assertEqual(r("rbxasset://textures/face.png")[0], "unsupported")
        self.assertEqual(r("what")[0], "bad")

    def test_layout_matches_tags_build(self):
        measure = lambda text, font, px: len(text) * px * 0.5
        d = self.tag(size=22, backdrop={"on": True, "round": True})
        lay = tagpreview.layout(d, measure, True)
        # Tags.build: lineMain ceil(22*1.35)=30, sub 14 -> ceil(18.9)=19, textH 49; textW = ceil(11*11)+10 = 131
        # pic = floor(max(49, 33)) = 49, gap 8, padX 12 / padY 6 (backdrop on)
        self.assertEqual(lay["card"], (math.ceil(24 + 49 + 8 + 131), math.ceil(12 + 49)))
        self.assertEqual(lay["pic_box"], (12, 6, 49, 49))
        self.assertEqual(lay["align"], "left")
        self.assertEqual(lay["corner"], 14)
        self.assertAlmostEqual(lay["main_box"][3], 49 * 30 / 49)
        self.assertEqual(lay["far"], (57, 57))
        bare = tagpreview.layout(self.tag(sub="", backdrop={"on": False}), measure, False)
        self.assertEqual(bare["card"], (math.ceil(8 + 131), 8 + 30))
        self.assertEqual((bare["align"], bare["corner"], bare["far"]), ("center", 0, None))

    def test_colours_and_rainbow(self):
        main, sub = tagpreview.text_colours(self.tag(color=[100, 0, 200]), 0)
        self.assertEqual((main, sub), ((100, 0, 200), (162, 102, 222)))
        r0, _ = tagpreview.text_colours(self.tag(rainbow=True), 0)
        r1, _ = tagpreview.text_colours(self.tag(rainbow=True), 2.0)
        self.assertEqual(r0, (255, 25, 25))   # HSV(0, 0.9, 1)
        self.assertNotEqual(r0, r1, "the rainbow moves round in 4 seconds")
        self.assertEqual(tagpreview.text_colours(self.tag(rainbow=True), 4.0)[0], r0)

    def test_every_tag_font_has_a_file(self):
        for name in tags.FONTS:
            path, info = tagpreview.font_entry(name)
            self.assertTrue(path and os.path.isfile(path), name)
        self.assertTrue(tagpreview.font_entry("GothamBold")[1]["standin"])
        self.assertFalse(tagpreview.font_entry("Arcade")[1]["standin"])
        self.assertEqual(tagpreview.font_entry("NoSuchFont")[1]["file"], tagpreview.font_entry("GothamBold")[1]["file"])

    def load(self, images, source):
        done = threading.Event()
        pic = images.get(source, done.set)
        self.assertTrue(done.wait(5), "loader finished")
        return pic

    def test_loading_pictures(self):
        fake = FakeRoblox(thumb_states=["Pending", "Completed"], asset_type=13)
        images = tagpreview.Images(lambda fn: fn(), fake, sleep=lambda s: None)
        url = self.load(images, ("url", "https://example.com/p.png"))
        self.assertEqual((url.state, url.image.getpixel((5, 5))[:3]), ("ok", (230, 30, 30)))
        page = self.load(images, ("url", "https://example.com/page.html"))
        self.assertEqual(page.state, "failed")
        self.assertIn("web page", page.error)
        asset = self.load(images, ("asset", "4242"))
        self.assertEqual((asset.state, asset.image.getpixel((1, 1))[:3]), ("ok", (40, 200, 90)))
        self.assertIn("Decal", asset.note)
        head = self.load(images, ("headshot", "99"))
        self.assertEqual(head.state, "ok")
        self.assertTrue(any("avatar-headshot?userIds=99" in u for u in fake.asked))
        blocked = self.load(tagpreview.Images(lambda fn: fn(), FakeRoblox(["Blocked"])), ("asset", "1"))
        self.assertIn("blocked", blocked.error)
        down = self.load(tagpreview.Images(lambda fn: fn(), FakeRoblox()), ("url", "https://nowhere.example/x"))
        self.assertIn("could not connect", down.error)
        self.assertEqual(images.get(("bad", "nope"), None).state, "failed")

    def test_drawing(self):
        from PIL import Image
        red = Image.new("RGBA", (50, 50), (230, 30, 30, 255))
        d = self.tag(backdrop={"on": True, "color": [32, 48, 64], "transparency": 0.6, "round": True}, pfp={"mode": "custom", "round": True})
        lay = tagpreview.layout(d, tagpreview.measure_with_pillow, True)
        card = tagpreview.draw_tag(d, lay, red, None, 0, 1.0)
        self.assertEqual(card.size, lay["card"])
        cw, ch = lay["card"]
        self.assertEqual(card.getpixel((cw // 2, 2)), (32, 48, 64, 102), "backdrop colour at 40 % (transparency 0.6)")
        self.assertEqual(card.getpixel((0, 0))[3], 0, "rounded corner")
        x, y, w, h = lay["pic_box"]
        self.assertEqual(card.getpixel((x + w // 2, y + h // 2))[:3], (230, 30, 30), "the loaded picture")
        self.assertNotEqual(card.getpixel((x + 1, y + 1))[:3], (230, 30, 30), "the picture is round")
        square = tagpreview.draw_tag(self.tag(backdrop={"on": False}, pfp={"mode": "custom", "round": False}),
                                     tagpreview.layout(self.tag(backdrop={"on": False}), tagpreview.measure_with_pillow, True), red, None, 0, 1.0)
        self.assertEqual(square.getpixel((4 + 8, 4 + 8))[:3], (230, 30, 30), "6 px corners only")
        back = Image.new("RGBA", (300, 80), (0, 0, 255, 255))
        withimg = tagpreview.draw_tag(d, lay, red, back, 0, 1.0)
        bx = withimg.getpixel((cw // 2, 2))
        self.assertGreater(bx[2], 150, "the backdrop image shows through at 85 %")
        far = tagpreview.draw_far(d, lay, red, 1.0)
        self.assertEqual(far.size, (lay["pic"] + 8, lay["pic"] + 8))
        img, shown = tagpreview.scene(d, red, back, True, 0, 520)
        self.assertEqual((img.width, shown), (520, 1.0))
        long = self.tag(text="W" * 40, size=48)
        img2, shown2 = tagpreview.scene(long, None, None, True, 0, 400)
        self.assertLess(shown2, 1.0, "a tag wider than the preview is shown smaller")

    def test_plan_and_notes(self):
        need, notes = tagpreview.plan(self.tag(pfp={"mode": "avatar"}), "1", "pupone")
        self.assertEqual(need["picture"], ("headshot", "1"))
        self.assertTrue(any("pupone" in n for n in notes))
        self.assertTrue(any("stand-in" in n for n in notes), "GothamBold is a stand-in font")
        need, notes = tagpreview.plan(self.tag(pfp={"mode": "custom", "image": ""}, backdrop={"on": False, "image": "123"}, font="Arcade"))
        self.assertIsNone(need["picture"])
        self.assertIsNone(need["backdrop"])
        self.assertTrue(any("no image is set" in n for n in notes))
        self.assertTrue(any("backdrop is off" in n for n in notes))
        self.assertFalse(any("stand-in" in n for n in notes))


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

    def test_post_picture_and_webhook_picture(self):
        b = core.build_payload("a", "b", avatar_url="https://example.com/pup.png")
        self.assertEqual(b["avatar_url"], "https://example.com/pup.png")
        self.assertNotIn("avatar_url", core.build_payload("a", "b"))
        with self.assertRaises(ValueError):
            core.build_payload("a", "b", avatar_url="http://insecure/p.png")
        self.assertEqual(core.relay_fields("a", "b", avatar_url="https://x.y/p.png")["avatarUrl"], "https://x.y/p.png")
        img = core.load_image(png_file(self.folder))
        self.assertTrue(core.avatar_data_uri(img).startswith("data:image/png;base64,iVBOR"))
        with self.assertRaises(ValueError):
            core.avatar_data_uri(dict(img, mime="image/webp"))
        d = FakeDiscord()
        core.set_webhook_avatar(HOOK, img, opener=d)
        self.assertEqual(d.sent[0][0], HOOK)
        self.assertTrue(d.sent[0][1]["avatar"].startswith("data:image/png;base64,"))
        core.set_webhook_avatar(HOOK, None, opener=d)
        self.assertIsNone(d.sent[1][1]["avatar"])
        with self.assertRaises(RuntimeError):
            core.set_webhook_avatar("", img, opener=d)

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

    def test_tag_cleaning_matches_puppy_admin(self):
        out = tags.sanitize([{"name": "x" * 50, "text": "t", "color": [300, -5, 7.9], "size": 99, "members": ["12", "ab", 5, "12"],
                              "pfp": {"mode": "weird"}, "rainbow": "yes"},
                             {"name": "D1", "isDefault": True}, {"name": "D2", "isDefault": True}, {"text": "no name"}, 7])
        self.assertEqual(len(out), 2, "a second default tag and entries without a name are dropped (as TagSync.sanitize)")
        t = out[0]
        self.assertEqual((len(t["name"]), t["color"], t["size"], t["members"], t["pfp"]["mode"], t["rainbow"]),
                         (30, [255, 0, 7], 48, ["12", "5"], "none", False))
        self.assertTrue(out[1]["isDefault"])
        self.assertEqual(out[1]["name"], "D1")
        self.assertEqual(tags.parse_hex("#F59B28"), [245, 155, 40])
        with self.assertRaises(ValueError):
            tags.parse_hex("orange")

    def test_tags_load_and_save(self):
        repo = FakeTagRepo(TAGS)
        lst, sha = tags.load(None, repo)
        self.assertEqual([t["name"] for t in lst], ["Owner Tag", "Default"])
        lst[0]["members"].append("3")
        with self.assertRaises(RuntimeError):
            tags.save(lst, sha, None, opener=repo)
        with self.assertRaises(RuntimeError) as e:
            tags.save(lst, sha, "ghp_bad", opener=repo)
        self.assertIn("refused the token", str(e.exception))
        new_sha = tags.save(lst, sha, "ghp_good", opener=repo)
        self.assertEqual(repo.writes[0][0]["members"], ["1", "2", "3"])
        with self.assertRaises(RuntimeError) as e:
            tags.save(lst, sha, "ghp_good", opener=repo)
        self.assertIn("changed somewhere else", str(e.exception))
        self.assertEqual(new_sha, "s2")
        self.assertEqual(tags.user_id("PupFriend", repo), ("777", "PupFriend"))
        self.assertEqual(tags.user_id(" 123 ", repo), ("123", None))
        with self.assertRaises(RuntimeError):
            tags.user_id("nobody_here", repo)
        self.assertEqual(tags.user_names(["1", "2"], repo), {"1": "user1", "2": "user2"})
        self.assertIs(tags.owner_of(lst, "2"), lst[0])

    def test_update_check_and_download(self):
        exe = b"MZ new pupdates"
        info = {"build": 50, "sha256": hashlib.sha256(exe).hexdigest(), "size": len(exe)}

        def gh(req, timeout):
            if req.full_url.endswith(update.INFO):
                return Resp(json.dumps(info).encode())
            if req.full_url.endswith(update.EXE):
                return Resp(exe)
            raise AssertionError(req.full_url)
        got = update.check(gh)
        self.assertTrue(got["newer"])
        path = update.download(got, self.folder, gh)
        with open(path, "rb") as f:
            self.assertEqual(f.read(), exe)
        with self.assertRaises(RuntimeError):
            update.download(dict(got, sha256="0" * 64), self.folder, gh)
        bat = update.swap_script(r"C:\t\Pupdates.exe", r"C:\Apps\Pupdates.exe")
        self.assertIn('move /y "C:\\t\\Pupdates.exe" "C:\\Apps\\Pupdates.exe"', bat)
        self.assertIn("goto wait", bat)

    def test_bot_client(self):
        self.assertTrue(bot.valid_token(BOT_TOKEN))
        self.assertFalse(bot.valid_token("https://discord.com/api/webhooks/1/x"))
        self.assertEqual(bot.app_id_from_token(BOT_TOKEN), "123456789012345678")
        self.assertIn("client_id=123456789012345678&scope=bot+applications.commands", bot.invite_url("123456789012345678"))
        self.assertEqual(bot.PERMISSIONS, 1099780320278)
        self.assertNotIn(BOT_TOKEN, core.redact("failed: " + BOT_TOKEN))
        d = FakeBotDiscord()
        b = bot.Bot(BOT_TOKEN, d)
        self.assertEqual(b.me()["username"], "PupBot")
        self.assertEqual([g["name"] for g in b.guilds()], ["Puppy Server", "Zeta"])
        chans = b.channels("1")
        self.assertEqual([c["name"] for c in chans], ["lobby", "announcements", "general"], "no categories or voice; Discord's order")
        self.assertEqual(chans[1]["category"], "INFO")
        img = core.load_image(png_file(self.folder))
        body = core.build_payload("Hi", "there", image_name=img["name"], avatar_url="https://x.y/a.png")
        msg = b.post("11", body, img)
        method, path, sent, files = d.calls[-1]
        self.assertEqual((method, path), ("POST", "/channels/11/messages"))
        self.assertNotIn("username", sent)
        self.assertNotIn("avatar_url", sent, "bots keep their own name and picture")
        self.assertEqual(files[0][1], "pupdates.png")
        b.publish("11", msg["id"])
        self.assertEqual(d.calls[-1][1], "/channels/11/messages/%s/crosspost" % msg["id"])
        b.edit("11", msg["id"], core.build_payload("Hi again", "changed", image_name="pupdates.png"))
        patched = d.calls[-1][2]
        self.assertEqual(patched["attachments"], [{"id": "a" + msg["id"]}], "the picture is kept")
        self.assertEqual(patched["embeds"][0]["image"]["url"], "attachment://pupdates.png")
        b.delete("11", msg["id"])
        with self.assertRaises(bot.BotError) as e:
            b.message("11", msg["id"])
        self.assertIn("no longer exists", str(e.exception))
        with self.assertRaises(bot.BotError) as e:
            b.post("99", core.build_payload("a", "b"))
        self.assertIn("missing a permission", str(e.exception))
        with self.assertRaises(bot.BotError) as e:
            bot.Bot(BOT_TOKEN[:-3] + "zzz", d).me()
        self.assertIn("wrong or was reset", str(e.exception))
        self.assertNotIn(BOT_TOKEN[:20], str(e.exception))
        b.set_profile(username="Pupdates Bot")
        self.assertEqual(d.calls[-1][2], {"username": "Pupdates Bot"})
        b.set_profile(avatar=img)
        self.assertTrue(d.calls[-1][2]["avatar"].startswith("data:image/png;base64,"))
        self.assertEqual(bot.remember([{"message": "1"}, {"message": "2"}], {"message": "2"}), [{"message": "2"}, {"message": "1"}])

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
        self.settings.set("mode", "webhook")     # the older tests post to a webhook; the bot tests switch to "bot"
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

    def test_tags_section(self):
        repo = FakeTagRepo(TAGS)
        self.app.opener = repo
        self.app.show("tags")
        self.assertTrue(self.app.load_tags())
        self.assertTrue(self.pump(lambda: self.app.tags_box.size() == 2))
        self.assertTrue(self.pump(lambda: "user1" in " ".join(self.app.members_box.get(0, "end")) or self.app.tag_names))
        self.app.tags_box.selection_set(0)
        self.app.pick_tag()
        self.assertEqual(self.app.tv["text"].get(), "Puppy Admin")
        self.app.tv["text"].set("Puppy Boss")
        self.app.member_var.set("PupFriend")
        self.assertTrue(self.app.add_member())
        self.assertTrue(self.pump(lambda: "777" in self.app.tag_list[0]["members"]))
        self.assertFalse(self.app.save_tags(), "no token yet")
        self.app.tag_token_var.set("ghp_good")
        self.assertTrue(self.app.save_tag_token())
        self.assertTrue(self.app.save_tags())
        self.assertTrue(self.pump(lambda: repo.writes))
        saved = repo.writes[0][0]
        self.assertEqual((saved["text"], saved["members"]), ("Puppy Boss", ["1", "2", "777"]))
        self.app.new_tag()
        self.assertEqual(self.app.tags_box.size(), 3)
        self.app.tv["color"].set("nope")
        self.assertFalse(self.app._store_tag())
        self.assertIn("hex", self.app.status.cget("text"))

    def test_webhook_picture_settings(self):
        self.app.avatar_var.set("ftp://nope")
        self.assertFalse(self.app.save_avatar_url())
        self.app.avatar_var.set("https://example.com/pup.png")
        self.assertTrue(self.app.save_avatar_url())
        self.settings.set_webhook(HOOK)
        self.app.message.insert("1.0", "hi")
        self.assertTrue(self.app.post())
        self.assertTrue(self.pump(lambda: self.discord.sent))
        self.assertEqual(self.discord.sent[0][1]["avatar_url"], "https://example.com/pup.png")
        self.assertTrue(self.app.set_webhook_avatar(core.load_image(png_file(self.folder))))
        self.assertTrue(self.pump(lambda: len(self.discord.sent) == 2))
        self.assertTrue(self.discord.sent[1][1]["avatar"].startswith("data:image/png"))
        self.assertTrue(self.pump(lambda: "picture was changed" in self.app.status.cget("text")))

    def test_every_tag_setting_round_trips(self):
        repo = FakeTagRepo(TAGS)
        self.app.opener = repo
        self.settings.set_secret("tags_token", "ghp_good")
        self.app.load_tags()
        self.assertTrue(self.pump(lambda: self.app.tags_box.size() == 2))
        self.app.tags_box.selection_set(0)
        self.app.pick_tag()
        self.assertEqual((self.app.tv["bd_color"].get(), self.app.tv["bd_alpha"].get(), self.app.tv["offset"].get()), ("#121216", "0.35", "3"))
        for k, v in (("offset", "7.5"), ("bd_color", "#203040"), ("bd_alpha", "0.6"), ("bd_image", "rbxassetid://123"),
                     ("bd_img_alpha", "0.3"), ("pfp_mode", "custom"), ("pfp_image", "https://example.com/p.png"), ("size", "30")):
            self.app.tv[k].set(v)
        self.app.tv_bd_round.set(False)
        self.app.tv_pfp_round.set(False)
        self.assertTrue(self.app.save_tags())
        self.assertTrue(self.pump(lambda: repo.writes))
        t = repo.writes[0][0]
        self.assertEqual((t["offset"], t["size"], t["backdrop"], t["pfp"]),
                         (7.5, 30.0, {"on": True, "color": [32, 48, 64], "transparency": 0.6, "image": "rbxassetid://123",
                                      "imageTransparency": 0.3, "round": False},
                          {"mode": "custom", "image": "https://example.com/p.png", "round": False}))
        self.app.tv["bd_alpha"].set("lots")
        self.assertFalse(self.app._store_tag())

    @unittest.skipUnless(tagpreview.available(), "needs Pillow")
    def test_tag_preview_loads_the_pictures(self):
        repo = FakeTagRepo(TAGS)
        self.app.opener = repo
        self.app.tag_images.opener = FakeRoblox()
        self.app.show("tags")
        self.app.load_tags()
        self.assertTrue(self.pump(lambda: self.app.tags_box.size() == 2))
        self.app.tags_box.selection_set(0)
        self.app.pick_tag()
        self.app.tv["pfp_mode"].set("custom")
        self.app.tv["pfp_image"].set("https://example.com/me.png")
        self.app.tv["bd_image"].set("4242")
        self.assertTrue(self.pump(lambda: "loading" not in self.app.tag_preview_note.cget("text")
                                  and self.app._preview_photo is not None, 5))
        self.assertTrue(self.app.tag_preview.cget("image"))
        self.app.tv["pfp_image"].set("https://example.com/page.html")
        self.assertTrue(self.pump(lambda: "could not load" in self.app.tag_preview_note.cget("text"), 5))
        self.assertIn("shows no picture", self.app.tag_preview_note.cget("text"))

    def test_bot_mode(self):
        d = FakeBotDiscord()
        self.app.opener = d
        self.app.mode_var.set("bot")
        self.app.set_mode()
        self.assertFalse(self.app.post())
        self.assertIn("token", self.app.status.cget("text"))
        self.app.show("bot")
        self.app.bot_token_var.set("not a token")
        self.assertFalse(self.app.save_bot_token())
        self.app.bot_token_var.set(BOT_TOKEN)
        self.assertTrue(self.app.save_bot_token())
        with open(os.path.join(self.folder, "settings.json"), encoding="utf-8") as f:
            self.assertNotIn(BOT_TOKEN, f.read())
        self.assertTrue(self.pump(lambda: "Signed in as PupBot" in self.app.bot_who.cget("text")))
        self.assertTrue(self.pump(lambda: self.settings.get("bot_channel") == "14"), "first server, first channel")
        self.assertEqual(self.app.guild_var.get(), "Puppy Server")
        self.app.channel_var.set(self.app._channel_text(self.app.bot_channels[1]))
        self.assertTrue(self.app.pick_channel())
        self.assertEqual((self.settings.get("bot_channel"), self.settings.get("bot_channel_type")), ("11", bot.ANNOUNCEMENT))
        self.app.show("compose")
        self.assertIn("#announcements", self.app.where_lbl.cget("text"))
        self.app.title_var.set("Big news")
        self.app.message.insert("1.0", "Pupdates has a bot now")
        self.assertTrue(self.app.post())
        self.assertTrue(self.pump(lambda: "Published" in self.app.status.cget("text")))
        self.assertEqual(self.app.posts_box.size(), 1)
        mid = self.settings.get("recent_posts")[0]["message"]
        self.assertTrue(any(c[1].endswith("/crosspost") for c in d.calls))
        # edit it
        self.app.show("bot")
        self.app.posts_box.selection_set(0)
        self.assertTrue(self.app.edit_post())
        self.assertTrue(self.pump(lambda: self.app.editing is not None))
        self.assertEqual(self.app.title_var.get(), "Big news")
        self.assertEqual(self.app.post_btn.cget("text"), "Save changes")
        self.app.title_var.set("Bigger news")
        self.assertTrue(self.app.post())
        self.assertTrue(self.pump(lambda: "updated" in self.app.status.cget("text")))
        self.assertEqual(d.messages[mid]["embeds"][0]["title"], "Bigger news")
        self.assertEqual(self.settings.get("recent_posts")[0]["title"], "Bigger news")
        self.assertIsNone(self.app.editing)
        # delete it
        self.app.posts_box.selection_set(0)
        self.assertTrue(self.app.delete_post())
        self.assertTrue(self.pump(lambda: self.app.posts_box.size() == 0))
        self.assertNotIn(mid, d.messages)
        # the bot itself
        self.app.bot_name_var.set("Pup News")
        self.assertTrue(self.app.rename_bot())
        self.assertTrue(self.pump(lambda: "Pup News" in self.app.status.cget("text")))
        self.assertTrue(self.app.set_bot_picture(core.load_image(png_file(self.folder))))
        self.assertTrue(self.pump(lambda: "picture was changed" in self.app.status.cget("text")))

    def test_topmost_setting(self):
        self.app.topmost_var.set(True)
        self.app.set_topmost(True, save=True)
        self.assertTrue(self.settings.get("topmost"))  # (X11 reports -topmost 0 for a withdrawn test window)

    def test_sections_and_icons(self):
        for name in ("bot", "updates", "tags", "whitelist", "settings", "compose"):
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

        self.assertTrue(self.app.install_mod_commands())
        self.assertTrue(self.pump(lambda: "Installed 18 commands" in self.app.mod_lbl.cget("text")))
        self.assertIn(RELAY + "/interactions", self.app.mod_lbl.cget("text"))


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
