"""Pull a newer puppy_companion package from GitHub so the exe need not be rebuilt.

Flow: check() reads payload.json from the repo and compares its version with the
running one; download() fetches every listed file into a new version folder under
%APPDATA%\\PuppyCompanion\\code\\<version>, checks each sha256 and that each .py
compiles, then marks it active. run_companion.py loads the active folder next
start (and this one can relaunch to it at once). A half-written or broken folder
is never marked active, so a failed update can never stop the app from starting.
"""
import hashlib
import json
import os
import py_compile
import re
import shutil

import tempfile
import urllib.request

from . import _payload
from .paths import data_dir

CODE_SUBDIR = "code"
ACTIVE_MARKER = "active.txt"
VERSION_MARKER = ".payload-version"
MAX_FILE = 4 * 1024 * 1024  # a source file over this is refused


class UpdateError(Exception):
    pass


def _default_opener(request, timeout):
    return urllib.request.urlopen(request, timeout=timeout)


def _get(url, opener, timeout=20):
    request = urllib.request.Request(url, headers={
        "User-Agent": "PuppyCompanion", "Accept": "*/*", "Cache-Control": "no-cache"})
    try:
        with opener(request, timeout) as response:
            if getattr(response, "status", 200) not in (200, None):
                raise UpdateError("GitHub answered %s for %s" % (response.status, url))
            data = response.read(MAX_FILE + 1)
    except UpdateError:
        raise
    except Exception as e:
        raise UpdateError("could not fetch %s (%s)" % (url.rsplit("/", 1)[-1], e))
    if len(data) > MAX_FILE:
        raise UpdateError("%s is larger than expected" % url.rsplit("/", 1)[-1])
    return data


_SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def resolve_ref(opener=None):
    """The commit the branch points at now, or None (then the branch name is used).
    raw.githubusercontent.com caches each branch file for minutes, so right after a
    push payload.json and the files it lists can come from different commits. Reading
    everything from one commit SHA keeps the set consistent."""
    opener = opener or _default_opener
    url = "https://api.github.com/repos/%s/%s/commits/%s" % (
        _payload.REPO_OWNER, _payload.REPO_NAME, _payload.REPO_BRANCH)
    request = urllib.request.Request(url, headers={
        "User-Agent": "PuppyCompanion", "Accept": "application/vnd.github.sha"})
    try:
        with opener(request, 15) as response:
            text = response.read(4096).decode("ascii", "replace").strip()
    except Exception:
        return None
    if not _SHA_RE.match(text):
        try:
            text = str(json.loads(text).get("sha", ""))
        except (ValueError, AttributeError):
            return None
    return text if _SHA_RE.match(text) else None


def _raw(ref, rel):
    """rel is relative to the repository root."""
    if not ref:
        return _payload.raw_base() + rel
    return "https://raw.githubusercontent.com/%s/%s/%s/%s" % (
        _payload.REPO_OWNER, _payload.REPO_NAME, ref, rel)


def _manifest_url(ref):
    return _raw(ref, _payload.COMPANION_SUBDIR + "/" + _payload.MANIFEST_NAME) if ref else _payload.manifest_url()


def _file_url(ref, rel):
    return _raw(ref, _payload.COMPANION_SUBDIR + "/" + rel.replace("\\", "/")) if ref else _payload.file_url(rel)


def code_root():
    return os.path.join(data_dir(), CODE_SUBDIR)


def installed_version():
    """The version run_companion.py would load next start, or None."""
    try:
        with open(os.path.join(code_root(), ACTIVE_MARKER), "r", encoding="utf-8") as f:
            name = f.read().strip()
    except OSError:
        return None
    pkg = os.path.join(code_root(), name, "puppy_companion", "__init__.py")
    return name if name and os.path.isfile(pkg) else None


