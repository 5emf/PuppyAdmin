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
from tkinter import colorchooser, filedialog, messagebox, ttk

from . import art_data, core, tags, update

KEY = "#0d0e13"                       # see-through colour (only used for the backdrop)
CARD, FIELD, LINE, STRIP = "#fbfbfb", "#ffffff", "#c8ccd4", "#e6e7ea"
INK, DIM, ORANGE, GOOD, BAD = "#464646", "#8a8d96", "#f59b28", "#3f9b56", "#d0453a"
SECTIONS = ("compose", "updates", "tags", "whitelist", "settings")
TITLES = {"compose": "Compose", "updates": "Updates", "tags": "Tags", "whitelist": "Whitelist", "settings": "Settings"}
DESCRIPTIONS = {
    "compose": "Write any message, add a picture, and post it to your Discord channel.",
    "updates": "Fill in a Puppy Admin or Puppy Companion update from GitHub.",
    "whitelist": "Choose who may post through your relay (owner only: needs the admin key).",
    "tags": "Edit Puppy Admin's shared tags (tags.json): text, colour, picture and who wears them.",
    "settings": "Webhook or relay, stay on top of other windows, and updates.",
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
        self._build_tags()
        self._build_whitelist()
        self._build_settings()
        self.set_topmost(bool(self.settings.get("topmost")))
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
                                  embed=self.embed_var.get(), image_name=self.image["name"] if self.image else None,
                                  avatar_url=self.settings.get("avatar_url"))

    def fields(self):
        return core.relay_fields(self.title_var.get(), self.message.get("1.0", "end"), self.color_var.get(), self.ping_var.get(),
                                 self.role_var.get(), self.loadstring_var.get(), self.username_var.get(), self.embed_var.get(),
                                 avatar_url=self.settings.get("avatar_url"))

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
        ttk.Label(p, text="Webhook picture", style="Head.TLabel").pack(anchor="w", pady=(12, 2))
        r = self._row(p)
        ttk.Label(r, text="Each post", width=10).pack(side="left")
        self.avatar_var = tk.StringVar(value=self.settings.get("avatar_url"))
        ttk.Entry(r, textvariable=self.avatar_var).pack(side="left", fill="x", expand=True)
        ttk.Button(r, text="Save", command=self.save_avatar_url).pack(side="left", padx=(6, 0))
        r = self._row(p)
        ttk.Button(r, text="Set the webhook's own picture...", command=self.pick_webhook_avatar).pack(side="left")
        ttk.Button(r, text="Remove it", command=lambda: self.set_webhook_avatar(None)).pack(side="left", padx=4)
        ttk.Label(p, text="Each post: an https link to an image, shown instead of the webhook's picture (empty = the webhook's own). "
                          "Own picture: a PNG / JPG / GIF saved on the webhook for good (needs your webhook, or the relay's admin key).",
                  style="Dim.TLabel", wraplength=460).pack(anchor="w")

        ttk.Label(p, text="Window", style="Head.TLabel").pack(anchor="w", pady=(12, 2))
        self.topmost_var = tk.BooleanVar(value=bool(self.settings.get("topmost")))
        ttk.Checkbutton(p, text="Stay on top of other windows (an overlay over games and apps)", variable=self.topmost_var,
                        command=lambda: self.set_topmost(self.topmost_var.get(), save=True)).pack(anchor="w")
        r = self._row(p, pady=(8, 0))
        self.update_btn = ttk.Button(r, text="Check for updates", command=self.check_update)
        self.update_btn.pack(side="left")
        self.update_lbl = ttk.Label(r, style="Dim.TLabel", text="Build %d" % update.current() if update.current() else "Running from source")
        self.update_lbl.pack(side="left", padx=8)
        ttk.Label(p, text="Webhook, keys, the admin key and the tag token are stored encrypted for this Windows user and never shown again.",
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

    # ------------------------------------------------------------------ webhook picture
    def save_avatar_url(self):
        url = self.avatar_var.get().strip()
        if url and not core.valid_avatar_url(url):
            self.say("The post picture must be an https:// link to an image.", "Bad")
            return False
        self.settings.set("avatar_url", url)
        self.say("Posts now use this picture." if url else "Posts use the webhook's own picture again.", "Good")
        return True

    def pick_webhook_avatar(self):
        path = filedialog.askopenfilename(parent=self.root, title="The webhook's picture",
                                          filetypes=[("Pictures", "*.png *.jpg *.jpeg *.gif"), ("All files", "*.*")])
        if path:
            try:
                self.set_webhook_avatar(core.load_image(path))
            except ValueError as e:
                self.say(str(e), "Bad")

    def set_webhook_avatar(self, image):
        """image = load_image() result, or None to remove the picture."""
        try:
            if image:
                core.avatar_data_uri(image)
        except ValueError as e:
            self.say(str(e), "Bad")
            return False
        url = self.settings.webhook()
        base, admin = self.settings.get("relay_url"), self.settings.secret("admin_key")
        if url:
            work = lambda: core.set_webhook_avatar(url, image, opener=self.opener)
        elif base and admin:
            work = lambda: core.admin_avatar(base, admin, image, opener=self.opener)
        else:
            self.say("Save your webhook first (or the relay address and admin key in Whitelist).", "Bad")
            return False
        self.say("Changing the webhook's picture...")

        def done(res, err):
            if err:
                self.say(err, "Bad")
            else:
                self.say("The webhook's picture was changed." if image else "The webhook's picture was removed.", "Good")
        self.run_bg(work, done)
        return True

    # ------------------------------------------------------------------ window options + update
    def set_topmost(self, on, save=False):
        try:
            self.root.wm_attributes("-topmost", bool(on))
        except tk.TclError:
            pass
        if save:
            self.settings.set("topmost", bool(on))

    def check_update(self):
        self.update_btn.state(["disabled"])
        self.say("Checking for a Pupdates update...")

        def checked(info, err):
            if err:
                self.update_btn.state(["!disabled"])
                self.say(err, "Bad")
                return
            if not info["newer"]:
                self.update_btn.state(["!disabled"])
                self.say("Pupdates is up to date (build %d)." % max(update.current(), info["build"]), "Good")
                return
            if not update.can_self_update():
                self.update_btn.state(["!disabled"])
                self.say("Build %d is out. Only the built Pupdates.exe updates itself (from source: git pull)." % info["build"])
                return
            if not self.confirm("Pupdates build %d is out (you have %d). Download it and restart?" % (info["build"], update.current())):
                self.update_btn.state(["!disabled"])
                return
            self.say("Downloading build %d..." % info["build"])

            def downloaded(path, err2):
                self.update_btn.state(["!disabled"])
                if err2:
                    self.say(err2, "Bad")
                    return
                try:
                    update.install(path)
                except (RuntimeError, OSError) as e:
                    self.say(str(e), "Bad")
                    return
                self.close()
            self.run_bg(lambda: update.download(info, opener=self.gh_opener), downloaded)
        self.run_bg(lambda: update.check(self.gh_opener), checked)

    # ------------------------------------------------------------------ tags
    def _build_tags(self):
        p = self._page("tags")
        self.tag_list, self.tag_sha, self.tag_index, self.tag_names = [], None, None, {}
        r = self._row(p)
        ttk.Label(r, text="GitHub token", width=12).pack(side="left")
        self.tag_token_var = tk.StringVar()
        self._secret_entry(r, self.tag_token_var).pack(side="left", fill="x", expand=True)
        ttk.Button(r, text="Save", command=self.save_tag_token).pack(side="left", padx=(6, 0))
        ttk.Button(r, text="Load", command=self.load_tags).pack(side="left", padx=(4, 0))
        self.tag_token_lbl = ttk.Label(p, style="Dim.TLabel", wraplength=460, text="")
        self.tag_token_lbl.pack(anchor="w")
        self._tag_token_label()

        r = self._row(p, pady=(6, 3))
        lf = tk.Frame(r, bg=FIELD, highlightthickness=1, highlightbackground=LINE)
        lf.pack(side="left", fill="both", expand=True)
        self.tags_box = tk.Listbox(lf, height=4, bg=FIELD, fg=INK, relief="flat", highlightthickness=0, bd=0, exportselection=False,
                                   selectbackground=ORANGE, selectforeground="#ffffff", font=(self.family, 10), activestyle="none")
        self.tags_box.pack(fill="both", expand=True, padx=4, pady=4)
        self.tags_box.bind("<<ListboxSelect>>", lambda e: self.pick_tag())
        side = ttk.Frame(r)
        side.pack(side="left", fill="y", padx=(6, 0))
        ttk.Button(side, text="New", command=self.new_tag).pack(fill="x")
        ttk.Button(side, text="Delete", command=self.delete_tag).pack(fill="x", pady=4)

        g = ttk.Frame(p)
        g.pack(fill="x", pady=(4, 0))
        self.tv = {k: tk.StringVar() for k in ("name", "text", "sub", "color", "font", "size", "offset", "pfp_mode", "pfp_image",
                                                "bd_color", "bd_alpha", "bd_image", "bd_img_alpha")}
        self.tv_rainbow, self.tv_backdrop = tk.BooleanVar(), tk.BooleanVar()
        self.tv_bd_round, self.tv_pfp_round = tk.BooleanVar(value=True), tk.BooleanVar(value=True)
        cells = [("Name", "name"), ("Text", "text"), ("Under it", "sub")]
        for i, (label, key) in enumerate(cells):
            ttk.Label(g, text=label).grid(row=i, column=0, sticky="w", pady=1)
            ttk.Entry(g, textvariable=self.tv[key]).grid(row=i, column=1, columnspan=5, sticky="ew", pady=1)
        ttk.Label(g, text="Colour").grid(row=3, column=0, sticky="w", pady=1)
        ttk.Entry(g, textvariable=self.tv["color"], width=9).grid(row=3, column=1, sticky="w")
        ttk.Button(g, text="Pick...", command=lambda: self.pick_tag_color("color")).grid(row=3, column=2, sticky="w", padx=4)
        ttk.Checkbutton(g, text="Rainbow", variable=self.tv_rainbow).grid(row=3, column=3, columnspan=3, sticky="w")
        ttk.Label(g, text="Font").grid(row=4, column=0, sticky="w", pady=1)
        ttk.Combobox(g, textvariable=self.tv["font"], values=list(tags.FONTS), state="readonly", width=14).grid(row=4, column=1, sticky="w")
        ttk.Label(g, text="Size").grid(row=4, column=2, sticky="e", padx=4)
        ttk.Spinbox(g, textvariable=self.tv["size"], from_=8, to=48, width=4).grid(row=4, column=3, sticky="w")
        ttk.Label(g, text="Height").grid(row=4, column=4, sticky="e", padx=4)
        ttk.Spinbox(g, textvariable=self.tv["offset"], from_=0, to=12, increment=0.5, width=4).grid(row=4, column=5, sticky="w")
        ttk.Label(g, text="Picture").grid(row=5, column=0, sticky="w", pady=1)
        ttk.Combobox(g, textvariable=self.tv["pfp_mode"], values=list(tags.PFP_MODES), state="readonly", width=8).grid(row=5, column=1, sticky="w")
        ttk.Checkbutton(g, text="Round picture", variable=self.tv_pfp_round).grid(row=5, column=2, columnspan=4, sticky="w", padx=4)
        ttk.Label(g, text="Image").grid(row=6, column=0, sticky="w", pady=1)
        ttk.Entry(g, textvariable=self.tv["pfp_image"]).grid(row=6, column=1, columnspan=5, sticky="ew", pady=1)
        ttk.Checkbutton(g, text="Backdrop", variable=self.tv_backdrop).grid(row=7, column=0, sticky="w", pady=(4, 1))
        ttk.Entry(g, textvariable=self.tv["bd_color"], width=9).grid(row=7, column=1, sticky="w", pady=(4, 1))
        ttk.Button(g, text="Pick...", command=lambda: self.pick_tag_color("bd_color")).grid(row=7, column=2, sticky="w", padx=4, pady=(4, 1))
        ttk.Checkbutton(g, text="Rounded corners", variable=self.tv_bd_round).grid(row=7, column=3, columnspan=3, sticky="w", pady=(4, 1))
        ttk.Label(g, text="See-through").grid(row=8, column=0, sticky="w", pady=1)
        ttk.Spinbox(g, textvariable=self.tv["bd_alpha"], from_=0, to=1, increment=0.05, width=5).grid(row=8, column=1, sticky="w")
        ttk.Label(g, text="Image see-through").grid(row=8, column=2, columnspan=3, sticky="e", padx=4)
        ttk.Spinbox(g, textvariable=self.tv["bd_img_alpha"], from_=0, to=1, increment=0.05, width=5).grid(row=8, column=5, sticky="w")
        ttk.Label(g, text="Box image").grid(row=9, column=0, sticky="w", pady=1)
        ttk.Entry(g, textvariable=self.tv["bd_image"]).grid(row=9, column=1, columnspan=5, sticky="ew", pady=1)
        g.grid_columnconfigure(1, weight=1)
        self.tag_preview = tk.Canvas(p, height=58, bg="#7f8794", highlightthickness=1, highlightbackground=LINE)
        self.tag_preview.pack(fill="x", pady=(4, 0))
        for v in list(self.tv.values()) + [self.tv_rainbow, self.tv_backdrop, self.tv_bd_round, self.tv_pfp_round]:
            v.trace_add("write", lambda *a: self._draw_tag_preview())

        r = self._row(p, pady=(6, 3))
        mf = tk.Frame(r, bg=FIELD, highlightthickness=1, highlightbackground=LINE)
        mf.pack(side="left", fill="both", expand=True)
        self.members_box = tk.Listbox(mf, height=3, bg=FIELD, fg=INK, relief="flat", highlightthickness=0, bd=0, exportselection=False,
                                      selectbackground=ORANGE, selectforeground="#ffffff", font=(self.family, 10), activestyle="none")
        self.members_box.pack(fill="both", expand=True, padx=4, pady=4)
        side = ttk.Frame(r)
        side.pack(side="left", fill="y", padx=(6, 0))
        self.member_var = tk.StringVar()
        ttk.Entry(side, textvariable=self.member_var, width=16).pack(fill="x")
        ttk.Button(side, text="Add wearer", command=self.add_member).pack(fill="x", pady=(4, 0))
        ttk.Button(side, text="Remove", command=self.remove_member).pack(fill="x", pady=4)
        r = self._row(p, pady=(6, 0))
        ttk.Label(r, text="Wearers: Roblox username or user id.", style="Dim.TLabel").pack(side="left")
        self.save_tags_btn = ttk.Button(r, text="Save to GitHub", style="Accent.TButton", command=self.save_tags)
        self.save_tags_btn.pack(side="right")

    def _tag_token_label(self):
        self.tag_token_lbl.configure(text="A token is saved (encrypted): you can save tag changes." if self.settings.secret("tags_token") else
                                     "Anyone can load the tags. Saving needs a fine-grained GitHub token for 5emf/PuppyAdmin with "
                                     "Contents: read and write (the same one Puppy Admin's tag sync uses).")

    def save_tag_token(self):
        try:
            self.settings.set_secret("tags_token", self.tag_token_var.get())
        except RuntimeError as e:
            self.say(str(e), "Bad")
            return False
        self.tag_token_var.set("")
        self._tag_token_label()
        self.say("Token saved." if self.settings.secret("tags_token") else "Token removed.", "Good")
        return True

    def _tag_label(self, t):
        return ("(default) " if t.get("isDefault") else "") + t["name"] + "   [%d]" % len(t["members"])

    def _fill_tags_box(self):
        self.tags_box.delete(0, "end")
        for t in self.tag_list:
            self.tags_box.insert("end", self._tag_label(t))
        if self.tag_index is not None and self.tag_index < len(self.tag_list):
            self.tags_box.selection_set(self.tag_index)

    def load_tags(self):
        self.say("Loading the tags...")
        token = self.settings.secret("tags_token") or None

        def done(res, err):
            if err:
                self.say(err, "Bad")
                return
            self.tag_list, self.tag_sha = res
            self.tag_index = None
            self._fill_tags_box()
            self._show_tag(None)
            self.say("%d tags loaded." % len(self.tag_list), "Good")
            ids = sorted({m for t in self.tag_list for m in t["members"]})
            self.run_bg(lambda: tags.user_names(ids, self.opener), self._got_names)
        self.run_bg(lambda: tags.load(token, self.opener), done)
        return True

    def _got_names(self, names, err):
        if names:
            self.tag_names.update(names)
            self._show_members()

    def _store_tag(self):
        """Writes the fields into the selected tag (returns False and says why when a field is wrong)."""
        if self.tag_index is None:
            return True
        t = self.tag_list[self.tag_index]
        try:
            color = tags.parse_hex(self.tv["color"].get())
            bd_color = tags.parse_hex(self.tv["bd_color"].get())
        except ValueError as e:
            self.say(str(e), "Bad")
            return False
        try:
            size = float(self.tv["size"].get() or 22)
            offset = float(self.tv["offset"].get() or 3)
            alpha = float(self.tv["bd_alpha"].get() or 0.35)
            img_alpha = float(self.tv["bd_img_alpha"].get() or 0.15)
        except ValueError:
            self.say("Size, height and see-through are numbers (size 8-48, height 0-12, see-through 0-1)", "Bad")
            return False
        t.update({"name": self.tv["name"].get(), "text": self.tv["text"].get(), "sub": self.tv["sub"].get(), "color": color,
                  "rainbow": self.tv_rainbow.get(), "font": self.tv["font"].get() or "GothamBold", "size": size, "offset": offset})
        t["backdrop"].update({"on": self.tv_backdrop.get(), "color": bd_color, "transparency": alpha, "image": self.tv["bd_image"].get().strip(),
                              "imageTransparency": img_alpha, "round": self.tv_bd_round.get()})
        t["pfp"].update({"mode": self.tv["pfp_mode"].get() or "none", "image": self.tv["pfp_image"].get().strip(), "round": self.tv_pfp_round.get()})
        self.tag_list[self.tag_index] = tags.clean_tag(t)
        self.tags_box.delete(self.tag_index)
        self.tags_box.insert(self.tag_index, self._tag_label(self.tag_list[self.tag_index]))
        return True

    def _show_tag(self, i):
        self.tag_index = i
        t = self.tag_list[i] if i is not None else tags.new_tag("")
        bd, pf = t["backdrop"], t["pfp"]
        num = lambda v: ("%g" % v)
        for key, val in (("name", t["name"]), ("text", t["text"]), ("sub", t["sub"]), ("color", tags.hex_color(t["color"])),
                         ("font", t["font"]), ("size", num(t["size"])), ("offset", num(t["offset"])), ("pfp_mode", pf["mode"]),
                         ("pfp_image", pf["image"]), ("bd_color", tags.hex_color(bd["color"])), ("bd_alpha", num(bd["transparency"])),
                         ("bd_image", bd["image"]), ("bd_img_alpha", num(bd["imageTransparency"]))):
            self.tv[key].set(val if i is not None else "")
        self.tv_rainbow.set(t["rainbow"] and i is not None)
        self.tv_backdrop.set(bd["on"] and i is not None)
        self.tv_bd_round.set(bd["round"])
        self.tv_pfp_round.set(pf["round"])
        self._draw_tag_preview()
        self._show_members()

    def _show_members(self):
        self.members_box.delete(0, "end")
        if self.tag_index is None:
            return
        t = self.tag_list[self.tag_index]
        if t.get("isDefault"):
            self.members_box.insert("end", "The default tag: worn by everyone running Puppy Admin with no other tag.")
            return
        for m in t["members"]:
            name = self.tag_names.get(m)
            self.members_box.insert("end", "%s (%s)" % (name, m) if name else m)

    def pick_tag(self):
        sel = self.tags_box.curselection()
        if not sel or sel[0] == self.tag_index:
            return
        if not self._store_tag():
            self.tags_box.selection_clear(0, "end")
            self.tags_box.selection_set(self.tag_index)
            return
        self._show_tag(sel[0])

    def new_tag(self):
        if not self._store_tag():
            return
        if len(self.tag_list) >= tags.MAX_TAGS:
            self.say("Puppy Admin keeps at most %d tags." % tags.MAX_TAGS, "Bad")
            return
        self.tag_list.append(tags.new_tag())
        self.tag_index = len(self.tag_list) - 1
        self._fill_tags_box()
        self._show_tag(self.tag_index)
        self.say("New tag added: fill it in, add wearers, then Save to GitHub.")

    def delete_tag(self):
        if self.tag_index is None:
            self.say("Pick a tag first.", "Bad")
            return
        name = self.tag_list[self.tag_index]["name"]
        if not self.confirm("Delete the tag %s?" % name):
            return
        del self.tag_list[self.tag_index]
        self.tag_index = None
        self._fill_tags_box()
        self._show_tag(None)
        self.say("%s deleted (not saved yet)." % name)

    def pick_tag_color(self, key="color"):
        try:
            start = tags.hex_color(tags.parse_hex(self.tv[key].get()))
        except ValueError:
            start = "#ffffff"
        got = colorchooser.askcolor(color=start, parent=self.root, title="Backdrop colour" if key == "bd_color" else "Tag colour")
        if got and got[1]:
            self.tv[key].set(got[1])

    def _draw_tag_preview(self):
        """A rough look at the tag (Roblox draws the real one): backdrop, picture spot, text and the line under it."""
        c = getattr(self, "tag_preview", None)
        if c is None:
            return
        c.delete("all")
        if self.tag_index is None:
            c.create_text(10, 29, anchor="w", text="Pick or add a tag to see it here", fill="#ffffff", font=(self.family, 10))
            return
        w = max(c.winfo_width(), 300)
        spec = tags.preview_spec(self._preview_values())
        x0, x1, y0, y1 = w / 2 - 130, w / 2 + 130, 6, 52
        if spec["backdrop"]:
            c.create_rectangle(x0, y0, x1, y1, fill=spec["backdrop"], outline="", stipple=spec["stipple"])
        if spec["pfp"]:
            if spec["pfp_round"]:
                c.create_oval(x0 + 6, y0 + 6, x0 + 40, y0 + 40, fill="#d8dbe2", outline="#ffffff")
            else:
                c.create_rectangle(x0 + 6, y0 + 6, x0 + 40, y0 + 40, fill="#d8dbe2", outline="#ffffff")
            c.create_text(x0 + 23, y0 + 23, text=spec["pfp"], fill="#464646", font=(self.family, 7))
        size = max(9, min(18, int(spec["size"] * 0.7)))
        tx = w / 2 + (14 if spec["pfp"] else 0)
        if spec["rainbow"]:
            text, cols = spec["text"], tags.RAINBOW
            total = len(text) * size * 0.62
            for k, ch in enumerate(text):
                c.create_text(tx - total / 2 + k * size * 0.62, 22, text=ch, fill=cols[k % len(cols)], font=(self.family, size, "bold"))
        else:
            c.create_text(tx, 22, text=spec["text"], fill=spec["color"], font=(self.family, size, "bold"))
        if spec["sub"]:
            c.create_text(tx, 42, text=spec["sub"], fill="#dddddd", font=(self.family, 9))

    def _preview_values(self):
        def num(key, default):
            try:
                return float(self.tv[key].get())
            except ValueError:
                return default
        return {"text": self.tv["text"].get(), "sub": self.tv["sub"].get(), "color": self.tv["color"].get(), "rainbow": self.tv_rainbow.get(),
                "size": num("size", 22), "backdrop": self.tv_backdrop.get(), "bd_color": self.tv["bd_color"].get(),
                "bd_alpha": num("bd_alpha", 0.35), "pfp": self.tv["pfp_mode"].get(), "pfp_round": self.tv_pfp_round.get()}

    def add_member(self):
        if self.tag_index is None or self.tag_list[self.tag_index].get("isDefault"):
            self.say("Pick a tag (not the default one) first.", "Bad")
            return False
        text = self.member_var.get().strip()
        if not text:
            self.say("Type a Roblox username or user id.", "Bad")
            return False
        index = self.tag_index

        def done(res, err):
            if err:
                self.say(err, "Bad")
                return
            uid, name = res
            other = tags.owner_of(self.tag_list, uid)
            if other is self.tag_list[index]:
                self.say("They already wear this tag.")
                return
            if other is not None:
                if not self.confirm("%s already wears %s. Move them to this tag?" % (name or uid, other["name"])):
                    return
                other["members"].remove(uid)
            self.tag_list[index]["members"].append(uid)
            if name:
                self.tag_names[uid] = name
            self.member_var.set("")
            self._fill_tags_box()
            self._show_members()
            self.say("%s added (not saved yet)." % (name or uid), "Good")
        self.run_bg(lambda: tags.user_id(text, self.opener), done)
        return True

    def remove_member(self):
        sel = self.members_box.curselection()
        if self.tag_index is None or not sel or self.tag_list[self.tag_index].get("isDefault"):
            self.say("Pick a wearer first.", "Bad")
            return False
        t = self.tag_list[self.tag_index]
        del t["members"][sel[0]]
        self._fill_tags_box()
        self._show_members()
        self.say("Removed (not saved yet).")
        return True

    def save_tags(self):
        if not self._store_tag():
            return False
        token = self.settings.secret("tags_token")
        if not token:
            self.say("Save your GitHub token first (it needs Contents: read and write).", "Bad")
            return False
        if self.tag_sha is None and not self.tag_list:
            self.say("Load the tags first.", "Bad")
            return False
        self.save_tags_btn.state(["disabled"])
        self.say("Saving the tags to GitHub...")
        snapshot = [dict(t) for t in self.tag_list]

        def done(sha, err):
            self.save_tags_btn.state(["!disabled"])
            if err:
                self.say(err, "Bad")
                return
            self.tag_sha = sha
            self.say("Saved: Puppy Admin picks the new tags up within a minute or two.", "Good")
        self.run_bg(lambda: tags.save(snapshot, self.tag_sha, token, opener=self.opener), done)
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
