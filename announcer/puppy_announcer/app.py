"""The Puppy Announcer window: write an announcement and post it to your Discord channel."""
import queue
import sys
import threading
import tkinter as tk
from tkinter import messagebox, ttk

from . import core

BG, CARD, FIELD, LINE = "#14151a", "#1c1d24", "#262731", "#32333f"
FG, DIM, ACCENT, GOOD, BAD = "#e9e9ee", "#9b9ca8", "#f59b28", "#6fdc8c", "#ff7a7a"


def style(root):
    s = ttk.Style(root)
    try:
        s.theme_use("clam")
    except tk.TclError:
        pass
    family = "Segoe UI" if sys.platform == "win32" else "DejaVu Sans"
    root.configure(bg=BG)
    s.configure(".", background=BG, foreground=FG, fieldbackground=FIELD, bordercolor=LINE, font=(family, 10),
                lightcolor=CARD, darkcolor=CARD, insertcolor=FG, selectbackground=ACCENT)
    s.configure("TLabel", background=BG, foreground=FG)
    s.configure("Dim.TLabel", foreground=DIM)
    s.configure("Good.TLabel", foreground=GOOD)
    s.configure("Bad.TLabel", foreground=BAD)
    s.configure("Title.TLabel", font=(family, 15, "bold"))
    s.configure("TButton", background=FIELD, foreground=FG, padding=(10, 5), focusthickness=0)
    s.map("TButton", background=[("active", LINE), ("disabled", CARD)], foreground=[("disabled", DIM)])
    s.configure("Accent.TButton", background=ACCENT, foreground="#14151a")
    s.map("Accent.TButton", background=[("active", "#ffb24d"), ("disabled", CARD)])
    s.configure("TEntry", fieldbackground=FIELD, foreground=FG, padding=5)
    s.configure("TCombobox", fieldbackground=FIELD, background=FIELD, foreground=FG, arrowcolor=FG)
    s.map("TCombobox", fieldbackground=[("readonly", FIELD)], foreground=[("readonly", FG)])
    s.configure("TCheckbutton", background=BG, foreground=FG, indicatorbackground=FIELD, indicatorforeground=ACCENT)
    s.map("TCheckbutton", background=[("active", BG)])
    root.option_add("*TCombobox*Listbox.background", CARD)
    root.option_add("*TCombobox*Listbox.foreground", FG)
    return family


