"""Puppy Admin's shared tags (tags.json on the repository's main branch), read and written the same
way Puppy Admin's TagSync does: anyone can read; writing needs a GitHub token with Contents: read
and write on the repository. Tags are cleaned with the same limits as TagSync.sanitize, so what
the app saves is exactly what Puppy Admin accepts.
"""
import base64
import json
import urllib.error
import urllib.parse
import urllib.request

OWNER, REPO, BRANCH, PATH = "5emf", "PuppyAdmin", "main", "tags.json"
FONTS = ("GothamBold", "Gotham", "GothamSemibold", "Code", "Arcade", "SourceSansBold", "FredokaOne", "Bangers", "SciFi", "Fantasy")
PFP_MODES = ("none", "avatar", "custom")
MAX_TAGS, MAX_MEMBERS = 200, 500
API = "https://api.github.com/repos/%s/%s/contents/%s" % (OWNER, REPO, PATH)
# Roblox user lookups (from memory, not checked against Roblox's docs here)
ROBLOX_BY_NAME = "https://users.roblox.com/v1/usernames/users"
ROBLOX_BY_ID = "https://users.roblox.com/v1/users"


def _s(v, n, default=""):
    return v[:n] if isinstance(v, str) else default


def _num(v, lo, hi, default):
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v:
        return default
    return max(lo, min(hi, v))


def _rgb(v, default):
    if isinstance(v, list) and len(v) >= 3 and all(isinstance(x, (int, float)) and not isinstance(x, bool) for x in v[:3]):
        return [int(max(0, min(255, x))) for x in v[:3]]
    return list(default)


def new_tag(name="New tag"):
    return clean_tag({"name": name, "text": name})


def clean_tag(d, allow_default=True):
    bd = d.get("backdrop") if isinstance(d.get("backdrop"), dict) else {}
    pf = d.get("pfp") if isinstance(d.get("pfp"), dict) else {}
    members = []
    for m in (d.get("members") if isinstance(d.get("members"), list) else [])[:MAX_MEMBERS]:
        m = str(m)
        if m.isdigit() and len(m) <= 20 and m not in members:
            members.append(m)
    text = _s(d.get("text"), 40)
    name = _s(d.get("name"), 30) or text or "Tag"
    out = {
        "name": name, "text": text, "sub": _s(d.get("sub"), 40),
        "color": _rgb(d.get("color"), (255, 255, 255)), "rainbow": d.get("rainbow") is True,
        "size": _num(d.get("size"), 8, 48, 22), "offset": _num(d.get("offset"), 0, 12, 3),
        "font": _s(d.get("font"), 40) or "GothamBold",
        "backdrop": {
            "on": bd.get("on") is True, "color": _rgb(bd.get("color"), (18, 18, 22)),
            "transparency": _num(bd.get("transparency"), 0, 1, 0.35), "image": _s(bd.get("image"), 300),
            "imageTransparency": _num(bd.get("imageTransparency"), 0, 1, 0.15), "round": bd.get("round") is not False,
        },
        "pfp": {
            "mode": pf.get("mode") if pf.get("mode") in ("avatar", "custom") else "none",
            "image": _s(pf.get("image"), 300), "round": pf.get("round") is not False,
        },
        "members": members,
    }
    if allow_default and d.get("isDefault") is True:
        out["isDefault"] = True
    return out


def sanitize(lst):
    """The tag list as Puppy Admin keeps it (TagSync.sanitize): at most 200, one default tag."""
    if not isinstance(lst, list):
        raise ValueError("tags.json is not a list")
    out, have_default = [], False
    for d in lst[:MAX_TAGS]:
        if not isinstance(d, dict) or not isinstance(d.get("name"), str):
            continue
        if d.get("isDefault") is True:
            if have_default:
                continue
            have_default = True
        out.append(clean_tag(d))
    return out


def owner_of(tags, user_id):
    """The (non-default) tag a user id already wears, or None: Puppy Admin shows one tag per user."""
    for t in tags:
        if not t.get("isDefault") and str(user_id) in t["members"]:
            return t
    return None


def hex_color(rgb):
    return "#%02x%02x%02x" % tuple(rgb)


