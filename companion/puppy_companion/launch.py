"""Starting Roblox for an account, and letting several Roblox windows run.

Roblox's launch protocol and its single-window lock are Roblox's own and can
change; everything that depends on them is in this file.
"""
import os
import random
import re
import subprocess
import sys
import time
from urllib.parse import quote, urlencode

PLACE_LAUNCHER = "https://assetgame.roblox.com/game/PlaceLauncher.ashx"
ROBLOX_EXE = "RobloxPlayerBeta.exe"
ERROR_ALREADY_EXISTS = 183
# other players that launch Roblox and already manage multiple windows themselves
BOOTSTRAPPERS = ("Fishstrap", "Bloxstrap")


def detect_bootstrapper():
    """What handles roblox-player: links on this PC: (name, command) or (None, reason).

    name is 'Fishstrap', 'Bloxstrap', 'Roblox' or 'unknown'. A roblox-player: launch
    goes through whatever this returns, so Fishstrap/Bloxstrap launches work with no
    change; they also manage multiple windows themselves (see the multi-window setting).
    """
    if sys.platform != "win32":
        return None, "not Windows"
    try:
        import winreg
    except ImportError:
        return None, "no registry access"
    for hive, sub in ((winreg.HKEY_CURRENT_USER, r"Software\Classes\roblox-player\shell\open\command"),
                      (winreg.HKEY_CLASSES_ROOT, r"roblox-player\shell\open\command")):
        try:
            with winreg.OpenKey(hive, sub) as key:
                command = winreg.QueryValueEx(key, "")[0]
        except OSError:
            continue
        low = command.lower()
        for name in BOOTSTRAPPERS:
            if name.lower() in low:
                return name, command
        if "roblox" in low:
            return "Roblox", command
        return "unknown", command
    return None, "no roblox-player handler registered (Roblox is not installed for this user)"

_JOB_ID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
_GAME_LINK = re.compile(r"roblox\.com/(?:[a-z]{2}/)?games/(\d+)", re.IGNORECASE)


def new_tracker_id(rng=random):
    return "%d%d" % (rng.randint(100000, 174999), rng.randint(100000, 899999))


def parse_place(text):
    """A place ID from '1818', a game link, or nothing (None)."""
    text = (text or "").strip()
    if text.isdigit():
        return int(text) or None
    m = _GAME_LINK.search(text)
    if m:
        return int(m.group(1))
    m = re.search(r"[?&]placeId=(\d+)", text)
    return int(m.group(1)) if m else None


def parse_job(text):
    """A server ID (JobId, a GUID) or None."""
    text = (text or "").strip()
    m = re.search(r"[?&]gameInstanceId=([0-9a-fA-F-]{36})", text)
    if m:
        text = m.group(1)
    return text.lower() if _JOB_ID.match(text) else None


def place_launcher_url(tracker, place_id=None, job_id=None, follow_user_id=None):
    if follow_user_id:
        query = {"request": "RequestFollowUser", "browserTrackerId": tracker, "userId": str(int(follow_user_id))}
    elif job_id:
        query = {"request": "RequestGameJob", "browserTrackerId": tracker, "placeId": str(int(place_id)),
                 "gameId": job_id, "isPlayTogetherGame": "false"}
    else:
        query = {"request": "RequestGame", "browserTrackerId": tracker, "placeId": str(int(place_id)),
                 "isPlayTogetherGame": "false"}
    return PLACE_LAUNCHER + "?" + urlencode(query)


def launch_uri(ticket, launcher_url, tracker, launch_time_ms=None):
    if launch_time_ms is None:
        launch_time_ms = int(time.time() * 1000)
    return ("roblox-player:1+launchmode:play+gameinfo:" + ticket
            + "+launchtime:" + str(int(launch_time_ms))
            + "+placelauncherurl:" + quote(launcher_url, safe="")
            + "+browsertrackerid:" + tracker
            + "+robloxLocale:en_us+gameLocale:en_us+channel:+LaunchExp:InApp")


def open_uri(uri):
    """Hands the roblox-player: link to Windows, which starts Roblox (or Bloxstrap)."""
    if sys.platform != "win32":
        raise OSError("Starting Roblox needs Windows.")
    os.startfile(uri)


def close_all_roblox():
    """Ends every Roblox player window. Returns how many processes were ended."""
    if sys.platform != "win32":
        return 0
    r = subprocess.run(["taskkill", "/F", "/IM", ROBLOX_EXE], capture_output=True, text=True,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    return sum(1 for line in (r.stdout or "").splitlines() if line.strip().upper().startswith("SUCCESS"))


class MultiInstance:
    """Roblox closes or refuses a second window while its single-window lock (a named
    mutex / event) belongs to the first one. Creating the lock before any Roblox
    window opens, and keeping it, lets several windows run."""

    def __init__(self):
        self._handles = []
        self.report = []

    def hold(self, names):
        """names: lock names; one with "event" in it is made as an event, the rest as mutexes.
        Returns [(name, kind, state)] with state "held", "busy" (Roblox already had it) or "failed"."""
        self.release()
        self.report = []
        if sys.platform != "win32":
            self.report = [(n, "-", "failed") for n in names]
            return self.report
        import ctypes
        from ctypes import wintypes
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
        kernel32.CreateMutexW.restype = wintypes.HANDLE
        kernel32.CreateEventW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.BOOL, wintypes.LPCWSTR]
        kernel32.CreateEventW.restype = wintypes.HANDLE
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        for name in names:
            kind = "event" if "event" in name.lower() else "mutex"
            ctypes.set_last_error(0)
            if kind == "event":
                handle = kernel32.CreateEventW(None, True, False, name)
            else:
                handle = kernel32.CreateMutexW(None, True, name)
            err = ctypes.get_last_error()
            if not handle:
                self.report.append((name, kind, "failed"))
            elif err == ERROR_ALREADY_EXISTS:
                # Roblox made it first: holding a second handle would not help
                kernel32.CloseHandle(handle)
                self.report.append((name, kind, "busy"))
            else:
                self._handles.append(handle)
                self.report.append((name, kind, "held"))
        return self.report

    def release(self):
        if self._handles and sys.platform == "win32":
            import ctypes
            from ctypes import wintypes
            kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
            for h in self._handles:
                kernel32.CloseHandle(h)
        self._handles = []

    @property
    def held(self):
        return bool(self._handles)
