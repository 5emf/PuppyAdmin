"""Starts Puppy Companion: python run_companion.py (from source) or PuppyCompanion.exe (built).

PuppyCompanion.exe --selftest report.txt runs the built-in checks instead and
exits with 0 when they all pass.

This file is the stable bootstrap and is NOT replaced by the auto-update. Before
importing the app it checks %APPDATA%\\PuppyCompanion\\code for a package the
updater has downloaded and, if it is newer than this build, loads the app from
there. Anything wrong with that folder falls back to the bundled package, so a
bad update can never stop the app from starting.
"""
import importlib.util
import os
import sys
import traceback


def _data_dir():
    base = os.environ.get("PUPPY_COMPANION_HOME")
    if not base:
        if sys.platform == "win32":
            base = os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~"), "PuppyCompanion")
        else:
            base = os.path.join(os.path.expanduser("~"), ".puppy_companion")
    return base


def _version_tuple(text):
    out = []
    for part in str(text).split("."):
        digits = "".join(ch for ch in part if ch.isdigit())
        out.append(int(digits) if digits else 0)
    return tuple(out) or (0,)


def _bundled_version():
    try:
        from puppy_companion import _payload
        return _payload.PAYLOAD_VERSION
    except Exception:
        return "0"


def _activate_update():
    """If a downloaded package is newer than this build, load puppy_companion from it."""
    root = os.path.join(_data_dir(), "code")
    try:
        with open(os.path.join(root, "active.txt"), "r", encoding="utf-8") as f:
            name = f.read().strip()
    except OSError:
        return
    if not name or _version_tuple(name) <= _version_tuple(_bundled_version()):
        return
    pkg_dir = os.path.join(root, name, "puppy_companion")
    init = os.path.join(pkg_dir, "__init__.py")
    if not os.path.isfile(init):
        return
    try:
        # drop the bundled package so the file-system copy wins over the frozen one
        for mod in [m for m in sys.modules if m == "puppy_companion" or m.startswith("puppy_companion.")]:
            del sys.modules[mod]
        spec = importlib.util.spec_from_file_location(
            "puppy_companion", init, submodule_search_locations=[pkg_dir])
        module = importlib.util.module_from_spec(spec)
        sys.modules["puppy_companion"] = module
        spec.loader.exec_module(module)
    except Exception:
        # the downloaded package is unusable: forget it and use the bundled one
        for mod in [m for m in sys.modules if m == "puppy_companion" or m.startswith("puppy_companion.")]:
            del sys.modules[mod]
        try:
            os.remove(os.path.join(root, "active.txt"))
        except OSError:
            pass


def _selftest_crash(argv):
    """The built program has no console: a crash during --selftest goes into the report."""
    i = argv.index("--selftest")
    out = argv[i + 1] if len(argv) > i + 1 else "selftest.txt"
    with open(out, "w", encoding="utf-8") as f:
        f.write("RESULT: CRASH\n\n" + traceback.format_exc())
    return 2


def main():
    _activate_update()
    from puppy_companion.app import main as app_main
    return app_main()


if __name__ == "__main__":
    try:
        code = main()
    except Exception:
        if "--selftest" not in sys.argv:
            raise
        code = _selftest_crash(sys.argv)
    sys.exit(code)