class AnnouncerApp:
    def __init__(self, root, settings, opener=None, gh_opener=None):
        self.root, self.settings = root, settings
        self.opener, self.gh_opener = opener, gh_opener
        self.ui = queue.Queue()
        self.info = None       # latest GitHub info, after a template fill
        self.template = None   # "script" / "companion" when the text came from a template
        family = style(root)
        root.title("Puppy Announcer")
        root.geometry("640x660")
        root.minsize(560, 600)
        pad = {"padx": 16}

        top = ttk.Frame(root)
        top.pack(fill="x", pady=(14, 6), **pad)
        ttk.Label(top, text="Puppy Announcer", style="Title.TLabel").pack(side="left")
        ttk.Label(top, text="posts to your Discord channel", style="Dim.TLabel").pack(side="left", padx=10, pady=(6, 0))

        # webhook
        wh = ttk.Frame(root)
        wh.pack(fill="x", pady=4, **pad)
        ttk.Label(wh, text="Webhook").pack(side="left")
        self.webhook_var = tk.StringVar()
        self.webhook_entry = ttk.Entry(wh, textvariable=self.webhook_var, show="•")
        self.webhook_entry.pack(side="left", fill="x", expand=True, padx=8)
        ttk.Button(wh, text="Save", command=self.save_webhook).pack(side="left")
        self.webhook_lbl = ttk.Label(root, style="Dim.TLabel", text="", wraplength=600)
        self.webhook_lbl.pack(anchor="w", **pad)
        self.update_webhook_label()

        # quick fills
        qf = ttk.Frame(root)
        qf.pack(fill="x", pady=(10, 4), **pad)
        ttk.Label(qf, text="Fill in").pack(side="left")
        self.fill_script_btn = ttk.Button(qf, text="Puppy Admin update", command=lambda: self.fill("script"))
        self.fill_script_btn.pack(side="left", padx=(8, 4))
        self.fill_comp_btn = ttk.Button(qf, text="Companion update", command=lambda: self.fill("companion"))
        self.fill_comp_btn.pack(side="left", padx=4)
        ttk.Button(qf, text="Clear", command=self.clear).pack(side="left", padx=4)

        # title + message
        ttk.Label(root, text="Title").pack(anchor="w", pady=(8, 2), **pad)
        self.title_var = tk.StringVar()
        ttk.Entry(root, textvariable=self.title_var).pack(fill="x", **pad)
        ttk.Label(root, text="Message").pack(anchor="w", pady=(8, 2), **pad)
        self.message = tk.Text(root, height=12, wrap="word", bg=FIELD, fg=FG, insertbackground=FG, relief="flat",
                               font=(family, 10), padx=8, pady=6, highlightthickness=1, highlightbackground=LINE)
        self.message.pack(fill="both", expand=True, **pad)

        # options
        op = ttk.Frame(root)
        op.pack(fill="x", pady=(8, 2), **pad)
        ttk.Label(op, text="Colour").pack(side="left")
        self.color_var = tk.StringVar(value=settings.get("color") if settings.get("color") in core.COLORS else "Orange")
        ttk.Combobox(op, textvariable=self.color_var, values=list(core.COLORS), state="readonly", width=8).pack(side="left", padx=(6, 14))
        ttk.Label(op, text="Ping").pack(side="left")
        self.ping_var = tk.StringVar(value=settings.get("ping") if settings.get("ping") in core.PINGS else "none")
        ttk.Combobox(op, textvariable=self.ping_var, values=list(core.PINGS), state="readonly", width=10).pack(side="left", padx=(6, 6))
        ttk.Label(op, text="role id").pack(side="left")
        self.role_var = tk.StringVar(value=settings.get("role_id"))
        ttk.Entry(op, textvariable=self.role_var, width=20).pack(side="left", padx=6)
        op2 = ttk.Frame(root)
        op2.pack(fill="x", pady=2, **pad)
        self.loadstring_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(op2, text="Add the Puppy Admin loadstring", variable=self.loadstring_var).pack(side="left")
        ttk.Label(op2, text="Name").pack(side="left", padx=(16, 4))
        self.username_var = tk.StringVar(value=settings.get("username"))
        ttk.Entry(op2, textvariable=self.username_var, width=22).pack(side="left")

        # actions
        act = ttk.Frame(root)
        act.pack(fill="x", pady=(10, 4), **pad)
        ttk.Button(act, text="Preview", command=self.preview).pack(side="left")
        self.post_btn = ttk.Button(act, text="Post to Discord", style="Accent.TButton", command=self.post)
        self.post_btn.pack(side="right")
        self.status = ttk.Label(root, style="Dim.TLabel", text="Write an announcement, or fill one in from GitHub.", wraplength=600)
        self.status.pack(anchor="w", pady=(4, 14), **pad)
        self._after = root.after(100, self._tick)

    # ------------------------------------------------------------------ helpers
    def say(self, text, kind="Dim"):
        self.status.configure(text=text, style=kind + ".TLabel")

    def update_webhook_label(self):
        has = bool(self.settings.webhook())
        self.webhook_lbl.configure(text="A webhook is saved (encrypted for this Windows user). Paste a new one to replace it."
                                   if has else "Paste your channel's webhook URL and press Save (it is stored encrypted, never shown again).")

    def run_bg(self, work, done):
        def runner():
            try:
                res, err = work(), None
            except Exception as e:  # shown in the window
                res, err = None, core.redact(e)
            self.ui.put((done, res, err))
        threading.Thread(target=runner, daemon=True).start()

    def _tick(self):
        try:
            while True:
                done, res, err = self.ui.get_nowait()
                done(res, err)
        except queue.Empty:
            pass
        self._after = self.root.after(100, self._tick)

    def body(self):
        return core.build_payload(self.title_var.get(), self.message.get("1.0", "end"), self.color_var.get(),
                                  self.ping_var.get(), self.role_var.get(), self.loadstring_var.get(), self.username_var.get())

    # ------------------------------------------------------------------ actions
    def save_webhook(self):
        url = self.webhook_var.get().strip()
        try:
            self.settings.set_webhook(url)
        except (ValueError, RuntimeError) as e:
            self.say(str(e), "Bad")
            return False
        self.webhook_var.set("")
        self.update_webhook_label()
        self.say("Webhook saved." if url else "Webhook removed.", "Good")
        return True

    def clear(self):
        self.title_var.set("")
        self.message.delete("1.0", "end")
        self.template = None

    def fill(self, which):
        self.say("Reading the latest build from GitHub...")
        for b in (self.fill_script_btn, self.fill_comp_btn):
            b.state(["disabled"])

        def done(info, err):
            for b in (self.fill_script_btn, self.fill_comp_btn):
                b.state(["!disabled"])
            if err:
                self.say(err, "Bad")
                return
            self.info = info
            key = "last_script_sha" if which == "script" else "last_companion_sha"
            maker = core.script_template if which == "script" else core.companion_template
            title, text = maker(info, self.settings.get(key) or None)
            self.title_var.set(title)
            self.message.delete("1.0", "end")
            self.message.insert("1.0", text)
            self.template = which
            self.color_var.set("Orange" if which == "script" else "Blue")
            self.loadstring_var.set(which == "script")
            self.say("Filled in from GitHub (changes since your last %s announcement). Edit it, then post." %
                     ("Puppy Admin" if which == "script" else "companion"))
        self.run_bg(lambda: core.latest(self.gh_opener), done)

    def preview(self):
        try:
            text = core.preview_text(self.body())
        except ValueError as e:
            self.say(str(e), "Bad")
            return None
        win = tk.Toplevel(self.root)
        win.title("Preview")
        win.configure(bg=BG)
        t = tk.Text(win, width=70, height=22, wrap="word", bg=CARD, fg=FG, relief="flat", padx=10, pady=8)
        t.insert("1.0", text)
        t.configure(state="disabled")
        t.pack(fill="both", expand=True, padx=10, pady=10)
        return win

    def post(self):
        url = self.webhook_var.get().strip() or self.settings.webhook()
        if not url:
            self.say("Paste your webhook URL and press Save first.", "Bad")
            return False
        if not self.title_var.get().strip() and not self.message.get("1.0", "end").strip():
            self.say("Write a title or a message first.", "Bad")
            return False
        try:
            body = self.body()
        except ValueError as e:
            self.say(str(e), "Bad")
            return False
        if body.get("content") and not messagebox.askyesno("Puppy Announcer", "This will ping %s. Post it?" % body["content"],
                                                             parent=self.root):
            return False
        for key, var in (("color", self.color_var), ("ping", self.ping_var), ("role_id", self.role_var), ("username", self.username_var)):
            self.settings.data[key] = var.get()
        self.settings.save()
        self.post_btn.state(["disabled"])
        self.say("Posting...")
        template, info = self.template, self.info

        def done(msg_id, err):
            self.post_btn.state(["!disabled"])
            if err:
                self.say(err, "Bad")
                return
            if template and info:  # the next fill-in starts after this one
                self.settings.set("last_script_sha" if template == "script" else "last_companion_sha", info["sha"])
            self.say("Posted to Discord." + (" (message %s)" % msg_id if msg_id else ""), "Good")
        self.run_bg(lambda: core.post(url, body, self.opener), done)
        return True

    def close(self):
        try:
            self.root.after_cancel(self._after)
        except (tk.TclError, AttributeError):
            pass
        self.root.destroy()


def main():
    if sys.platform == "win32":
        try:
            import ctypes
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except (AttributeError, OSError):
            pass
    try:
        protector = core.Dpapi()
    except RuntimeError:
        protector = None
    root = tk.Tk()
    app = AnnouncerApp(root, core.Settings(protector=protector))
    root.protocol("WM_DELETE_WINDOW", app.close)
    root.mainloop()
