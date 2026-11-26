"""The Pupdates window, laid out like the Sword Art Online-style menu (original, shapes only): no
window frame and no backdrop on Windows, just a column of round icons (Compose, Updates,
Whitelist, Settings) beside a white card with a grey description strip under it. Drag the card's
header to move it; the small - and x in the header minimise and close. On other systems it is an
ordinary window with the same contents.
"""
import os
import queue
import sys
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from . import art_data, core

KEY = "#0d0e13"                       # see-through colour (only used for the backdrop)
CARD, FIELD, LINE, STRIP = "#fbfbfb", "#ffffff", "#c8ccd4", "#e6e7ea"
INK, DIM, ORANGE, GOOD, BAD = "#464646", "#8a8d96", "#f59b28", "#3f9b56", "#d0453a"
SECTIONS = ("compose", "updates", "whitelist", "settings")
TITLES = {"compose": "Compose", "updates": "Updates", "whitelist": "Whitelist", "settings": "Settings"}
DESCRIPTIONS = {
    "compose": "Write any message, add a picture, and post it to your Discord channel.",
    "updates": "Fill in a Puppy Admin or Puppy Companion update from GitHub.",
    "whitelist": "Choose who may post through your relay (owner only: needs the admin key).",
    "settings": "Post straight to a webhook, or through the relay with your access key.",
    "minimise": "Minimise Pupdates.",
    "close": "Close Pupdates.",
}


def style(root):
    s = ttk.Style(root)
    try:
        s.theme_use("clam")
    except tk.TclError:
        pass
    family = "Segoe UI" if sys.platform == "win32" else "DejaVu Sans"
    s.configure(".", background=CARD, foreground=INK, fieldbackground=FIELD, bordercolor=LINE, font=(family, 10),
                lightcolor=CARD, darkcolor=CARD, insertcolor=INK, selectbackground=ORANGE, selectforeground="#ffffff")
    s.configure("TFrame", background=CARD)
    s.configure("TLabel", background=CARD, foreground=INK)
    s.configure("Dim.TLabel", foreground=DIM)
    s.configure("Good.TLabel", foreground=GOOD)
    s.configure("Bad.TLabel", foreground=BAD)
    s.configure("Head.TLabel", font=(family, 13, "bold"), foreground=INK)
    s.configure("Section.TLabel", font=(family, 10), foreground=DIM)
    s.configure("Strip.TLabel", background=STRIP, foreground=INK, padding=(10, 6))
    s.configure("TButton", background="#f1f2f4", foreground=INK, bordercolor=LINE, padding=(10, 4), focusthickness=0,
                lightcolor="#fcfcfc", darkcolor="#e4e5e8")
    s.map("TButton", background=[("pressed", "#d98618"), ("active", ORANGE), ("disabled", "#eeeeef")],
          foreground=[("active", "#ffffff"), ("disabled", DIM)], bordercolor=[("active", "#d98618")])
    s.configure("Accent.TButton", background=ORANGE, foreground="#ffffff", bordercolor="#d98618")
    s.map("Accent.TButton", background=[("pressed", "#d98618"), ("active", "#ffb24d"), ("disabled", "#eeeeef")])
    s.configure("TEntry", fieldbackground=FIELD, foreground=INK, padding=4)
    s.configure("TCombobox", fieldbackground=FIELD, background="#f1f2f4", foreground=INK, arrowcolor=INK)
    s.map("TCombobox", fieldbackground=[("readonly", FIELD)], foreground=[("readonly", INK)])
    for w in ("TCheckbutton", "TRadiobutton"):
        s.configure(w, background=CARD, foreground=INK, indicatorbackground=FIELD, indicatorforeground=ORANGE)
        s.map(w, background=[("active", CARD)], indicatorbackground=[("selected", ORANGE)])
    root.option_add("*TCombobox*Listbox.background", FIELD)
    root.option_add("*TCombobox*Listbox.foreground", INK)
    root.option_add("*TCombobox*Listbox.selectBackground", ORANGE)
    return family


