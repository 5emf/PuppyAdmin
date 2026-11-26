"""Everything Pupdates does that is not the window: Discord payloads (embed or plain message,
with an optional picture), posting straight to a webhook or through the Pupdates relay (the
whitelist), managing the whitelist, reading Puppy Admin's build / the companion's version /
recent commits from GitHub, and the settings file (webhook and keys encrypted with Windows
DPAPI). Standard library only.
"""
import base64
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

APP = "Pupdates"
REPO = "5emf/PuppyAdmin"
BRANCH = "ccr-3b4dfcff-nyfy0w"
LOADSTRING = ('local H=game:GetService("HttpService") local ok,sha=pcall(function() return H:JSONDecode(game:HttpGet('
              '"https://api.github.com/repos/%s/commits/%s")).sha end) loadstring(game:HttpGet('
              '"https://raw.githubusercontent.com/%s/"..(ok and sha or "%s").."/PuppyAdmin.lua"))()') % (REPO, BRANCH, REPO, BRANCH)
COLORS = {"Orange": 0xF59B28, "Blue": 0x5AA9FF, "Green": 0x6FDC8C, "Red": 0xE84A5F, "Grey": 0x9B9CA8, "Purple": 0xA064F0}
PINGS = ("none", "@here", "@everyone", "role")
MAX_DESC, MAX_FIELD, MAX_TITLE, MAX_CONTENT = 4096, 1024, 256, 2000
MAX_IMAGE = 8 * 1024 * 1024
WEBHOOK_RE = re.compile(r"^https://(?:ptb\.|canary\.)?discord(?:app)?\.com/api/webhooks/\d+/[\w-]+$")
USER_AGENT = "Pupdates/1"


# ------------------------------------------------------------------ text helpers
def valid_webhook(url):
    return bool(WEBHOOK_RE.match(str(url or "").strip()))


def valid_relay(url):
    u = str(url or "").strip()
    return u.startswith("https://") and " " not in u and len(u) > 10


def redact(text, *secrets):
    """Hides webhook secrets and keys in anything shown or logged."""
    t = str(text)
    t = re.sub(r"(discord(?:app)?\.com/api/webhooks/\d+/)[\w-]+", r"\1***", t)
    t = re.sub(r"pup_[\w-]{8,}", "pup_***", t)
    t = re.sub(r"[\w-]{18,}\.[\w-]{4,}\.[\w-]{20,}", "***", t)   # Discord bot tokens
    for s in secrets:
        if s:
            t = t.replace(s, "***")
    return t


def clean_subject(line):
    s = (line or "").strip()
    if not s or s.lower().startswith(("co-authored-by", "claude-session", "merge ")):
        return ""
    return s.rstrip(".")


def bullets(subjects, limit=3500):
    out, used = [], 0
    subjects = [s for s in (clean_subject(x) for x in subjects) if s]
    for i, s in enumerate(subjects):
        line = "- " + (s if len(s) <= 300 else s[:297] + "...")
        rest = len(subjects) - i
        if used + len(line) + 1 + len("\n... and %d more" % rest) > limit and out:
            out.append("... and %d more" % rest)
            break
        out.append(line)
        used += len(line) + 1
    return "\n".join(out)


# ------------------------------------------------------------------ pictures
IMAGE_MAGIC = ((b"\x89PNG\r\n\x1a\n", "image/png", "png"), (b"\xff\xd8\xff", "image/jpeg", "jpg"),
               (b"GIF87a", "image/gif", "gif"), (b"GIF89a", "image/gif", "gif"))


def image_kind(data):
    """(mime, extension) of a picture from its first bytes, or None when it is not PNG/JPG/GIF/WEBP."""
    for magic, mime, ext in IMAGE_MAGIC:
        if data.startswith(magic):
            return mime, ext
    if len(data) > 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp", "webp"
    return None


def load_image(path):
    """{data, mime, name} for a picture file, or raises ValueError with a readable reason."""
    try:
        size = os.path.getsize(path)
    except OSError:
        raise ValueError("That picture could not be opened")
    if size > MAX_IMAGE:
        raise ValueError("That picture is bigger than 8 MB")
    with open(path, "rb") as f:
        data = f.read()
    kind = image_kind(data)
    if not kind:
        raise ValueError("Pictures must be PNG, JPG, GIF or WEBP")
    return {"data": data, "mime": kind[0], "name": "pupdates." + kind[1], "path": path}


