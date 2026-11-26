"""Pupdates' own update (the Update button): the Windows build publishes Pupdates.exe and
pupdates-windows.json to the GitHub release "pupdates-windows-latest"; this compares the build
number, downloads the new exe, checks its SHA-256, and swaps it in after Pupdates closes.
"""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

from . import _build

BASE = "https://github.com/5emf/PuppyAdmin/releases/download/pupdates-windows-latest/"
INFO, EXE = "pupdates-windows.json", "Pupdates.exe"


def _get(url, opener=None, limit=200 * 1024 * 1024):
    opener = opener or urllib.request.urlopen
    req = urllib.request.Request(url, headers={"User-Agent": "Pupdates-Update"})
    try:
        with opener(req, timeout=60) as r:
            data = r.read(limit + 1)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise RuntimeError("No Pupdates update is published yet")
        raise RuntimeError("GitHub answered HTTP %d" % e.code)
    except (urllib.error.URLError, OSError) as e:
        raise RuntimeError("Could not connect: %s" % getattr(e, "reason", e))
    if len(data) > limit:
        raise RuntimeError("The download is too large")
    return data


def current():
    return int(getattr(_build, "BUILD", 0) or 0)


def check(opener=None):
    """{'build', 'sha256', 'size', 'newer'} of the published exe."""
    info = json.loads(_get(BASE + INFO, opener, 64 * 1024).decode("utf-8"))
    build = int(info.get("build", 0))
    return {"build": build, "sha256": str(info.get("sha256", "")).lower(), "size": int(info.get("size", 0)),
            "newer": build > current()}


def download(info, folder=None, opener=None):
    """Downloads and checks the new exe; returns its path."""
    data = _get(BASE + EXE, opener)
    if info.get("size") and len(data) != info["size"]:
        raise RuntimeError("The download is incomplete (%d of %d bytes)" % (len(data), info["size"]))
    if hashlib.sha256(data).hexdigest() != info.get("sha256"):
        raise RuntimeError("The download does not match its checksum: not installed")
    folder = folder or tempfile.mkdtemp(prefix="pupdates-update-")
    path = os.path.join(folder, EXE)
    with open(path, "wb") as f:
        f.write(data)
    return path


def swap_script(new_exe, old_exe):
    """A batch file that waits until Pupdates has closed, replaces the exe and starts it again."""
    return ("@echo off\r\n"
            ":wait\r\n"
            "timeout /t 1 /nobreak >nul\r\n"
            'move /y "%s" "%s" >nul 2>&1 || goto wait\r\n'
            'start "" "%s"\r\n'
            'del "%%~f0"\r\n') % (new_exe, old_exe, old_exe)


def can_self_update():
    return sys.platform == "win32" and getattr(sys, "frozen", False)


def install(new_exe):
    """Starts the swap; the caller closes Pupdates right after."""
    if not can_self_update():
        raise RuntimeError("Only the built Pupdates.exe updates itself (from source: git pull)")
    bat = os.path.join(os.path.dirname(new_exe), "pupdates-update.bat")
    with open(bat, "w", encoding="ascii", errors="replace") as f:
        f.write(swap_script(new_exe, sys.executable))
    flags = 0x00000008 | 0x08000000  # DETACHED_PROCESS | CREATE_NO_WINDOW
    subprocess.Popen(["cmd", "/c", bat], creationflags=flags, close_fds=True)
