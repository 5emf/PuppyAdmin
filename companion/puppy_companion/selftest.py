"""PuppyCompanion.exe --selftest [report.txt]

Checks the parts that only work on Windows, inside the built program: login
encryption, the saved-account file, the window lock, the launch link, the
executor-folder files and the window itself. It uses a temporary folder and
made-up names only: no Roblox request is sent and your saved accounts and
Roblox's own lock are never touched. Exit code 0 means every check passed.
"""
import json
import os
import shutil
import sys
import tempfile
import traceback
import uuid

from . import __version__, fonts, launch, workspace
from .secure import ProtectorError, default_protector
from .store import AccountStore, Settings

FAKE_COOKIE = "_|WARNING:-DO-NOT-SHARE-THIS.--SelfTest|_" + "AB12" * 40


class _FakeLock:
    def hold(self, names):
        return [(n, "mutex", "held") for n in names]

    def release(self):
        pass

    held = True


def _no_network(request, timeout):
    raise OSError("the self-test sends no network requests")


def check_dpapi(tmp):
    p = default_protector()
    secret = os.urandom(24) + FAKE_COOKIE.encode()
    blob = p.protect(secret)
    if secret in blob or FAKE_COOKIE.encode() in blob:
        raise AssertionError("the encrypted data still contains the plain text")
    if p.unprotect(blob) != secret:
        raise AssertionError("decrypting gave different bytes")
    broken = bytearray(blob)
    broken[len(broken) // 2] ^= 0x55
    try:
        p.unprotect(bytes(broken))
    except ProtectorError:
        pass
    else:
        raise AssertionError("damaged data was accepted")
    return "%s, %d-byte blob" % (p.name, len(blob))


def check_store(tmp):
    folder = os.path.join(tmp, "store")
    store = AccountStore(default_protector(), folder)
    store.add_or_update(FAKE_COOKIE, {"id": 1, "name": "SelfTestMain", "displayName": "Main"}, "main")
    store.add_or_update(FAKE_COOKIE + "x", {"id": 2, "name": "SelfTestAlt", "displayName": "Alt"}, "alt", "Alt one")
    with open(os.path.join(folder, AccountStore.FILE), "r", encoding="utf-8") as f:
        text = f.read()
    if "WARNING" in text or "AB12AB12" in text:
        raise AssertionError("accounts.json contains a cookie in plain text")
    again = AccountStore(default_protector(), folder)
    if again.cookie(1) != FAKE_COOKIE or again.cookie(2) != FAKE_COOKIE + "x":
        raise AssertionError("a saved cookie did not come back the same")
    if again.main().user_id != 1 or [a.user_id for a in again.alts()] != [2]:
        raise AssertionError("roles did not survive a reload")
    return "2 accounts saved, reloaded and decrypted"


def check_lock(tmp):
    base = "PuppyCompanionSelfTest_" + uuid.uuid4().hex
    names = [base + "_Mutex", base + "_Event"]
    first, second, third = launch.MultiInstance(), launch.MultiInstance(), launch.MultiInstance()
    try:
        a = [s for _, _, s in first.hold(names)]
        b = [s for _, _, s in second.hold(names)]
        first.release()
        c = [s for _, _, s in third.hold(names)]
    finally:
        for m in (first, second, third):
            m.release()
    if a != ["held", "held"] or b != ["busy", "busy"] or c != ["held", "held"]:
        raise AssertionError("expected held/busy/held, got %s / %s / %s" % (a, b, c))
    return "mutex and event: held, seen as busy by a second holder, free again after release"


def check_launch_link(tmp):
    place = launch.parse_place("https://www.roblox.com/games/1818/Classic-Crossroads")
    job = launch.parse_job("1B2C3D4E-0000-4000-8000-00000000ABCD")
    if place != 1818 or job != "1b2c3d4e-0000-4000-8000-00000000abcd":
        raise AssertionError("place / server parsing: %r %r" % (place, job))
    tracker = launch.new_tracker_id()
    uri = launch.launch_uri("TICKET", launch.place_launcher_url(tracker, place, job), tracker, 1)
    want = "roblox-player:1+launchmode:play+gameinfo:TICKET+launchtime:1+placelauncherurl:"
    if not uri.startswith(want) or "RequestGameJob" not in uri or " " in uri:
        raise AssertionError("unexpected link: " + uri[:120])
    return "%d characters" % len(uri)


def roblox_handler():
    """Which program starts roblox-player: links (Fishstrap / Bloxstrap / Roblox)."""
    name, detail = launch.detect_bootstrapper()
    if name:
        return "%s (%s)" % (name, detail)
    return detail


def check_workspace(tmp):
    ws = os.path.join(tmp, "Executor", "workspace")
    os.makedirs(workspace.status_dir(ws))
    import time
    now = time.time()
    with open(os.path.join(workspace.status_dir(ws), "1.json"), "w", encoding="utf-8") as f:
        json.dump({"userId": 1, "name": "SelfTestMain", "placeId": 1818, "online": True,
                   "jobId": "1b2c3d4e-0000-4000-8000-00000000abcd", "time": now}, f)
    st = workspace.read_statuses(ws, now + 1)
    if not st.get(1) or not st[1]["fresh"] or st[1]["placeId"] != 1818:
        raise AssertionError("status file not read back: %r" % (st,))
    store = AccountStore(default_protector(), os.path.join(tmp, "store"))
    path = workspace.write_roster(ws, store)
    with open(path, "r", encoding="utf-8") as f:
        roster = json.load(f)
    if roster["main"]["userId"] != 1 or "WARNING" in json.dumps(roster):
        raise AssertionError("roster.json is wrong")
    auto = workspace.install_autoexec(ws, "print('selftest')", create=True)
    if not os.path.isfile(auto):
        raise AssertionError("auto-execute file missing")
    return "status read, roster written, auto-execute file at ...%s%s" % (os.sep, os.path.relpath(auto, tmp))


def check_window(tmp):
    import tkinter as tk
    from .app import CompanionApp
    root = tk.Tk()
    root.withdraw()
    try:
        folder = os.path.join(tmp, "store")
        store = AccountStore(default_protector(), folder)
        app = CompanionApp(root, store, Settings(folder), multi=_FakeLock(), opener=_no_network,
                           open_uri=lambda uri: None, check_update=False)
        for _ in range(5):
            root.update()
        rows = app.tree.get_children()
        tabs = [app.nb.tab(t, "text") for t in app.nb.tabs()]
        if len(rows) != 2 or tabs != ["Accounts", "Launch", "Manage", "Settings"]:
            raise AssertionError("window content: rows=%r tabs=%r" % (rows, tabs))
        version = root.tk.call("info", "patchlevel")
        app.close()
    except BaseException:
        try:
            root.destroy()
        except tk.TclError:
            pass
        raise
    return "Tk %s, %d accounts listed, tabs %s" % (version, len(rows), ", ".join(tabs))


def check_fonts(tmp):
    files = sorted({f for _, (_, names) in fonts.FONTS.items() for f in names})
    missing = [f for f in files if not os.path.isfile(os.path.join(fonts.FONT_DIR, f))]
    if missing:
        raise AssertionError("font files missing from the program: %s" % ", ".join(missing))
    n = fonts.load_private(files)
    if n != len(files):
        raise AssertionError("only %d of %d fonts loaded" % (n, len(files)))
    return "%d font files loaded for this program" % n


CHECKS = [
    ("login encryption", check_dpapi),
    ("saved accounts", check_store),
    ("window lock", check_lock),
    ("launch link", check_launch_link),
    ("executor folder files", check_workspace),
    ("window", check_window),
    ("fonts", check_fonts),
]


def run(out_path=None):
    lines = ["Puppy Companion %s self-test" % __version__,
             "Python %s, %s" % (sys.version.split()[0], "built program" if getattr(sys, "frozen", False) else "source"),
             "Roblox link handler: %s" % _safe(roblox_handler), ""]
    tmp = tempfile.mkdtemp(prefix="puppy-selftest-")
    failed = 0
    try:
        for name, fn in CHECKS:
            try:
                lines.append("PASS  %s: %s" % (name, fn(tmp)))
            except Exception as e:
                failed += 1
                lines.append("FAIL  %s: %s: %s" % (name, type(e).__name__, e))
                lines.extend("      " + x for x in traceback.format_exc().rstrip().splitlines()[-6:])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    lines.append("")
    lines.append("RESULT: %s (%d of %d checks passed)" % ("PASS" if not failed else "FAIL", len(CHECKS) - failed, len(CHECKS)))
    text = "\n".join(lines) + "\n"
    if out_path:
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(text)
    elif sys.stdout is not None:
        sys.stdout.write(text)
    else:  # windowed program without a console: leave the report next to it
        with open(os.path.join(os.path.dirname(sys.executable), "selftest.txt"), "w", encoding="utf-8") as f:
            f.write(text)
    return 0 if not failed else 1


def _safe(fn):
    try:
        return fn()
    except Exception as e:
        return "unknown (%s)" % e