def multipart(fields, files):
    """(body bytes, content type) for a multipart/form-data request. files: [(field, name, mime, data)]"""
    boundary = "pupdates" + uuid.uuid4().hex
    parts = []
    for name, value in fields:
        parts.append(("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n"
                      "Content-Type: application/json\r\n\r\n" % (boundary, name)).encode() + value.encode("utf-8") + b"\r\n")
    for field, fname, mime, data in files:
        parts.append(("--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\n"
                      "Content-Type: %s\r\n\r\n" % (boundary, field, fname, mime)).encode() + data + b"\r\n")
    parts.append(("--%s--\r\n" % boundary).encode())
    return b"".join(parts), "multipart/form-data; boundary=" + boundary


# ------------------------------------------------------------------ Discord payloads
def valid_avatar_url(url):
    u = str(url or "").strip()
    return u.startswith("https://") and " " not in u and len(u) <= 2000


def build_payload(title, message, color="Orange", ping="none", role_id="", loadstring=False,
                  username=APP, embed=True, image_name=None, footer="", avatar_url=""):
    """The webhook body. embed=False sends a plain message (any text, up to 2000 characters).
    A picture is shown inside the embed (attachment://) or under the plain message.
    avatar_url (an https image) replaces the webhook's picture for this post only."""
    body = {"username": (username or APP)[:80], "allowed_mentions": {"parse": []}}
    if avatar_url:
        if not valid_avatar_url(avatar_url):
            raise ValueError("The post picture must be an https:// link to an image")
        body["avatar_url"] = avatar_url.strip()
    mention = ""
    if ping in ("@here", "@everyone"):
        mention = ping
        body["allowed_mentions"] = {"parse": ["everyone"]}
    elif ping == "role":
        rid = str(role_id or "").strip()
        if not rid.isdigit():
            raise ValueError("A role ping needs the role's id (a number: right-click the role > Copy Role ID)")
        mention = "<@&%s>" % rid
        body["allowed_mentions"] = {"roles": [rid]}
    message = (message or "").strip()
    if not embed:
        text = "\n".join(x for x in (mention, (title or "").strip() and "**%s**" % title.strip(), message) if x)
        if loadstring:
            text += "\n```lua\n%s\n```" % LOADSTRING
        if not text and not image_name:
            raise ValueError("Write a message or add a picture")
        body["content"] = text[:MAX_CONTENT]
        return body
    e = {"title": (title or APP).strip()[:MAX_TITLE], "color": COLORS.get(color, COLORS["Orange"]),
         "description": message[:MAX_DESC] or "-"}
    if loadstring:
        e["fields"] = [{"name": "Loadstring", "value": ("```lua\n%s\n```" % LOADSTRING)[:MAX_FIELD]}]
    if image_name:
        e["image"] = {"url": "attachment://" + image_name}
    if footer:
        e["footer"] = {"text": footer[:200]}
    body["embeds"] = [e]
    if mention:
        body["content"] = mention
    return body


def relay_fields(title, message, color="Orange", ping="none", role_id="", loadstring=False, username=APP, embed=True,
                 avatar_url=""):
    """What the relay gets (it builds the Discord message itself, adding who posted it)."""
    if avatar_url and not valid_avatar_url(avatar_url):
        raise ValueError("The post picture must be an https:// link to an image")
    return {"title": (title or "").strip(), "message": (message or "").strip(), "color": COLORS.get(color, COLORS["Orange"]),
            "ping": ping, "roleId": str(role_id or "").strip(), "loadstring": bool(loadstring),
            "username": (username or APP)[:80], "embed": bool(embed), "avatarUrl": (avatar_url or "").strip()}


AVATAR_TYPES = ("image/png", "image/jpeg", "image/gif")


def avatar_data_uri(image):
    """The webhook's saved picture as Discord wants it (PNG / JPG / GIF, at most 8 MB)."""
    if image["mime"] not in AVATAR_TYPES:
        raise ValueError("The webhook picture must be PNG, JPG or GIF")
    return "data:%s;base64,%s" % (image["mime"], base64.b64encode(image["data"]).decode("ascii"))


def set_webhook_avatar(url, image, name=None, opener=None):
    """Changes the webhook's own picture (and name) for good, with only the webhook URL (Discord's
    "modify webhook with token"). image=None removes the picture."""
    url = (url or "").strip()
    if not valid_webhook(url):
        raise RuntimeError("Save your webhook first")
    body = {"avatar": avatar_data_uri(image) if image else None}
    if name:
        body["name"] = name[:80]
    req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"), method="PATCH",
                                 headers={"Content-Type": "application/json", "User-Agent": USER_AGENT})
    try:
        return _send(req, opener, tries=2, secrets=(url,))
    except RuntimeError as e:
        raise RuntimeError("Discord did not change the picture: %s" % e)