def running_version():
    """The version actually running now (an applied update, else this build's)."""
    base = version_from(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    return base or _payload.PAYLOAD_VERSION


def version_from(pkg_parent):
    marker = os.path.join(pkg_parent, VERSION_MARKER)
    try:
        with open(marker, "r", encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return None


def _newest_known():
    """Highest version we ship or have already downloaded."""
    best = _payload.PAYLOAD_VERSION
    inst = installed_version()
    if inst and _payload.version_tuple(inst) > _payload.version_tuple(best):
        best = inst
    return best


def _valid_manifest(m):
    if not isinstance(m, dict) or not isinstance(m.get("version"), str):
        raise UpdateError("payload.json is not in the expected shape")
    files = m.get("files")
    if not isinstance(files, list) or not files:
        raise UpdateError("payload.json lists no files")
    for entry in files:
        if (not isinstance(entry, dict) or not isinstance(entry.get("path"), str)
                or not isinstance(entry.get("sha256"), str)):
            raise UpdateError("payload.json has a malformed entry")
        p = entry["path"].replace("\\", "/")
        if not p.startswith("puppy_companion/") or ".." in p or p.startswith("/"):
            raise UpdateError("payload.json points outside the package: %s" % p)
    return m


def check(opener=None):
    """Returns the manifest dict if the repo has a newer package, else None."""
    opener = opener or _default_opener
    ref = resolve_ref(opener)
    raw = _get(_manifest_url(ref), opener)
    try:
        manifest = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise UpdateError("payload.json could not be read")
    _valid_manifest(manifest)
    if _payload.version_tuple(manifest["version"]) <= _payload.version_tuple(_newest_known()):
        return None
    if ref:
        manifest["_ref"] = ref  # download() reads the files from this same commit
    return manifest


def download(manifest, opener=None, progress=None):
    """Fetches every file into a fresh version folder, verifies it, marks it active.
    Returns the applied version string. Raises UpdateError and leaves nothing active
    on any problem."""
    opener = opener or _default_opener
    _valid_manifest(manifest)
    version = manifest["version"]
    ref = manifest.get("_ref") if _SHA_RE.match(str(manifest.get("_ref") or "")) else None
    root = code_root()
    os.makedirs(root, exist_ok=True)
    staging = tempfile.mkdtemp(prefix=".dl-", dir=root)
    try:
        files = manifest["files"]
        for i, entry in enumerate(files):
            rel = entry["path"].replace("\\", "/")
            if progress:
                progress(i, len(files), rel)
            data = _get(_file_url(ref, rel), opener)
            got = hashlib.sha256(data).hexdigest()
            if got != entry["sha256"].lower():
                raise UpdateError("%s did not match its checksum (download corrupted)" % rel)
            dest = os.path.join(staging, *rel.split("/"))
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as f:
                f.write(data)
            if rel.endswith(".py"):
                try:
                    py_compile.compile(dest, doraise=True)
                except py_compile.PyCompileError as e:
                    raise UpdateError("%s did not compile, update refused (%s)" % (rel, e))
        init = os.path.join(staging, "puppy_companion", "__init__.py")
        if not os.path.isfile(init):
            raise UpdateError("the downloaded package has no __init__.py")
        with open(os.path.join(staging, VERSION_MARKER), "w", encoding="utf-8") as f:
            f.write(version)
        final = os.path.join(root, version)
        if os.path.isdir(final):
            shutil.rmtree(final, ignore_errors=True)
        os.replace(staging, final)
        staging = None
        with open(os.path.join(root, ACTIVE_MARKER), "w", encoding="utf-8") as f:
            f.write(version)
        _prune(root, keep=version)
        return version
    finally:
        if staging and os.path.isdir(staging):
            shutil.rmtree(staging, ignore_errors=True)


def _prune(root, keep):
    """Keep the active folder and this build; drop older downloads."""
    try:
        names = os.listdir(root)
    except OSError:
        return
    for name in names:
        full = os.path.join(root, name)
        if name in (keep, ACTIVE_MARKER) or not os.path.isdir(full):
            continue
        if _payload.version_tuple(name) <= _payload.version_tuple(_payload.PAYLOAD_VERSION):
            shutil.rmtree(full, ignore_errors=True)


def clear_active():
    """Fall back to the bundled package (used if loading an update failed)."""
    try:
        os.remove(os.path.join(code_root(), ACTIVE_MARKER))
    except OSError:
        pass


# --- Puppy Admin (the in-game script) -----------------------------------------
# The companion only updates its own code; Puppy Admin updates itself whenever it is
# (re-)executed. These let the companion show the latest script build and which
# windows still run an older one.
SCRIPT_PATH = "PuppyAdmin.lua"
_BUILD_RE = re.compile(r'SCRIPT_BUILD\s*=\s*"([^"]+)"')


def build_tuple(build):
    """'2026.11.24-50' -> (2026, 11, 24, 50); compares builds correctly."""
    return tuple(int(x) for x in re.findall(r"\d+", str(build or ""))) or (0,)


def latest_script_build(opener=None):
    """The SCRIPT_BUILD of PuppyAdmin.lua on GitHub (reads only the first few KB)."""
    opener = opener or _default_opener
    request = urllib.request.Request(_raw(resolve_ref(opener), SCRIPT_PATH), headers={
        "User-Agent": "PuppyCompanion", "Range": "bytes=0-8191", "Cache-Control": "no-cache"})
    try:
        with opener(request, 20) as response:
            head = response.read(16384).decode("utf-8", "replace")
    except Exception as e:
        raise UpdateError("could not read Puppy Admin's version (%s)" % e)
    m = _BUILD_RE.search(head)
    return m.group(1) if m else None

