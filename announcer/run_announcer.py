"""Starts Puppy Announcer: python run_announcer.py (from source) or PuppyAnnouncer.exe (built).

PuppyAnnouncer.exe --selftest report.txt runs the built-in checks instead (payloads, the
encrypted webhook round trip, the window) and exits with 0 when they all pass.
"""
import os
import sys
import tempfile
import traceback


def selftest(report):
    lines, ok = [], True

    def check(name, fn):
        nonlocal ok
        try:
            msg = fn() or ""
            lines.append("PASS  %s %s" % (name, msg))
        except Exception:
            ok = False
            lines.append("FAIL  %s\n%s" % (name, traceback.format_exc()))

    from puppy_announcer import core

    def payloads():
        b = core.build_payload("T", "x", ping="@here", loadstring=True)
        assert b["content"] == "@here" and "loadstring" in b["embeds"][0]["fields"][0]["value"]
        assert core.redact("https://discord.com/api/webhooks/1/abc") == "https://discord.com/api/webhooks/1/***"
    check("payloads", payloads)

    def webhook_storage():
        folder = tempfile.mkdtemp()
        s = core.Settings(folder, core.Dpapi())
        url = "https://discord.com/api/webhooks/123/abc-DEF_9"
        s.set_webhook(url)
        assert core.Settings(folder, core.Dpapi()).webhook() == url
        with open(os.path.join(folder, "settings.json"), encoding="utf-8") as f:
            assert "abc-DEF_9" not in f.read(), "the webhook must not be stored in plain text"
    check("encrypted webhook", webhook_storage)

    def window():
        import tkinter as tk
        from puppy_announcer.app import AnnouncerApp
        root = tk.Tk()
        root.withdraw()
        app = AnnouncerApp(root, core.Settings(tempfile.mkdtemp(), None))
        app.title_var.set("Hello")
        assert app.body()["embeds"][0]["title"] == "Hello"
        app.close()
    check("window", window)

    lines.append("RESULT: %s" % ("PASS" if ok else "FAIL"))
    with open(report, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return 0 if ok else 1


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--selftest":
        sys.exit(selftest(sys.argv[2]))
    from puppy_announcer.app import main
    main()