def preview_text(body, image=None):
    """How the post reads, as plain text (for the preview)."""
    lines = []
    if body.get("embeds"):
        e = body["embeds"][0]
        if body.get("content"):
            lines.append(body["content"])
        lines += [e["title"].upper(), "", e["description"]]
        for f in e.get("fields", []):
            lines += ["", f["name"] + ":", f["value"]]
    else:
        lines.append(body.get("content", ""))
    if image:
        lines += ["", "[picture: %s]" % os.path.basename(image.get("path") or image["name"])]
    return "\n".join(lines)


# ------------------------------------------------------------------ sending
def _send(req, opener, tries=3, sleep=time.sleep, secrets=()):
    opener = opener or urllib.request.urlopen
    for attempt in range(tries):
        try:
            with opener(req, timeout=30) as r:
                raw = r.read()
                try:
                    return json.loads(raw.decode("utf-8")) if raw else {}
                except (ValueError, UnicodeDecodeError):
                    return {}
        except urllib.error.HTTPError as e:
            try:
                info = json.loads(e.read().decode("utf-8"))
            except (ValueError, AttributeError, UnicodeDecodeError):
                info = {}
            if e.code == 429 and attempt < tries - 1 and "retry_after" in info:
                sleep(min(float(info.get("retry_after") or 2), 30))
                continue
            raise RuntimeError(redact(info.get("error") or {
                401: "not allowed (the webhook was deleted, or your key is wrong / removed)",
                404: "it no longer exists", 400: "the message was not accepted (too long, or empty)",
                429: "too many posts: wait a minute"}.get(e.code, "HTTP %d" % e.code), *secrets))
        except (urllib.error.URLError, OSError) as e:
            raise RuntimeError(redact("Could not connect: %s" % getattr(e, "reason", e), *secrets))
    raise RuntimeError("Still rate-limited: try again in a minute")


def post_webhook(url, body, image=None, opener=None, sleep=time.sleep):
    """Posts straight to a Discord webhook. Returns the message id ("" when unknown)."""
    url = (url or "").strip()
    if not valid_webhook(url):
        raise RuntimeError("That is not a Discord webhook URL (channel settings > Integrations > Webhooks > Copy Webhook URL)")
    if image:
        data, ctype = multipart([("payload_json", json.dumps(body))], [("files[0]", image["name"], image["mime"], image["data"])])
    else:
        data, ctype = json.dumps(body).encode("utf-8"), "application/json"
    req = urllib.request.Request(url + "?wait=true", data=data, method="POST",
                                 headers={"Content-Type": ctype, "User-Agent": USER_AGENT})
    try:
        return str(_send(req, opener, sleep=sleep, secrets=(url,)).get("id", ""))
    except RuntimeError as e:
        raise RuntimeError("Discord refused the post: %s" % e)


def _relay_req(base, path, method="GET", key=None, admin=None, data=None, ctype=None):
    headers = {"User-Agent": USER_AGENT}
    if key:
        headers["Authorization"] = "Bearer " + key
    if admin:
        headers["X-Admin-Key"] = admin
    if ctype:
        headers["Content-Type"] = ctype
    return urllib.request.Request(base.rstrip("/") + path, data=data, method=method, headers=headers)


def post_relay(base, key, fields, image=None, opener=None):
    """Posts through the Pupdates relay with a whitelist access key. Returns the relay's answer."""
    if not valid_relay(base):
        raise RuntimeError("The relay address must start with https://")
    if not key:
        raise RuntimeError("Enter your access key (ask the owner to whitelist you)")
    files = [("image", image["name"], image["mime"], image["data"])] if image else []
    data, ctype = multipart([("payload", json.dumps(fields))], files)
    return _send(_relay_req(base, "/post", "POST", key=key, data=data, ctype=ctype), opener, tries=1, secrets=(key,))


def relay_me(base, key, opener=None):
    return _send(_relay_req(base, "/me", key=key), opener, tries=1, secrets=(key,))


def admin_list(base, admin, opener=None):
    out = _send(_relay_req(base, "/admin/users", admin=admin), opener, tries=1, secrets=(admin,))
    return out if isinstance(out, list) else []


def admin_add(base, admin, name, can_ping=False, opener=None):
    data = json.dumps({"name": name, "canPing": bool(can_ping)}).encode("utf-8")
    return _send(_relay_req(base, "/admin/users", "POST", admin=admin, data=data, ctype="application/json"),
                 opener, tries=1, secrets=(admin,))


