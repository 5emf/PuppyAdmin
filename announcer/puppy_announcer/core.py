"""Everything the announcer does that is not the window: Discord payloads, the webhook post,
reading Puppy Admin's build / the companion's version / recent commits from GitHub, and the
settings file (the webhook URL is kept encrypted with Windows DPAPI). Standard library only.
"""
import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

REPO = "5emf/PuppyAdmin"
BRANCH = "ccr-3b4dfcff-nyfy0w"
LOADSTRING = ('local H=game:GetService("HttpService") local ok,sha=pcall(function() return H:JSONDecode(game:HttpGet('
              '"https://api.github.com/repos/%s/commits/%s")).sha end) loadstring(game:HttpGet('
              '"https://raw.githubusercontent.com/%s/"..(ok and sha or "%s").."/PuppyAdmin.lua"))()') % (REPO, BRANCH, REPO, BRANCH)
COLORS = {"Orange": 0xF59B28, "Blue": 0x5AA9FF, "Green": 0x6FDC8C, "Red": 0xE84A5F, "Grey": 0x9B9CA8, "Purple": 0xA064F0}
PINGS = ("none", "@here", "@everyone", "role")
MAX_DESC, MAX_FIELD, MAX_TITLE = 4096, 1024, 256
WEBHOOK_RE = re.compile(r"^https://(?:ptb\.|canary\.)?discord(?:app)?\.com/api/webhooks/\d+/[\w-]+$")
USER_AGENT = "PuppyAnnouncer/1"


# ------------------------------------------------------------------ Discord
def valid_webhook(url):
    return bool(WEBHOOK_RE.match(str(url or "").strip()))


def redact(text, url=None):
    """Hides a webhook's secret part in anything shown or logged."""
    t = str(text)
    t = re.sub(r"(discord(?:app)?\.com/api/webhooks/\d+/)[\w-]+", r"\1***", t)
    if url:
        t = t.replace(url, "(webhook)")
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


def build_payload(title, message, color="Orange", ping="none", role_id="", loadstring=False,
                  username="Puppy Admin updates", footer=""):
    """The webhook body: one embed, and a mention only when a ping was chosen."""
    embed = {"title": (title or "Puppy Admin").strip()[:MAX_TITLE], "color": COLORS.get(color, COLORS["Orange"]),
             "description": (message or "").strip()[:MAX_DESC] or "-"}
    if loadstring:
        embed["fields"] = [{"name": "Loadstring", "value": ("```lua\n%s\n```" % LOADSTRING)[:MAX_FIELD]}]
    if footer:
        embed["footer"] = {"text": footer[:200]}
    body = {"username": (username or "Puppy Admin updates")[:80], "embeds": [embed], "allowed_mentions": {"parse": []}}
    if ping in ("@here", "@everyone"):
        body["content"] = ping
        body["allowed_mentions"] = {"parse": ["everyone"]}
    elif ping == "role":
        rid = str(role_id or "").strip()
        if not rid.isdigit():
            raise ValueError("A role ping needs the role's id (a number: right-click the role > Copy Role ID)")
        body["content"] = "<@&%s>" % rid
        body["allowed_mentions"] = {"roles": [rid]}
    return body


def preview_text(body):
    """How the post reads, as plain text (for the Preview box)."""
    e = body["embeds"][0]
    lines = []
    if body.get("content"):
        lines.append(body["content"])
    lines += [e["title"].upper(), "", e["description"]]
    for f in e.get("fields", []):
        lines += ["", f["name"] + ":", f["value"]]
    if e.get("footer"):
        lines += ["", e["footer"]["text"]]
    return "\n".join(lines)


def post(url, body, opener=None, tries=3, sleep=time.sleep):
    """Posts to the webhook. Returns the new message's id (or ""). Raises RuntimeError with a
    readable reason (never containing the webhook's secret)."""
    if not valid_webhook(url):
        raise RuntimeError("That is not a Discord webhook URL (channel settings > Integrations > Webhooks > Copy Webhook URL)")
    opener = opener or urllib.request.urlopen
    data = json.dumps(body).encode("utf-8")
    for attempt in range(tries):
        req = urllib.request.Request(url.strip() + "?wait=true", data=data, method="POST",
                                     headers={"Content-Type": "application/json", "User-Agent": USER_AGENT})
        try:
            with opener(req, timeout=20) as r:
                raw = r.read()
                try:
                    return str(json.loads(raw.decode("utf-8")).get("id", ""))
                except (ValueError, AttributeError):
                    return ""
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < tries - 1:
                try:
                    wait = float(json.loads(e.read().decode("utf-8")).get("retry_after", 2))
                except (ValueError, AttributeError):
                    wait = 2
                sleep(min(wait, 30))
                continue
            reason = {401: "the webhook was deleted or its URL is wrong", 404: "the webhook no longer exists",
                      400: "Discord did not accept the message (too long, or an empty field)"}.get(e.code, "HTTP %d" % e.code)
            raise RuntimeError("Discord refused the post: %s" % reason)
        except (urllib.error.URLError, OSError) as e:
            raise RuntimeError(redact("Could not reach Discord: %s" % getattr(e, "reason", e), url))
    raise RuntimeError("Discord kept rate-limiting the post; try again in a minute")


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
    """Commit subjects newer than last_sha (the last announced one); the newest cap when unknown."""
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


# ------------------------------------------------------------------ settings (webhook encrypted)
def data_dir():
    base = os.environ.get("PUPPY_ANNOUNCER_HOME")
    if base:
        return base
    if sys.platform == "win32":
        return os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~"), "PuppyAnnouncer")
    return os.path.join(os.path.expanduser("~"), ".puppy_announcer")


class Dpapi:
    """Windows DPAPI for the current user: only this Windows account on this PC can read it back."""
    ENTROPY = b"PuppyAnnouncer/webhook/v1"

    def __init__(self):
        if sys.platform != "win32":
            raise RuntimeError("The webhook is stored with Windows' own encryption: Windows only")
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
            raise RuntimeError("Windows could not read / write the saved webhook (error %d)" % ct.get_last_error())
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
    DEFAULTS = {"webhook": "", "username": "Puppy Admin updates", "color": "Orange", "ping": "none", "role_id": "",
                "last_script_sha": "", "last_companion_sha": ""}

    def __init__(self, folder=None, protector=None):
        self.folder = folder or data_dir()
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

    def webhook(self):
        blob = self.data.get("webhook") or ""
        if not blob or not self.protector:
            return ""
        try:
            return self.protector.unprotect(base64.b64decode(blob)).decode("utf-8")
        except (ValueError, RuntimeError):
            return ""

    def set_webhook(self, url):
        url = (url or "").strip()
        if url and not valid_webhook(url):
            raise ValueError("That is not a Discord webhook URL")
        if url and not self.protector:
            raise RuntimeError("No encryption available here, so the webhook is not saved")
        self.set("webhook", base64.b64encode(self.protector.protect(url.encode("utf-8"))).decode("ascii") if url else "")
