"""Starts Pupdates: python run_pupdates.py (from source) or Pupdates.exe (built).

Pupdates.exe --selftest report.txt runs the built-in checks instead (payloads, the picture
upload, the encrypted settings, the window) and exits with 0 when they all pass.
"""
import os
import sys
import tempfile
import traceback

PNG = (b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89"
       b"\x00\x00\x00\rIDATx\x9cc\xf8:[\xe3?\x00\x06\xf9\x02\xb8\x1d\xbd\xf0K\x00\x00\x00\x00IEND\xaeB`\x82")


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

    from pupdates_app import core

    def payloads():
        b = core.build_payload("T", "x", ping="@here", loadstring=True, image_name="pupdates.png")
        assert b["content"] == "@here" and "loadstring" in b["embeds"][0]["fields"][0]["value"]
        assert b["embeds"][0]["image"]["url"] == "attachment://pupdates.png"
        assert core.build_payload("", "hi", embed=False)["content"] == "hi"
        assert core.redact("https://discord.com/api/webhooks/1/abc") == "https://discord.com/api/webhooks/1/***"
    check("payloads", payloads)

    def picture():
        folder = tempfile.mkdtemp()
        path = os.path.join(folder, "p.png")
        with open(path, "wb") as f:
            f.write(PNG)
        img = core.load_image(path)
        body, ctype = core.multipart([("payload_json", "{}")], [("files[0]", img["name"], img["mime"], img["data"])])
        assert ctype.startswith("multipart/form-data; boundary=") and PNG in body
    check("picture upload", picture)

    def secrets():
        folder = tempfile.mkdtemp()
        s = core.Settings(folder, core.Dpapi())
        url = "https://discord.com/api/webhooks/123/abc-DEF_9"
        s.set_webhook(url)
        s.set_secret("relay_key", "pup_secretkey123")
        again = core.Settings(folder, core.Dpapi())
        assert again.webhook() == url and again.secret("relay_key") == "pup_secretkey123"
        with open(os.path.join(folder, "settings.json"), encoding="utf-8") as f:
            text = f.read()
        assert "abc-DEF_9" not in text and "pup_secretkey123" not in text, "secrets must not be stored in plain text"
    check("encrypted settings", secrets)

    def tag_preview():
        from pupdates_app import tagpreview, tags
        assert tagpreview.available(), "Pillow is not in the exe"
        assert tagpreview.font_dir(), "the tag fonts are not in the exe"
        for name in tags.FONTS:
            assert tagpreview.font_entry(name)[0], "font file missing for " + name
        d = tags.clean_tag({"name": "T", "text": "Puppy Admin", "sub": "Script Owner", "rainbow": True,
                            "backdrop": {"on": True}, "pfp": {"mode": "avatar"}})
        img, shown = tagpreview.scene(d, None, None, True, 1.0, 400)
        assert img.width == 400 and img.height >= 60
        return "(%d fonts)" % len(tags.FONTS)
    check("tag preview", tag_preview)

    def window():
        import tkinter as tk
        from pupdates_app.app import PupdatesApp
        root = tk.Tk()
        root.withdraw()
        app = PupdatesApp(root, core.Settings(tempfile.mkdtemp(), None), floating=False)
        app.title_var.set("Hello")
        assert app.body()["embeds"][0]["title"] == "Hello"
        for name in ("updates", "whitelist", "settings", "compose"):
            app.show(name)
        app.close()
    check("window", window)

    lines.append("RESULT: %s" % ("PASS" if ok else "FAIL"))
    with open(report, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return 0 if ok else 1


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--selftest":
        sys.exit(selftest(sys.argv[2]))
    from pupdates_app.app import main
    main()
