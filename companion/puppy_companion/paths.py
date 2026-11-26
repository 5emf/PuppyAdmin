"""Where the companion keeps its files."""
import os
import sys

APP_NAME = "PuppyCompanion"


def data_dir():
    """%APPDATA%\\PuppyCompanion on Windows (PUPPY_COMPANION_HOME overrides it)."""
    base = os.environ.get("PUPPY_COMPANION_HOME")
    if not base:
        if sys.platform == "win32":
            base = os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~"), APP_NAME)
        else:
            base = os.path.join(os.path.expanduser("~"), ".puppy_companion")
    os.makedirs(base, exist_ok=True)
    return base