class PupdatesApp:
    def __init__(self, root, settings, opener=None, gh_opener=None, floating=None):
        self.root, self.settings = root, settings
        self.opener, self.gh_opener = opener, gh_opener
        self.ui = queue.Queue()
        self.info = None        # latest GitHub info, after a fill-in
        self.template = None    # "script" / "companion" when the text came from a fill-in
        self.image = None       # {data, mime, name, path} of the picture to send
        self.confirm = lambda text: messagebox.askyesno("Pupdates", text, parent=self.root)
        self.family = style(root)
        root.title("Pupdates")
        self.floating = self._make_floating() if floating is None else floating
        root.configure(bg=KEY if self.floating else "#1b1c22")
        self.img = {k: tk.PhotoImage(master=root, data=v) for k, v in art_data.ICONS.items()}
        self.section = None

        # the column of round icons
        col = tk.Frame(root, bg=root.cget("bg"))
        col.grid(row=0, column=0, rowspan=2, sticky="n", padx=(8, 10), pady=(54, 8))
        self.icons = {}
        for name in SECTIONS:
            lbl = tk.Label(col, image=self.img[name + "_normal"], bd=0, highlightthickness=0, bg=root.cget("bg"), cursor="hand2")
            lbl.pack(pady=5)
            lbl.bind("<Enter>", lambda e, n=name: self._hover(n, True))
            lbl.bind("<Leave>", lambda e, n=name: self._hover(n, False))
            lbl.bind("<Button-1>", lambda e, n=name: self.show(n))
            self.icons[name] = lbl

        # the card
        card = tk.Frame(root, bg=CARD, highlightthickness=1, highlightbackground=LINE)
        card.grid(row=0, column=1, sticky="nsew", pady=(8, 0))
        head = tk.Frame(card, bg=CARD)
        head.pack(fill="x", padx=12, pady=(10, 0))
        logo = tk.Label(head, image=self.img["logo"], bg=CARD, bd=0)
        logo.pack(side="left")
        title = ttk.Label(head, text="PUPDATES", style="Head.TLabel")
        title.pack(side="left", padx=(8, 6))
        self.section_lbl = ttk.Label(head, text="", style="Section.TLabel")
        self.section_lbl.pack(side="left", pady=(3, 0))
        for text, key, cmd in (("×", "close", self.close), ("–", "minimise", self.minimise)):
            b = tk.Label(head, text=text, bg=CARD, fg=DIM, font=(self.family, 13), cursor="hand2", padx=6)
            b.pack(side="right")
            b.bind("<Button-1>", lambda e, c=cmd: c())
            b.bind("<Enter>", lambda e, w=b, k=key: (w.configure(fg=ORANGE), self._describe(k)))
            b.bind("<Leave>", lambda e, w=b: (w.configure(fg=DIM), self._describe(None)))
        for w in (head, logo, title, self.section_lbl):
            w.bind("<ButtonPress-1>", self._drag_start)
            w.bind("<B1-Motion>", self._drag_move)
        tk.Frame(card, bg=ORANGE, height=2).pack(fill="x", padx=12, pady=(8, 0))
        self.body_frame = ttk.Frame(card, padding=(14, 10, 14, 6))
        self.body_frame.pack(fill="both", expand=True)
        self.status = ttk.Label(card, style="Dim.TLabel", text="", wraplength=470)
        self.status.pack(fill="x", padx=14, pady=(0, 10))
        self.strip = ttk.Label(root, style="Strip.TLabel", text="", wraplength=480)
        self.strip.grid(row=1, column=1, sticky="ew", pady=(6, 8))
        root.grid_columnconfigure(1, weight=1, minsize=560)   # the same size on every section
        root.grid_rowconfigure(0, weight=1, minsize=580)

        self.pages = {}
        self._build_compose()
        self._build_updates()
        self._build_whitelist()
        self._build_settings()
        self.show("compose")
        self.say(self._mode_text())
        if self.floating:
            root.update_idletasks()
            w, h = root.winfo_reqwidth(), root.winfo_reqheight()
            root.geometry("+%d+%d" % (max(0, (root.winfo_screenwidth() - w) // 2), max(0, (root.winfo_screenheight() - h) // 3)))
        else:
            root.minsize(600, 640)
        self._after = root.after(100, self._tick)

    # ------------------------------------------------------------------ window
    def _make_floating(self):
        """No frame and a see-through backdrop (Windows only). False = an ordinary window."""
        if sys.platform != "win32":
            return False
        try:
            self.root.configure(bg=KEY)
            self.root.wm_attributes("-transparentcolor", KEY)
            self.root.overrideredirect(True)
            self.root.wm_attributes("-topmost", False)
        except tk.TclError:
            return False
        self.root.after(30, self._taskbar_entry)
        self.root.bind("<Map>", self._remapped, add="+")
        return True

    def _taskbar_entry(self):
        """A frameless Tk window has no taskbar button; give it one back (WS_EX_APPWINDOW)."""
        try:
            import ctypes
            user32 = ctypes.windll.user32
            hwnd = user32.GetParent(self.root.winfo_id())
            GWL_EXSTYLE, WS_EX_APPWINDOW, WS_EX_TOOLWINDOW = -20, 0x40000, 0x80
            ex = user32.GetWindowLongW(hwnd, GWL_EXSTYLE)
            user32.SetWindowLongW(hwnd, GWL_EXSTYLE, (ex & ~WS_EX_TOOLWINDOW) | WS_EX_APPWINDOW)
            self.root.withdraw()
            self.root.after(10, self.root.deiconify)
        except (AttributeError, OSError, tk.TclError):
            pass

    def _remapped(self, event):
        if event.widget is self.root and getattr(self, "_minimised", False):
            self._minimised = False
            self.root.after(10, lambda: (self.root.overrideredirect(True), self._taskbar_entry()))

    def minimise(self):
        try:
            if self.floating:
                self._minimised = True
                self.root.overrideredirect(False)
            self.root.iconify()
        except tk.TclError:
            pass

    def _drag_start(self, e):
        self._drag = (e.x_root - self.root.winfo_x(), e.y_root - self.root.winfo_y())

    def _drag_move(self, e):
        if getattr(self, "_drag", None):
            self.root.geometry("+%d+%d" % (e.x_root - self._drag[0], e.y_root - self._drag[1]))

    def _hover(self, name, inside):
        if name != self.section:
            self.icons[name].configure(image=self.img[name + ("_hover" if inside else "_normal")])
        self._describe(name if inside else None)

    def _describe(self, key):
        self.strip.configure(text=DESCRIPTIONS.get(key or self.section, ""))

    def show(self, name):
        if self.section:
            self.pages[self.section].pack_forget()
            self.icons[self.section].configure(image=self.img[self.section + "_normal"])
        self.section = name
        self.icons[name].configure(image=self.img[name + "_chosen"])
        self.pages[name].pack(fill="both", expand=True)
        self.section_lbl.configure(text="/ " + TITLES[name])
        self._describe(None)
        if name == "whitelist" and self.settings.secret("admin_key") and self.settings.get("relay_url") and not self.users_list.size():
            self.refresh_users()

    # ------------------------------------------------------------------ helpers
    def say(self, text, kind="Dim"):
        self.status.configure(text=text, style=kind + ".TLabel")

    def _mode_text(self):
        if self.settings.get("mode") == "relay":
            return "Posting through the relay." if self.settings.secret("relay_key") else "Relay mode: enter your access key in Settings."
        return "Posting to your webhook." if self.settings.webhook() else "Save your webhook in Settings (or use the relay)."

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

    def _page(self, name):
        f = ttk.Frame(self.body_frame)
        self.pages[name] = f
        return f

    def _row(self, parent, pady=3):
        r = ttk.Frame(parent)
        r.pack(fill="x", pady=pady)
        return r

    def _secret_entry(self, parent, var, width=None):
        e = ttk.Entry(parent, textvariable=var, show="•", **({"width": width} if width else {}))
        return e

    # ------------------------------------------------------------------ compose
    def _build_compose(self):
        p = self._page("compose")
        ttk.Label(p, text="Title").pack(anchor="w")
        self.title_var = tk.StringVar()
        ttk.Entry(p, textvariable=self.title_var).pack(fill="x", pady=(2, 6))
        ttk.Label(p, text="Message").pack(anchor="w")
        self.message = tk.Text(p, height=9, width=56, wrap="word", bg=FIELD, fg=INK, insertbackground=INK, relief="flat",
                               font=(self.family, 10), padx=8, pady=6, highlightthickness=1, highlightbackground=LINE,
                               highlightcolor=ORANGE, selectbackground=ORANGE)
        self.message.pack(fill="both", expand=True, pady=(2, 6))
        self.message.bind("<Control-Return>", lambda e: (self.post(), "break")[1])

        r = self._row(p)
        self.embed_var = tk.BooleanVar(value=bool(self.settings.get("embed")))
        ttk.Checkbutton(r, text="Card (embed)", variable=self.embed_var).pack(side="left")
        ttk.Label(r, text="Colour").pack(side="left", padx=(12, 4))
        self.color_var = tk.StringVar(value=self.settings.get("color") if self.settings.get("color") in core.COLORS else "Orange")
        ttk.Combobox(r, textvariable=self.color_var, values=list(core.COLORS), state="readonly", width=8).pack(side="left")
        ttk.Label(r, text="Name").pack(side="left", padx=(12, 4))
        self.username_var = tk.StringVar(value=self.settings.get("username"))
        ttk.Entry(r, textvariable=self.username_var, width=16).pack(side="left", fill="x", expand=True)

        r = self._row(p)
        ttk.Label(r, text="Ping").pack(side="left")
        self.ping_var = tk.StringVar(value=self.settings.get("ping") if self.settings.get("ping") in core.PINGS else "none")
        ttk.Combobox(r, textvariable=self.ping_var, values=list(core.PINGS), state="readonly", width=10).pack(side="left", padx=(4, 6))
        ttk.Label(r, text="role id").pack(side="left")
        self.role_var = tk.StringVar(value=self.settings.get("role_id"))
        ttk.Entry(r, textvariable=self.role_var, width=20).pack(side="left", padx=4)
        self.loadstring_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(r, text="Loadstring", variable=self.loadstring_var).pack(side="left", padx=(8, 0))

        r = self._row(p, pady=(6, 3))
        pic = tk.Label(r, image=self.img["picture_normal"], bg=CARD, bd=0, cursor="hand2")
        pic.pack(side="left")
        pic.bind("<Button-1>", lambda e: self.pick_image())
        pic.bind("<Enter>", lambda e: pic.configure(image=self.img["picture_hover"]))
        pic.bind("<Leave>", lambda e: pic.configure(image=self.img["picture_normal"]))
        box = ttk.Frame(r)
        box.pack(side="left", fill="x", expand=True, padx=8)
        self.image_lbl = ttk.Label(box, text="No picture (PNG, JPG, GIF or WEBP up to 8 MB)", style="Dim.TLabel")
        self.image_lbl.pack(anchor="w")
        bb = ttk.Frame(box)
        bb.pack(anchor="w", pady=(2, 0))
        ttk.Button(bb, text="Add picture...", command=self.pick_image).pack(side="left")
        self.remove_image_btn = ttk.Button(bb, text="Remove", command=self.clear_image)
        self.remove_image_btn.pack(side="left", padx=4)
        self.remove_image_btn.state(["disabled"])
        self.thumb = tk.Label(r, bg=CARD, bd=0)
        self.thumb.pack(side="right")

        r = self._row(p, pady=(8, 0))
        ttk.Button(r, text="Preview", command=self.preview).pack(side="left")
        ttk.Button(r, text="Clear", command=self.clear).pack(side="left", padx=4)
        send = tk.Label(r, image=self.img["send_normal"], bg=CARD, bd=0, cursor="hand2")
        send.pack(side="right")
        send.bind("<Button-1>", lambda e: self.post())
        send.bind("<Enter>", lambda e: send.configure(image=self.img["send_hover"]))
        send.bind("<Leave>", lambda e: send.configure(image=self.img["send_normal"]))
        self.post_btn = ttk.Button(r, text="Post to Discord", style="Accent.TButton", command=self.post)
        self.post_btn.pack(side="right", padx=6)

    def set_image(self, path):
        try:
            self.image = core.load_image(path)
        except ValueError as e:
            self.say(str(e), "Bad")
            return False
        kb = len(self.image["data"]) // 1024
        self.image_lbl.configure(text="%s (%d KB)" % (os.path.basename(path), kb), style="TLabel")
        self.remove_image_btn.state(["!disabled"])
        self._thumb_img = None
        if self.image["mime"] in ("image/png", "image/gif"):
            try:
                img = tk.PhotoImage(master=self.root, file=path)
                k = max(1, -(-img.width() // 120), -(-img.height() // 70))
                self._thumb_img = img.subsample(k, k) if k > 1 else img
            except tk.TclError:
                self._thumb_img = None
        self.thumb.configure(image=self._thumb_img or "")
        return True

    def pick_image(self):
        path = filedialog.askopenfilename(parent=self.root, title="Pick a picture",
                                          filetypes=[("Pictures", "*.png *.jpg *.jpeg *.gif *.webp"), ("All files", "*.*")])
        if path:
            self.set_image(path)

    def clear_image(self):
        self.image = None
        self._thumb_img = None
        self.thumb.configure(image="")
        self.image_lbl.configure(text="No picture (PNG, JPG, GIF or WEBP up to 8 MB)", style="Dim.TLabel")
        self.remove_image_btn.state(["disabled"])

    def body(self):
        return core.build_payload(self.title_var.get(), self.message.get("1.0", "end"), self.color_var.get(),
                                  self.ping_var.get(), self.role_var.get(), self.loadstring_var.get(), self.username_var.get(),
                                  embed=self.embed_var.get(), image_name=self.image["name"] if self.image else None)

    def fields(self):
        return core.relay_fields(self.title_var.get(), self.message.get("1.0", "end"), self.color_var.get(), self.ping_var.get(),
                                 self.role_var.get(), self.loadstring_var.get(), self.username_var.get(), self.embed_var.get())

    def clear(self):
        self.title_var.set("")
        self.message.delete("1.0", "end")
        self.template = None
        self.clear_image()

    def preview(self):
        try:
            text = core.preview_text(self.body(), self.image)
        except ValueError as e:
            self.say(str(e), "Bad")
            return None
        win = tk.Toplevel(self.root)
        win.title("Preview")
        win.configure(bg=CARD)
        t = tk.Text(win, width=70, height=22, wrap="word", bg=CARD, fg=INK, relief="flat", padx=10, pady=8,
                    font=(self.family, 10))
        t.insert("1.0", text)
        t.configure(state="disabled")
        t.pack(fill="both", expand=True, padx=10, pady=10)
        return win

    def post(self):
        relay = self.settings.get("mode") == "relay"
        url = self.settings.webhook()
        relay_url, key = self.settings.get("relay_url"), self.settings.secret("relay_key")
        if relay and not (relay_url and key):
            self.say("Enter the relay address and your access key in Settings first.", "Bad")
            return False
        if not relay and not url:
            self.say("Save your webhook in Settings first.", "Bad")
            return False
        if not self.title_var.get().strip() and not self.message.get("1.0", "end").strip() and not self.image:
            self.say("Write a title or a message, or add a picture.", "Bad")
            return False
        try:
            body = self.body()
        except ValueError as e:
            self.say(str(e), "Bad")
            return False
        mention = body.get("content", "").split("\n")[0] if self.ping_var.get() != "none" else ""
        if mention and not self.confirm("This will ping %s. Post it?" % mention):
            return False
        for k, var in (("color", self.color_var), ("ping", self.ping_var), ("role_id", self.role_var),
                       ("username", self.username_var), ("embed", self.embed_var)):
            self.settings.data[k] = var.get()
        self.settings.save()
        self.post_btn.state(["disabled"])
        self.say("Posting...")
        template, info, image = self.template, self.info, self.image

        def done(res, err):
            self.post_btn.state(["!disabled"])
            if err:
                self.say(err, "Bad")
                return
            if template and info:  # the next fill-in starts after this one
                self.settings.set("last_script_sha" if template == "script" else "last_companion_sha", info["sha"])
            note = ""
            if isinstance(res, dict) and res.get("pingDropped"):
                note = " The ping was left out: the owner has not allowed you to ping."
            self.say("Posted to Discord." + note, "Good")
        if relay:
            fields = self.fields()
            self.run_bg(lambda: core.post_relay(relay_url, key, fields, image, self.opener), done)
        else:
            self.run_bg(lambda: core.post_webhook(url, body, image, self.opener), done)
        return True

    # ------------------------------------------------------------------ updates
    def _build_updates(self):
        p = self._page("updates")
        ttk.Label(p, text="Fill in an announcement from GitHub: the newest build or version and the changes since "
                          "your last announcement of it. You can edit it before posting.", wraplength=460).pack(anchor="w")
        r = self._row(p, pady=(10, 4))
        self.fill_script_btn = ttk.Button(r, text="Puppy Admin update", command=lambda: self.fill("script"))
        self.fill_script_btn.pack(side="left")
        self.fill_comp_btn = ttk.Button(r, text="Companion update", command=lambda: self.fill("companion"))
        self.fill_comp_btn.pack(side="left", padx=6)
        self.latest_lbl = ttk.Label(p, text="", style="Dim.TLabel", wraplength=460, justify="left")
        self.latest_lbl.pack(anchor="w", pady=(10, 0))

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
            self.latest_lbl.configure(text="Puppy Admin build %s, Puppy Companion %s (commit %s)" %
                                      (info.get("build") or "?", info.get("version") or "?", info["sha"][:7]))
            key = "last_script_sha" if which == "script" else "last_companion_sha"
            maker = core.script_template if which == "script" else core.companion_template
            title, text = maker(info, self.settings.get(key) or None)
            self.title_var.set(title)
            self.message.delete("1.0", "end")
            self.message.insert("1.0", text)
            self.template = which
            self.embed_var.set(True)
            self.color_var.set("Orange" if which == "script" else "Blue")
            self.loadstring_var.set(which == "script")
            self.show("compose")
            self.say("Filled in from GitHub. Edit it, then post.")
        self.run_bg(lambda: core.latest(self.gh_opener), done)

    # ------------------------------------------------------------------ whitelist
    def _build_whitelist(self):
        p = self._page("whitelist")
        ttk.Label(p, text="The relay keeps your webhook secret and lets only the people listed here post, each with their "
                          "own access key. Set the relay up once (pupdates/relay/README.md).", wraplength=460).pack(anchor="w")
        r = self._row(p, pady=(8, 3))
        ttk.Label(r, text="Relay", width=10).pack(side="left")
        self.wl_relay_var = tk.StringVar(value=self.settings.get("relay_url"))
        ttk.Entry(r, textvariable=self.wl_relay_var).pack(side="left", fill="x", expand=True)
        r = self._row(p)
        ttk.Label(r, text="Admin key", width=10).pack(side="left")
        self.admin_var = tk.StringVar()
        self._secret_entry(r, self.admin_var).pack(side="left", fill="x", expand=True)
        ttk.Button(r, text="Save", command=self.save_admin).pack(side="left", padx=(6, 0))
        self.admin_lbl = ttk.Label(p, text="", style="Dim.TLabel")
        self.admin_lbl.pack(anchor="w")
        self._admin_label()

        r = self._row(p, pady=(8, 3))
        lf = tk.Frame(r, bg=FIELD, highlightthickness=1, highlightbackground=LINE)
        lf.pack(side="left", fill="both", expand=True)
        self.users_list = tk.Listbox(lf, height=6, bg=FIELD, fg=INK, relief="flat", highlightthickness=0, bd=0,
                                     selectbackground=ORANGE, selectforeground="#ffffff", font=(self.family, 10), activestyle="none")
        self.users_list.pack(fill="both", expand=True, padx=4, pady=4)
        side = ttk.Frame(r)
        side.pack(side="left", fill="y", padx=(6, 0))
        ttk.Button(side, text="Refresh", command=self.refresh_users).pack(fill="x")
        ttk.Button(side, text="Remove", command=self.remove_user).pack(fill="x", pady=4)

        r = self._row(p, pady=(6, 3))
        ttk.Label(r, text="Name", width=10).pack(side="left")
        self.new_name_var = tk.StringVar()
        ttk.Entry(r, textvariable=self.new_name_var).pack(side="left", fill="x", expand=True)
        self.new_ping_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(r, text="may ping", variable=self.new_ping_var).pack(side="left", padx=6)
        ttk.Button(r, text="Add", style="Accent.TButton", command=self.add_user).pack(side="left")
        r = self._row(p, pady=(6, 0))
        ttk.Label(r, text="New key", width=10).pack(side="left")
        self.new_key_var = tk.StringVar()
        ttk.Entry(r, textvariable=self.new_key_var, state="readonly").pack(side="left", fill="x", expand=True)
        ttk.Button(r, text="Copy", command=self.copy_key).pack(side="left", padx=(6, 0))
        ttk.Label(p, text="A new key is shown once: send it to that person. Adding the same name again gives them a new key.",
                  style="Dim.TLabel", wraplength=460).pack(anchor="w", pady=(4, 0))
        self.user_rows = []

    def _admin_label(self):
        self.admin_lbl.configure(text="An admin key is saved (encrypted)." if self.settings.secret("admin_key")
                                 else "Enter the ADMIN_KEY you gave the relay, then Save.")

    def _admin(self):
        base = self.wl_relay_var.get().strip()
        if base != self.settings.get("relay_url"):
            self.settings.set("relay_url", base)
            self.relay_var.set(base)
        admin = self.admin_var.get().strip() or self.settings.secret("admin_key")
        if not core.valid_relay(base):
            self.say("Enter the relay address (https://...workers.dev).", "Bad")
            return None
        if not admin:
            self.say("Enter your admin key first.", "Bad")
            return None
        return base, admin

    def save_admin(self):
        try:
            self.settings.set_secret("admin_key", self.admin_var.get())
        except RuntimeError as e:
            self.say(str(e), "Bad")
            return False
        self.admin_var.set("")
        self._admin_label()
        self.say("Admin key saved.", "Good")
        return True

    def refresh_users(self):
        a = self._admin()
        if not a:
            return False

        def done(users, err):
            if err:
                self.say(err, "Bad")
                return
            self.user_rows = sorted(users or [], key=lambda u: u.get("name", "").lower())
            self.users_list.delete(0, "end")
            for u in self.user_rows:
                self.users_list.insert("end", u["name"] + ("   (may ping)" if u.get("canPing") else ""))
            self.say("%d on the whitelist." % len(self.user_rows), "Good")
        self.run_bg(lambda: core.admin_list(a[0], a[1], self.opener), done)
        return True

    def add_user(self):
        a = self._admin()
        name = self.new_name_var.get().strip()
        if not a:
            return False
        if not name:
            self.say("Type the person's name first.", "Bad")
            return False
        ping = self.new_ping_var.get()

        def done(res, err):
            if err:
                self.say(err, "Bad")
                return
            self.new_key_var.set(res.get("key", ""))
            self.new_name_var.set("")
            self.say("%s is whitelisted. Copy their key now: it is not shown again." % res.get("name", name), "Good")
            self.refresh_users()
        self.run_bg(lambda: core.admin_add(a[0], a[1], name, ping, self.opener), done)
        return True

    def remove_user(self):
        a = self._admin()
        sel = self.users_list.curselection()
        if not a:
            return False
        if not sel:
            self.say("Pick a name in the list first.", "Bad")
            return False
        name = self.user_rows[sel[0]]["name"]
        if not self.confirm("Remove %s? Their key stops working at once." % name):
            return False

        def done(res, err):
            if err:
                self.say(err, "Bad")
                return
            self.say("%s removed." % name, "Good")
            self.refresh_users()
        self.run_bg(lambda: core.admin_remove(a[0], a[1], name, self.opener), done)
        return True

    def copy_key(self):
        key = self.new_key_var.get()
        if key:
            self.root.clipboard_clear()
            self.root.clipboard_append(key)
            self.say("Key copied.", "Good")

    # ------------------------------------------------------------------ settings
    def _build_settings(self):
        p = self._page("settings")
        r = self._row(p)
        ttk.Label(r, text="Post through").pack(side="left")
        self.mode_var = tk.StringVar(value="relay" if self.settings.get("mode") == "relay" else "webhook")
        for text, val in (("My webhook", "webhook"), ("The relay (whitelisted)", "relay")):
            ttk.Radiobutton(r, text=text, value=val, variable=self.mode_var, command=self.set_mode).pack(side="left", padx=(10, 0))

        ttk.Label(p, text="Webhook (owner)", style="Head.TLabel").pack(anchor="w", pady=(12, 2))
        r = self._row(p)
        self.webhook_var = tk.StringVar()
        self._secret_entry(r, self.webhook_var).pack(side="left", fill="x", expand=True)
        ttk.Button(r, text="Save", command=self.save_webhook).pack(side="left", padx=(6, 0))
        self.webhook_lbl = ttk.Label(p, style="Dim.TLabel", text="", wraplength=460)
        self.webhook_lbl.pack(anchor="w")
        self._webhook_label()

        ttk.Label(p, text="Relay (anyone you whitelisted)", style="Head.TLabel").pack(anchor="w", pady=(12, 2))
        r = self._row(p)
        ttk.Label(r, text="Address", width=10).pack(side="left")
        self.relay_var = tk.StringVar(value=self.settings.get("relay_url"))
        ttk.Entry(r, textvariable=self.relay_var).pack(side="left", fill="x", expand=True)
        r = self._row(p)
        ttk.Label(r, text="Access key", width=10).pack(side="left")
        self.key_var = tk.StringVar()
        self._secret_entry(r, self.key_var).pack(side="left", fill="x", expand=True)
        ttk.Button(r, text="Save", command=self.save_relay).pack(side="left", padx=(6, 0))
        ttk.Button(r, text="Check", command=self.check_relay).pack(side="left", padx=(4, 0))
        self.relay_lbl = ttk.Label(p, style="Dim.TLabel", text="", wraplength=460)
        self.relay_lbl.pack(anchor="w")
        self._relay_label()
        ttk.Label(p, text="Webhook, keys and the admin key are stored encrypted for this Windows user and never shown again.",
                  style="Dim.TLabel", wraplength=460).pack(anchor="w", pady=(14, 0))

    def _webhook_label(self):
        self.webhook_lbl.configure(text="A webhook is saved. Paste a new one to replace it (empty + Save removes it)."
                                   if self.settings.webhook() else
                                   "Discord: channel > Edit Channel > Integrations > Webhooks > Copy Webhook URL.")

    def _relay_label(self, who=None):
        if who:
            text = "Whitelisted as %s%s." % (who.get("name"), " (may ping)" if who.get("canPing") else "")
        else:
            text = "An access key is saved." if self.settings.secret("relay_key") else "Ask the owner for the relay address and your access key."
        self.relay_lbl.configure(text=text)

    def set_mode(self):
        self.settings.set("mode", self.mode_var.get())
        self.say(self._mode_text())

    def save_webhook(self):
        url = self.webhook_var.get().strip()
        try:
            self.settings.set_webhook(url)
        except (ValueError, RuntimeError) as e:
            self.say(str(e), "Bad")
            return False
        self.webhook_var.set("")
        self._webhook_label()
        self.say("Webhook saved." if url else "Webhook removed.", "Good")
        return True

    def save_relay(self):
        base = self.relay_var.get().strip()
        if base and not core.valid_relay(base):
            self.say("The relay address must start with https://", "Bad")
            return False
        self.settings.set("relay_url", base)
        self.wl_relay_var.set(base)
        if self.key_var.get().strip():
            try:
                self.settings.set_secret("relay_key", self.key_var.get())
            except RuntimeError as e:
                self.say(str(e), "Bad")
                return False
            self.key_var.set("")
        self._relay_label()
        self.say("Relay saved.", "Good")
        return True

    def check_relay(self):
        if self.key_var.get().strip() or self.relay_var.get().strip() != self.settings.get("relay_url"):
            if not self.save_relay():
                return False
        base, key = self.settings.get("relay_url"), self.settings.secret("relay_key")
        if not (base and key):
            self.say("Enter the relay address and your access key first.", "Bad")
            return False

        def done(me, err):
            if err:
                self.say(err, "Bad")
                return
            self._relay_label(me)
            self.say("The relay knows you as %s." % me.get("name"), "Good")
        self.run_bg(lambda: core.relay_me(base, key, self.opener), done)
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
            ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID("Pupdates")
        except (AttributeError, OSError):
            pass
    try:
        protector = core.Dpapi()
    except RuntimeError:
        protector = None
    root = tk.Tk()
    app = PupdatesApp(root, core.Settings(protector=protector))
    root.protocol("WM_DELETE_WINDOW", app.close)
    root.mainloop()
