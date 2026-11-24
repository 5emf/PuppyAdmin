"""The executor's workspace folder, shared with Puppy Admin running in each Roblox window.

Puppy Admin writes PuppyAdmin/companion/<UserId>.json every 10 s (who, which
game and server). The companion writes PuppyAdmin/companion/roster.json (which
accounts are the main and the alts: names and user IDs only, never cookies).
"""
import glob
import json
import os
import sys
import time

from .store import atomic_write

FRESH_SECONDS = 35
AUTOEXEC_NAMES = ("autoexec", "autoexecute", "auto-execute", "auto_exec", "autorun")


def status_dir(ws):
    return os.path.join(ws, "PuppyAdmin", "companion")


def read_statuses(ws, now=None):
    """{user_id: {"name", "placeId", "jobId", "online", "fresh", "time", "build", "privateServer"}}"""
    out = {}
    if not ws:
        return out
    now = time.time() if now is None else now
    for path in glob.glob(os.path.join(status_dir(ws), "*.json")):
        stem = os.path.splitext(os.path.basename(path))[0]
        if not stem.isdigit():
            continue
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
            uid = int(data.get("userId") or stem)
            t = float(data.get("time") or 0)
        except (OSError, ValueError, TypeError, AttributeError):
            continue
        out[uid] = {
            "name": str(data.get("name") or ""),
            "placeId": int(data.get("placeId") or 0),
            "jobId": str(data.get("jobId") or ""),
            "online": data.get("online") is not False,
            "privateServer": data.get("privateServer") is True,
            "build": str(data.get("build") or ""),
            "time": t,
            "fresh": now - t <= FRESH_SECONDS,
        }
    return out


def write_roster(ws, store):
    if not ws or not os.path.isdir(ws):
        return None
    main = store.main()
    data = {
        "updated": int(time.time()),
        "main": {"userId": main.user_id, "name": main.name} if main else None,
        "alts": [{"userId": a.user_id, "name": a.name} for a in store.alts()],
    }
    path = os.path.join(status_dir(ws), "roster.json")
    atomic_write(path, json.dumps(data, indent=2))
    return path


def autoexec_dir(ws):
    """The executor's auto-execute folder next to its workspace (existing one, or "autoexec")."""
    parent = os.path.dirname(os.path.normpath(ws))
    try:
        for name in os.listdir(parent):
            if name.lower() in AUTOEXEC_NAMES and os.path.isdir(os.path.join(parent, name)):
                return os.path.join(parent, name)
    except OSError:
        pass
    return os.path.join(parent, "autoexec")


def install_autoexec(ws, loader_text, create=False):
    folder = autoexec_dir(ws)
    if not os.path.isdir(folder):
        if not create:
            raise FileNotFoundError(folder)
        os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, "PuppyAdmin.lua")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(loader_text.strip() + "\n")
    return path


def _roots():
    home = os.path.expanduser("~")
    roots = []
    if sys.platform == "win32":
        for var in ("LOCALAPPDATA", "APPDATA"):
            if os.environ.get(var):
                roots.append(os.environ[var])
    for sub in ("Desktop", "Downloads", "Documents", os.path.join("OneDrive", "Desktop")):
        roots.append(os.path.join(home, sub))
    return [r for r in roots if os.path.isdir(r)]


def find_candidates(roots=None, depth=2, limit=400):
    """Workspace folders that already hold a PuppyAdmin folder, newest first."""
    found = []
    seen = 0
    for root in (roots if roots is not None else _roots()):
        stack = [(root, 0)]
        while stack:
            folder, level = stack.pop()
            try:
                names = os.listdir(folder)
            except OSError:
                continue
            for name in names:
                seen += 1
                if seen > limit * 50:
                    break
                path = os.path.join(folder, name)
                if not os.path.isdir(path):
                    continue
                if name.lower() == "workspace" and os.path.isdir(os.path.join(path, "PuppyAdmin")):
                    found.append(path)
                elif level < depth and not name.startswith("."):
                    stack.append((path, level + 1))
    found = sorted(set(found), key=lambda p: os.path.getmtime(os.path.join(p, "PuppyAdmin")), reverse=True)
    return found[:limit]