def admin_avatar(base, admin, image, name=None, opener=None):
    """Owner, relay mode: the relay changes its webhook's own picture (it alone knows the webhook)."""
    body = {"avatar": avatar_data_uri(image) if image else None}
    if name:
        body["name"] = name[:80]
    return _send(_relay_req(base, "/admin/avatar", "POST", admin=admin, data=json.dumps(body).encode("utf-8"),
                            ctype="application/json"), opener, tries=1, secrets=(admin,))


def admin_commands(base, admin, opener=None):
    """Owner: the relay installs / updates the moderation slash commands in Discord ->
    {count, application, interactionsUrl, publicKeySet}."""
    return _send(_relay_req(base, "/admin/commands", "POST", admin=admin, data=b"{}", ctype="application/json"),
                 opener, tries=1, secrets=(admin,))


def admin_remove(base, admin, name, opener=None):
    return _send(_relay_req(base, "/admin/users/" + urllib.parse.quote(name, safe=""), "DELETE", admin=admin),
                 opener, tries=1, secrets=(admin,))


# ------------------------------------------------------------------ GitHub (public repo, no token)
def _get(url, opener=None):
    opener = opener or urllib.request.urlopen
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json"})
    try:
        with opener(req, timeout=20) as r:
            return r.read()
    except (urllib.error.URLError, OSError) as e:
        raise RuntimeError("Could not reach GitHub: %s" % getattr(e, "reason", e))


def script_build(text):
    m = re.search(r'local\s+SCRIPT_BUILD\s*=\s*"([^"]+)"', text or "")
    return m.group(1) if m else None


def payload_version(text):
    m = re.search(r'PAYLOAD_VERSION\s*=\s*"([^"]+)"', text or "")
    return m.group(1) if m else None


def latest(opener=None):
    """The branch head: sha, Puppy Admin build, companion version, recent commits [(sha, subject)]."""
    commits = json.loads(_get("https://api.github.com/repos/%s/commits?sha=%s&per_page=40" % (REPO, BRANCH), opener).decode("utf-8"))
    if not isinstance(commits, list) or not commits:
        raise RuntimeError("GitHub returned no commits")
    sha = commits[0]["sha"]
    raw = "https://raw.githubusercontent.com/%s/%s/" % (REPO, sha)
    build = script_build(_get(raw + "PuppyAdmin.lua", opener).decode("utf-8", "replace"))
    version = payload_version(_get(raw + "companion/puppy_companion/_payload.py", opener).decode("utf-8", "replace"))
    recent = [(c["sha"], (c.get("commit", {}).get("message") or "").splitlines()[0] if c.get("commit") else "") for c in commits]
    return {"sha": sha, "build": build, "version": version, "commits": recent}


def subjects_since(commits, last_sha, cap=15):
    out = []
    for sha, subject in commits:
        if last_sha and sha.startswith(last_sha):
            break
        out.append(subject)
        if len(out) >= cap and not last_sha:
            break
    return list(reversed(out))


def script_template(info, last_sha=None):
    title = "Puppy Admin updated - build %s" % (info.get("build") or "?")
    text = bullets(subjects_since(info["commits"], last_sha)) or "- Small fixes"
    return title, text + "\n\nExecute Puppy Admin again: a newer build replaces the running one."


def companion_template(info, last_sha=None):
    title = "Puppy Companion updated - %s" % (info.get("version") or "?")
    text = bullets(subjects_since(info["commits"], last_sha)) or "- Small fixes"
    return title, text + "\n\nRestart Puppy Companion: it downloads the update itself."


# ------------------------------------------------------------------ settings (secrets encrypted)
def data_dir():
    base = os.environ.get("PUPDATES_HOME")
    if base:
        return base
    if sys.platform == "win32":
        return os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~"), "Pupdates")
    return os.path.join(os.path.expanduser("~"), ".pupdates")


def migrate_old_settings(new_dir):
    """Puppy Announcer -> Pupdates: the old settings (and the saved webhook) come along once."""
    if sys.platform != "win32" or os.path.exists(os.path.join(new_dir, "settings.json")):
        return False
    old = os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~"), "PuppyAnnouncer", "settings.json")
    if not os.path.isfile(old):
        return False
    os.makedirs(new_dir, exist_ok=True)
    shutil.copyfile(old, os.path.join(new_dir, "settings.json"))
    return True