def parse_hex(text):
    t = (text or "").strip().lstrip("#")
    if len(t) != 6 or any(c not in "0123456789abcdefABCDEF" for c in t):
        raise ValueError("Colours are 6 hex digits, like #f59b28")
    return [int(t[i:i + 2], 16) for i in (0, 2, 4)]


# ------------------------------------------------------------------ GitHub
def _req(url, token=None, method="GET", body=None):
    h = {"User-Agent": "Pupdates-Tags", "Accept": "application/vnd.github+json"}
    if token:
        h["Authorization"] = "Bearer " + token
    if body is not None:
        h["Content-Type"] = "application/json"
        body = json.dumps(body).encode("utf-8")
    return urllib.request.Request(url, data=body, method=method, headers=h)


def _open(req, opener):
    opener = opener or urllib.request.urlopen
    try:
        with opener(req, timeout=30) as r:
            return r.status if hasattr(r, "status") else 200, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read() if hasattr(e, "read") else b""
    except (urllib.error.URLError, OSError) as e:
        raise RuntimeError("Could not connect: %s" % getattr(e, "reason", e))


def load(token=None, opener=None):
    """(tags, sha) from the repository."""
    code, raw = _open(_req(API + "?ref=" + BRANCH, token), opener)
    if code == 404:
        return [], None
    if code in (401, 403) and token:
        raise RuntimeError("GitHub refused the token (%d)" % code)
    if code == 403:
        raise RuntimeError("GitHub's limit for reads without a token was reached: try again later or save a token")
    if code != 200:
        raise RuntimeError("GitHub answered HTTP %d" % code)
    info = json.loads(raw.decode("utf-8"))
    text = base64.b64decode(info.get("content", "")).decode("utf-8")
    return sanitize(json.loads(text) if text.strip() else []), info.get("sha")


def encode(tags):
    return json.dumps(sanitize(tags), separators=(",", ":"))


def save(tags, sha, token, message="Pupdates: update tags", opener=None):
    """Writes the list. Returns the new sha. A change made elsewhere since the load raises (load again)."""
    if not token:
        raise RuntimeError("Saving tags needs a GitHub token (Contents: read and write on %s/%s)" % (OWNER, REPO))
    body = {"message": message, "content": base64.b64encode(encode(tags).encode("utf-8")).decode("ascii"), "branch": BRANCH}
    if sha:
        body["sha"] = sha
    code, raw = _open(_req(API, token, "PUT", body), opener)
    if code in (200, 201):
        return json.loads(raw.decode("utf-8")).get("content", {}).get("sha")
    if code in (401, 403):
        raise RuntimeError("GitHub refused the token (%d): it needs Contents: read and write on %s/%s" % (code, OWNER, REPO))
    if code in (409, 422):
        raise RuntimeError("The tags changed somewhere else since you loaded them: press Load, then make your change again")
    raise RuntimeError("GitHub answered HTTP %d" % code)


# ------------------------------------------------------------------ Roblox users
def _post_json(url, body, opener):
    req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"), method="POST",
                                 headers={"Content-Type": "application/json", "Accept": "application/json",
                                          "User-Agent": "Pupdates-Tags"})
    code, raw = _open(req, opener)
    if code != 200:
        raise RuntimeError("Roblox answered HTTP %d" % code)
    return json.loads(raw.decode("utf-8")).get("data") or []


def user_id(text, opener=None):
    """A user id from a number or a username. Returns (id, name)."""
    t = (text or "").strip()
    if t.isdigit() and len(t) <= 20:
        return t, None
    if not t:
        raise ValueError("Type a username or a user id")
    found = _post_json(ROBLOX_BY_NAME, {"usernames": [t], "excludeBannedUsers": False}, opener)
    if not found:
        raise RuntimeError("No Roblox user called %s" % t)
    return str(found[0]["id"]), found[0].get("name") or t


def user_names(ids, opener=None):
    """{id: name} for display (best effort: empty when Roblox cannot be reached)."""
    ids = [int(i) for i in ids if str(i).isdigit()][:100]
    if not ids:
        return {}
    try:
        return {str(u["id"]): u.get("name", "") for u in _post_json(ROBLOX_BY_ID, {"userIds": ids, "excludeBannedUsers": False}, opener)}
    except (RuntimeError, ValueError, KeyError):
        return {}
