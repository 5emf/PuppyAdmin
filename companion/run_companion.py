"""Starts Puppy Companion: python run_companion.py (from source) or PuppyCompanion.exe (built).

PuppyCompanion.exe --selftest report.txt runs the built-in checks instead and
exits with 0 when they all pass.
"""
import sys
import traceback


def _selftest_crash(argv):
    """The built program has no console: a crash during --selftest goes into the report."""
    i = argv.index("--selftest")
    out = argv[i + 1] if len(argv) > i + 1 else "selftest.txt"
    with open(out, "w", encoding="utf-8") as f:
        f.write("RESULT: CRASH\n\n" + traceback.format_exc())
    return 2


if __name__ == "__main__":
    try:
        from puppy_companion.app import main
        code = main()
    except Exception:
        if "--selftest" not in sys.argv:
            raise
        code = _selftest_crash(sys.argv)
    sys.exit(code)