class Dpapi:
    """Windows DPAPI for the current user: only this Windows account on this PC can read it back.
    (Same entropy as Puppy Announcer, so a migrated webhook still opens.)"""
    ENTROPY = b"PuppyAnnouncer/webhook/v1"

    def __init__(self):
        if sys.platform != "win32":
            raise RuntimeError("Secrets are stored with Windows' own encryption: Windows only")
        import ctypes
        from ctypes import wintypes

        class BLOB(ctypes.Structure):
            _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]
        self._ct, self._BLOB = ctypes, BLOB
        crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
        self._kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self._protect, self._unprotect = crypt32.CryptProtectData, crypt32.CryptUnprotectData
        for fn in (self._protect, self._unprotect):
            fn.argtypes = [ctypes.POINTER(BLOB), ctypes.c_void_p, ctypes.POINTER(BLOB), ctypes.c_void_p,
                           ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(BLOB)]
            fn.restype = wintypes.BOOL
        self._kernel32.LocalFree.argtypes = [ctypes.c_void_p]

    def _run(self, fn, data):
        ct = self._ct
        sbuf = ct.create_string_buffer(bytes(data), len(data))
        ebuf = ct.create_string_buffer(self.ENTROPY, len(self.ENTROPY))
        src = self._BLOB(len(data), ct.cast(sbuf, ct.POINTER(ct.c_char)))
        ent = self._BLOB(len(self.ENTROPY), ct.cast(ebuf, ct.POINTER(ct.c_char)))
        out = self._BLOB()
        if not fn(ct.byref(src), None, ct.byref(ent), None, None, 1, ct.byref(out)):
            raise RuntimeError("Windows could not read / write a saved secret (error %d)" % ct.get_last_error())
        try:
            return ct.string_at(out.pbData, out.cbData)
        finally:
            self._kernel32.LocalFree(ct.cast(out.pbData, ct.c_void_p))

    def protect(self, data):
        return self._run(self._protect, data)

    def unprotect(self, data):
        return self._run(self._unprotect, data)


class Settings:
    FILE = "settings.json"
    SECRETS = ("webhook", "relay_key", "admin_key", "tags_token", "bot_token")
    DEFAULTS = {"mode": "bot", "webhook": "", "relay_url": "", "relay_key": "", "admin_key": "",
                "username": APP, "color": "Orange", "ping": "none", "role_id": "", "embed": True,
                "last_script_sha": "", "last_companion_sha": "", "tags_token": "", "topmost": False, "avatar_url": "",
                "bot_token": "", "bot_guild": "", "bot_guild_name": "", "bot_channel": "", "bot_channel_name": "",
                "bot_channel_type": 0, "bot_publish": True, "recent_posts": [],
                "bot_online": False, "bot_activity_type": "Listening", "bot_activity_text": "Jae but mainly Claude", "bot_status": "online",
                "rp_on": False, "rp_app_id": "", "rp_type": "Listening", "rp_details": "May Your Heart Be", "rp_state": "Your Guiding Key",
                "rp_start": "1795676718", "rp_button_label": "Join for more Pupdates", "rp_button_url": "https://discord.gg/eDC7V9bnAX",
                "rp_image": ""}

    def __init__(self, folder=None, protector=None):
        self.folder = folder or data_dir()
        if folder is None:
            try:
                migrate_old_settings(self.folder)
            except OSError:
                pass
        self.path = os.path.join(self.folder, self.FILE)
        self.protector = protector
        self.data = dict(self.DEFAULTS)
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                saved = json.load(f)
            if isinstance(saved, dict):
                for k in self.DEFAULTS:
                    if k in saved and isinstance(saved[k], type(self.DEFAULTS[k])):
                        self.data[k] = saved[k]
                if self.data.get("username") == "Puppy Admin updates":
                    self.data["username"] = APP
        except (OSError, ValueError):
            pass

    def save(self):
        os.makedirs(self.folder, exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.data, f, indent=2)
        os.replace(tmp, self.path)

    def get(self, key):
        return self.data.get(key, self.DEFAULTS.get(key))

    def set(self, key, value):
        self.data[key] = value
        self.save()

    def secret(self, key):
        blob = self.data.get(key) or ""
        if not blob or not self.protector:
            return ""
        try:
            return self.protector.unprotect(base64.b64decode(blob)).decode("utf-8")
        except (ValueError, RuntimeError):
            return ""

    def set_secret(self, key, value):
        value = (value or "").strip()
        if value and not self.protector:
            raise RuntimeError("No encryption available here, so it is not saved")
        self.set(key, base64.b64encode(self.protector.protect(value.encode("utf-8"))).decode("ascii") if value else "")

    def webhook(self):
        return self.secret("webhook")

    def set_webhook(self, url):
        url = (url or "").strip()
        if url and not valid_webhook(url):
            raise ValueError("That is not a Discord webhook URL")
        self.set_secret("webhook", url)
