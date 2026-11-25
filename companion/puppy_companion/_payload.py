"""Where the updatable code lives and which version this build ships with.

The exe (the Python runtime, Tk, the bootloader) is the heavy part and rarely
changes. The puppy_companion package is small and is what actually changes, so
the app can pull a newer copy of it from GitHub into %APPDATA%\\PuppyCompanion
and load that next start, with no new exe. _payload.py and run_companion.py are
the only files the updater does not replace, so keep them small and stable.
"""

# Bumped whenever the package changes. make_payload.py writes it into payload.json.
PAYLOAD_VERSION = "1.6.3"

# The repository the update is pulled from (raw files over HTTPS, same trust model
# as the Lua loadstring). Point these at your fork/branch if you run your own.
REPO_OWNER = "5emf"
REPO_NAME = "PuppyAdmin"
REPO_BRANCH = "ccr-3b4dfcff-nyfy0w"

# payload.json and the package files live under companion/ in the repository.
COMPANION_SUBDIR = "companion"
MANIFEST_NAME = "payload.json"


def raw_base():
    return "https://raw.githubusercontent.com/%s/%s/%s/" % (REPO_OWNER, REPO_NAME, REPO_BRANCH)


def manifest_url():
    return raw_base() + COMPANION_SUBDIR + "/" + MANIFEST_NAME


def file_url(rel_path):
    """rel_path is relative to companion/, e.g. 'puppy_companion/app.py'."""
    return raw_base() + COMPANION_SUBDIR + "/" + rel_path.replace("\\", "/")


def version_tuple(text):
    """'1.10.2' -> (1, 10, 2); unparsable parts become 0 so a bad string never wins."""
    out = []
    for part in str(text).split("."):
        digits = "".join(ch for ch in part if ch.isdigit())
        out.append(int(digits) if digits else 0)
    return tuple(out) or (0,)
