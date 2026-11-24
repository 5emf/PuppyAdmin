"""The Puppy Companion window."""
import os
import queue
import subprocess
import sys
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox, simpledialog, ttk
from tkinter import font as tkfont

from . import launch, update, workspace
from .icon_data import ICON_32, ICON_64
from .launch_queue import LaunchJob, LaunchQueue
from .redact import redact
from .roblox import RobloxError, RobloxSession
from .secure import ProtectorError, default_protector
from .store import AccountStore, Settings

BG, CARD, FIELD, LINE = "#14151a", "#1c1d24", "#262731", "#32333f"
FG, DIM, ACCENT, GOOD, WARN, BAD = "#e9e9ee", "#9b9ca8", "#5aa9ff", "#6fdc8c", "#ffbe78", "#ff7a7a"
SELECT = "#2f4f7a"

# What "Add Puppy Admin to auto-execute" writes: the usual Puppy Admin loadstring
LOADER = ('local H=game:GetService("HttpService") local ok,sha=pcall(function() return H:JSONDecode('
          'game:HttpGet("https://api.github.com/repos/5emf/PuppyAdmin/commits/ccr-3b4dfcff-nyfy0w")).sha end) '
          'loadstring(game:HttpGet("https://raw.githubusercontent.com/5emf/PuppyAdmin/"..(ok and sha or '
          '"ccr-3b4dfcff-nyfy0w").."/PuppyAdmin.lua"))()')

COOKIE_HELP = ("Log in to that account in a private browser window, press F12, open Application > Cookies > "
               "https://www.roblox.com and copy the value of .ROBLOSECURITY. Then just close the private "
               "window: logging out would end that cookie.")


def screen_scale(root):
    """1.0 at 96 DPI (100 %), 1.5 at 144 DPI (150 %): pixel sizes are multiplied by it."""
    try:
        return max(1.0, min(4.0, root.winfo_fpixels("1i") / 96.0))
    except tk.TclError:
        return 1.0


def apply_theme(root, k=1.0):
    def p(n):
        return int(round(n * k))
    style = ttk.Style(root)
    try:
        style.theme_use("clam")
    except tk.TclError:
        pass
    family = "Segoe UI" if sys.platform == "win32" else "DejaVu Sans"
    base = (family, 10)
    # named fonts, not the option database: an option-database font would override every ttk style's font
    for name in ("TkDefaultFont", "TkTextFont", "TkMenuFont", "TkHeadingFont", "TkCaptionFont", "TkTooltipFont"):
        try:
            tkfont.nametofont(name, root=root).configure(family=family, size=10)
        except tk.TclError:
            pass
    style.configure(".", background=BG, foreground=FG, fieldbackground=FIELD, bordercolor=LINE,
                    lightcolor=CARD, darkcolor=CARD, troughcolor=CARD, focuscolor=ACCENT, font=base,
                    insertcolor=FG, selectbackground=SELECT, selectforeground=FG)
    style.configure("TFrame", background=BG)
    style.configure("TLabel", background=BG, foreground=FG)
    style.configure("Dim.TLabel", foreground=DIM)
    style.configure("Good.TLabel", foreground=GOOD)
    style.configure("Warn.TLabel", foreground=WARN)
    style.configure("Bad.TLabel", foreground=BAD)
    style.configure("Title.TLabel", font=(family, 15, "bold"))
    style.configure("TLabelframe", background=BG, bordercolor=LINE, relief="solid", borderwidth=1)
    style.configure("TLabelframe.Label", background=BG, foreground=DIM, font=(family, 9, "bold"))
    style.configure("TButton", background=FIELD, foreground=FG, bordercolor=LINE, padding=(p(12), p(6)), focusthickness=0)
    style.map("TButton", background=[("disabled", CARD), ("pressed", LINE), ("active", "#2f303c")],
              foreground=[("disabled", DIM)])
    style.configure("Accent.TButton", background=ACCENT, foreground="#0b0d12", bordercolor=ACCENT)
    style.map("Accent.TButton", background=[("pressed", "#3f8fe6"), ("active", "#74b7ff")])
    style.configure("Danger.TButton", background="#47222a", foreground="#ffd9d9", bordercolor="#5c2a33")
    style.map("Danger.TButton", background=[("pressed", "#3a1b21"), ("active", "#5c2a33")])
    style.configure("TEntry", fieldbackground=FIELD, foreground=FG, bordercolor=LINE, insertcolor=FG, padding=p(5))
    style.map("TEntry", bordercolor=[("focus", ACCENT)], lightcolor=[("focus", FIELD)])
    style.configure("TSpinbox", fieldbackground=FIELD, foreground=FG, bordercolor=LINE, arrowcolor=FG,
                    insertcolor=FG, padding=p(4), background=FIELD)
    style.map("TSpinbox", bordercolor=[("focus", ACCENT)], lightcolor=[("focus", FIELD)])
    # clam draws check and radio indicators with -indicatorbackground (box) and -indicatorforeground (mark)
    for cls in ("TCheckbutton", "TRadiobutton"):
        style.configure(cls, background=BG, foreground=FG, indicatorbackground=FIELD, indicatorforeground=ACCENT,
                        upperbordercolor=LINE, lowerbordercolor=LINE, padding=p(2))
        style.map(cls, background=[("active", BG)], foreground=[("disabled", DIM)],
                  indicatorbackground=[("pressed", LINE), ("disabled", CARD)])
    style.configure("TNotebook", background=BG, bordercolor=LINE, tabmargins=(0, 0, 0, 0))
    style.configure("TNotebook.Tab", background=CARD, foreground=DIM, padding=(p(18), p(7)), bordercolor=LINE)
    # clam shrinks the selected tab and gives it a light top edge: keep it the same size and dark
    style.map("TNotebook.Tab", background=[("selected", FIELD), ("active", "#23242c")], foreground=[("selected", FG)],
              lightcolor=[("selected", FIELD), ("", CARD)], padding=[("selected", (p(18), p(7)))])
    style.configure("Treeview", background=CARD, fieldbackground=CARD, foreground=FG, rowheight=p(26), bordercolor=LINE)
    style.map("Treeview", background=[("selected", SELECT)], foreground=[("selected", FG)])
    style.configure("Treeview.Heading", background=FIELD, foreground=DIM, relief="flat", padding=(p(6), p(5)))
    style.map("Treeview.Heading", background=[("active", LINE)])
    style.configure("Vertical.TScrollbar", background=FIELD, troughcolor=CARD, bordercolor=CARD, arrowcolor=DIM,
                    lightcolor=FIELD, darkcolor=FIELD, gripcount=0)
    # a scrollbar whose content fits is "disabled": clam would paint it light grey
    style.map("Vertical.TScrollbar", background=[("disabled", CARD), ("active", LINE)],
              arrowcolor=[("disabled", LINE)], lightcolor=[("disabled", CARD)], darkcolor=[("disabled", CARD)],
              bordercolor=[("disabled", CARD)])


def ago(seconds):
    if seconds < 10:
        return "now"
    if seconds < 90:
        return "%d s ago" % seconds
    if seconds < 5400:
        return "%d min ago" % (seconds // 60)
    if seconds < 172800:
        return "%d h ago" % (seconds // 3600)
    return "%d days ago" % (seconds // 86400)


class CompanionApp:
    TICK_MS = 150
    REFRESH_SECONDS = 3

    def __init__(self, root, store, settings, multi=None, opener=None, open_uri=None,
                 update_opener=None, check_update=True):
        self.root = root
        self.store = store
        self.settings = settings
        self.multi = multi or launch.MultiInstance()
        self.opener = opener
        self._update_opener = update_opener  # None -> real urllib; a fake in tests
        self._check_update = check_update
        self.ui = queue.Queue()
        self.statuses = {}
        self._last_refresh = 0.0
        self._closing = False
        self.update_ready = None       # version string once a newer package is downloaded
        self._update_busy = False
        self._bootstrapper = launch.detect_bootstrapper()  # (name, command) or (None, reason)
        self.launches = LaunchQueue(store, lambda: self.settings.get("launch_delay"), self.log_from_thread,
                                    opener=opener, open_uri=open_uri)
        self.k = screen_scale(root)
        root.title("Puppy Companion")
        root.geometry("%dx%d" % (self.px(880), self.px(660)))
        root.minsize(self.px(780), self.px(580))
        root.configure(bg=BG)
        apply_theme(root, self.k)
        try:
            self._icons = [tk.PhotoImage(master=root, data=ICON_64), tk.PhotoImage(master=root, data=ICON_32)]
            root.iconphoto(True, *self._icons)
        except tk.TclError:
            self._icons = []
        self._build()
        self.refresh_status(force=True)
        self.apply_multi_instance(initial=True)
        self.write_roster()
        self.log("Puppy Companion %s ready. %d account(s)." % (update.running_version(), len(self.store.accounts())))
        root.protocol("WM_DELETE_WINDOW", self.close)
        self._after = root.after(self.TICK_MS, self._tick)
        if self._check_update:
            self.check_updates(manual=False)

    def px(self, n):
        return int(round(n * self.k))

    def pad(self, *values):
        return tuple(self.px(v) for v in values)

    # layout ---------------------------------------------------------------------------
    def _build(self):
        top = ttk.Frame(self.root, padding=self.pad(16, 12, 16, 0))
        top.pack(fill="x")
        ttk.Label(top, text="Puppy Companion", style="Title.TLabel").pack(side="left")
        ttk.Label(top, text="v" + update.running_version(), style="Dim.TLabel").pack(
            side="left", padx=self.pad(8, 0), pady=self.pad(6, 0))
        self.restart_btn = ttk.Button(top, text="Restart to update", style="Accent.TButton", command=self._do_restart)
        # packed only once an update has been downloaded
        self.multi_lbl = ttk.Label(top, text="", style="Dim.TLabel")
        self.multi_lbl.pack(side="right", pady=self.pad(6, 0))

        self.nb = ttk.Notebook(self.root)
        self.nb.pack(fill="both", expand=True, padx=self.px(16), pady=self.pad(10, 8))
        self._build_accounts()
        self._build_launch()
        self._build_settings()

        logf = ttk.Frame(self.root, padding=self.pad(16, 0, 16, 14))
        logf.pack(fill="x")
        mono = ("Consolas", 9) if sys.platform == "win32" else ("DejaVu Sans Mono", 9)
        self.log_text = tk.Text(logf, height=7, bg=CARD, fg=DIM, relief="flat", wrap="word", font=mono,
                                highlightthickness=1, highlightbackground=LINE, highlightcolor=LINE,
                                insertbackground=FG, padx=self.px(8), pady=self.px(6))
        sb = ttk.Scrollbar(logf, orient="vertical", command=self.log_text.yview)
        self.log_text.configure(yscrollcommand=sb.set, state="disabled")
        self.log_text.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")

    def _build_accounts(self):
        tab = ttk.Frame(self.nb, padding=self.px(12))
        self.nb.add(tab, text="Accounts")
        cols = (("label", "Name", 150, False), ("user", "Roblox user", 190, False), ("role", "Role", 64, False),
                ("status", "Status", 250, True), ("seen", "Last seen", 90, False))
        self.tree = ttk.Treeview(tab, columns=[c[0] for c in cols], show="headings", selectmode="extended", height=10)
        for key, title, width, stretch in cols:
            self.tree.heading(key, text=title)
            self.tree.column(key, width=self.px(width), anchor="w", stretch=stretch)
        self.tree.tag_configure("online", foreground=GOOD)
        self.tree.tag_configure("idle", foreground=FG)
        self.tree.tag_configure("gone", foreground=DIM)
        sb = ttk.Scrollbar(tab, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=sb.set)
        self.tree.grid(row=0, column=0, sticky="nsew")
        sb.grid(row=0, column=1, sticky="ns")
        tab.columnconfigure(0, weight=1)
        tab.rowconfigure(0, weight=1)
        self.tree.bind("<Double-1>", lambda e: self.rename_selected())
        btns = ttk.Frame(tab)
        btns.grid(row=1, column=0, columnspan=2, sticky="w", pady=self.pad(10, 0))
        for text, cmd, style in (("Add account", self.add_account, "Accent.TButton"),
                                 ("Remove", self.remove_selected, "TButton"),
                                 ("Make main", lambda: self.set_role("main"), "TButton"),
                                 ("Make alt", lambda: self.set_role("alt"), "TButton"),
                                 ("Rename", self.rename_selected, "TButton"),
                                 ("Check logins", self.check_logins, "TButton")):
            ttk.Button(btns, text=text, command=cmd, style=style).pack(side="left", padx=self.pad(0, 6))
        ttk.Label(tab, style="Dim.TLabel", wraplength=self.px(780),
                  text="Status and server come from Puppy Admin running in each Roblox window "
                       "(set the executor folder in Settings). Double-click a row to rename it."
                  ).grid(row=2, column=0, columnspan=2, sticky="w", pady=self.pad(8, 0))

    def _build_launch(self):
        tab = ttk.Frame(self.nb, padding=self.px(12))
        self.nb.add(tab, text="Launch")
        where = ttk.LabelFrame(tab, text="WHERE TO", padding=self.px(12))
        where.pack(fill="x")
        self.place_var = tk.StringVar(value=str(self.settings.get("place") or ""))
        self.job_var = tk.StringVar(value=str(self.settings.get("job") or ""))
        ttk.Label(where, text="Game (place ID or game link)").grid(row=0, column=0, sticky="w")
        ttk.Entry(where, textvariable=self.place_var).grid(row=0, column=1, sticky="we", padx=self.px(10))
        ttk.Label(where, text="Server ID (optional)").grid(row=1, column=0, sticky="w", pady=self.pad(8, 0))
        ttk.Entry(where, textvariable=self.job_var).grid(row=1, column=1, sticky="we", padx=self.px(10), pady=self.pad(8, 0))
        ttk.Button(where, text="Use main's server", command=self.fill_main_server).grid(row=1, column=2, pady=self.pad(8, 0))
        where.columnconfigure(1, weight=1)

        act = ttk.LabelFrame(tab, text="LAUNCH", padding=self.px(12))
        act.pack(fill="x", pady=self.pad(12, 0))
        row = ttk.Frame(act)
        row.pack(fill="x")
        ttk.Button(row, text="Launch selected accounts", command=self.launch_selected,
                   style="Accent.TButton").pack(side="left")
        ttk.Button(row, text="Launch all alts", command=self.launch_alts).pack(side="left", padx=self.px(6))
        ttk.Button(row, text="Send alts to main's server", command=self.alts_to_main).pack(side="left")
        row2 = ttk.Frame(act)
        row2.pack(fill="x", pady=self.pad(12, 0))
        ttk.Label(row2, text="Seconds between launches").pack(side="left")
        self.delay_var = tk.StringVar(value=str(self.settings.get("launch_delay")))
        sp = ttk.Spinbox(row2, from_=3, to=60, width=5, textvariable=self.delay_var, command=self._save_delay)
        sp.pack(side="left", padx=self.px(8))
        sp.bind("<FocusOut>", lambda e: self._save_delay())
        sp.bind("<Return>", lambda e: self._save_delay())
        self.queue_lbl = ttk.Label(row2, text="Nothing waiting", style="Dim.TLabel")
        self.queue_lbl.pack(side="left", padx=self.pad(14, 0))
        ttk.Button(row2, text="Stop", command=self.stop_queue).pack(side="right")
        ttk.Label(act, style="Dim.TLabel", wraplength=self.px(780),
                  text="Launching a few seconds apart lets each Roblox window start before the next one. "
                       "Accounts already in the target server are skipped."
                  ).pack(anchor="w", pady=self.pad(10, 0))

        win = ttk.LabelFrame(tab, text="ROBLOX WINDOWS", padding=self.px(12))
        win.pack(fill="x", pady=self.pad(12, 0))
        ttk.Button(win, text="Close every Roblox window", command=self.close_all, style="Danger.TButton").pack(side="left")
        ttk.Label(win, text="Ends every RobloxPlayerBeta.exe on this PC.", style="Dim.TLabel").pack(side="left", padx=self.px(12))

    def _build_settings(self):
        tab = ttk.Frame(self.nb, padding=self.px(12))
        self.nb.add(tab, text="Settings")
        ws = ttk.LabelFrame(tab, text="EXECUTOR FOLDER (ITS WORKSPACE)", padding=self.px(12))
        ws.pack(fill="x")
        self.ws_var = tk.StringVar(value=str(self.settings.get("workspace") or ""))
        entry = ttk.Entry(ws, textvariable=self.ws_var)
        entry.grid(row=0, column=0, sticky="we")
        entry.bind("<Return>", lambda e: self.set_workspace(self.ws_var.get()))
        entry.bind("<FocusOut>", lambda e: self.set_workspace(self.ws_var.get(), quiet=True))
        ttk.Button(ws, text="Browse", command=self.browse_workspace).grid(row=0, column=1, padx=self.pad(8, 0))
        ttk.Button(ws, text="Find", command=self.find_workspace).grid(row=0, column=2, padx=self.pad(6, 0))
        self.ws_lbl = ttk.Label(ws, text="", style="Dim.TLabel", wraplength=self.px(760))
        self.ws_lbl.grid(row=1, column=0, columnspan=3, sticky="w", pady=self.pad(8, 0))
        aerow = ttk.Frame(ws)
        aerow.grid(row=2, column=0, columnspan=3, sticky="w", pady=self.pad(10, 0))
        ttk.Button(aerow, text="Add Puppy Admin to auto-execute", command=self.install_autoexec).pack(side="left")
        ttk.Button(aerow, text="Choose autoexec folder", command=self.choose_autoexec).pack(side="left", padx=self.pad(6, 0))
        ws.columnconfigure(0, weight=1)

        mi = ttk.LabelFrame(tab, text="SEVERAL ROBLOX WINDOWS", padding=self.px(12))
        mi.pack(fill="x", pady=self.pad(12, 0))
        self.multi_var = tk.BooleanVar(value=bool(self.settings.get("multi_instance")))
        ttk.Checkbutton(mi, text="Let more than one Roblox window run",
                        variable=self.multi_var, command=self.apply_multi_instance).grid(row=0, column=0, columnspan=3, sticky="w")
        self.boot_var = tk.BooleanVar(value=bool(self.settings.get("bootstrapper_multi")))
        ttk.Checkbutton(mi, text="Fishstrap / Bloxstrap handles multiple windows (don't hold the lock here)",
                        variable=self.boot_var, command=self.apply_multi_instance).grid(row=1, column=0, columnspan=3, sticky="w", pady=self.pad(6, 0))
        self.boot_lbl = ttk.Label(mi, text="", style="Dim.TLabel", wraplength=self.px(760))
        self.boot_lbl.grid(row=2, column=0, columnspan=3, sticky="w", pady=self.pad(6, 0))
        ttk.Label(mi, text="Lock names").grid(row=3, column=0, sticky="w", pady=self.pad(10, 0))
        self.names_var = tk.StringVar(value=str(self.settings.get("singleton_names")))
        ttk.Entry(mi, textvariable=self.names_var).grid(row=3, column=1, sticky="we", padx=self.px(10), pady=self.pad(10, 0))
        ttk.Button(mi, text="Apply", command=self.apply_multi_instance).grid(row=3, column=2, pady=self.pad(10, 0))
        ttk.Label(mi, style="Dim.TLabel", wraplength=self.px(760),
                  text="Open the companion before any Roblox window. If Roblox was already running, "
                       "close every Roblox window and press Apply. With Fishstrap, turn on its own "
                       "“Multiple Roblox instances” setting and tick the box above."
                  ).grid(row=4, column=0, columnspan=3, sticky="w", pady=self.pad(8, 0))
        mi.columnconfigure(1, weight=1)

        dt = ttk.LabelFrame(tab, text="YOUR DATA", padding=self.px(12))
        dt.pack(fill="x", pady=self.pad(12, 0))
        ttk.Label(dt, wraplength=self.px(760), text=(
            "Accounts are saved in %s, with each login cookie encrypted for your Windows user "
            "(Windows DPAPI). Cookies only ever go to roblox.com and are never written to the executor folder."
            % self.store.folder)).pack(anchor="w")
        ttk.Button(dt, text="Open data folder", command=lambda: self._open_folder(self.store.folder)).pack(anchor="w", pady=self.pad(10, 0))

        up = ttk.LabelFrame(tab, text="UPDATES", padding=self.px(12))
        up.pack(fill="x", pady=self.pad(12, 0))
        self.update_lbl = ttk.Label(up, wraplength=self.px(760), style="Dim.TLabel",
                                    text="Running version %s. Updates are the app's code, pulled from GitHub: "
                                         "no new download of the program." % update.running_version())
        self.update_lbl.pack(anchor="w")
        row = ttk.Frame(up)
        row.pack(anchor="w", pady=self.pad(10, 0))
        self.update_btn = ttk.Button(row, text="Check for updates", command=lambda: self.check_updates(manual=True))
        self.update_btn.pack(side="left")
        self.update_restart_btn = ttk.Button(row, text="Restart to update", style="Accent.TButton", command=self._do_restart)
        # shown next to the button once an update is downloaded

    # plumbing ---------------------------------------------------------------------------
    def _tick(self):
        if self._closing:
            return
        try:
            while True:
                kind, payload = self.ui.get_nowait()
                if kind == "log":
                    self.log(payload)
                elif kind == "call":
                    fn, args = payload
                    fn(*args)
        except queue.Empty:
            pass
        n = self.launches.pending()
        self.queue_lbl.configure(text=("%d launch%s waiting" % (n, "" if n == 1 else "es")) if n else "Nothing waiting")
        if time.time() - self._last_refresh >= self.REFRESH_SECONDS:
            self.refresh_status()
        self._after = self.root.after(self.TICK_MS, self._tick)

    def run_bg(self, work, done):
        """work() runs on a thread; done(result, error_text) runs on the window's thread."""
        def runner():
            try:
                res, err = work(), None
            except RobloxError as e:
                res, err = None, str(e)
            except Exception as e:
                res, err = None, redact("%s: %s" % (type(e).__name__, e))
            self.ui.put(("call", (done, (res, err))))
        threading.Thread(target=runner, daemon=True).start()

    def log(self, text):
        line = time.strftime("%H:%M:%S  ") + redact(text)
        self.log_text.configure(state="normal")
        self.log_text.insert("end", line + "\n")
        self.log_text.see("end")
        self.log_text.configure(state="disabled")
        path = os.path.join(self.store.folder, "companion.log")
        try:
            if os.path.exists(path) and os.path.getsize(path) > 1_000_000:
                os.replace(path, path + ".old")
            with open(path, "a", encoding="utf-8") as f:
                f.write(time.strftime("%Y-%m-%d ") + line + "\n")
        except OSError:
            pass

    def log_from_thread(self, text):
        self.ui.put(("log", text))

    def selected_ids(self):
        return [int(i) for i in self.tree.selection()]

    def _open_folder(self, path):
        try:
            if sys.platform == "win32":
                os.startfile(path)
            else:
                subprocess.Popen(["xdg-open", path])
        except OSError as e:
            self.log("Could not open %s: %s" % (path, e))

    # updates ----------------------------------------------------------------------------
    def check_updates(self, manual=True):
        """Looks for a newer package on GitHub and downloads it. manual=False is the quiet
        startup check (it says nothing unless there is an update)."""
        if self._update_busy or self.update_ready:
            if manual and self.update_ready:
                self.log("Update %s is downloaded. Press Restart to update." % self.update_ready)
            return
        self._update_busy = True
        if manual:
            self.update_btn.state(["disabled"])
            self.update_lbl.configure(text="Checking GitHub for a newer version...", style="Dim.TLabel")

        def work():
            manifest = update.check(opener=self._http_opener())
            if not manifest:
                return None
            return update.download(manifest, opener=self._http_opener())

        self.run_bg(work, lambda version, err: self._update_done(version, err, manual))

    def _http_opener(self):
        # None -> update.py uses real urllib; a fake opener is injected only in tests
        return self._update_opener

    def _update_done(self, version, err, manual):
        self._update_busy = False
        if self.update_btn:
            self.update_btn.state(["!disabled"])
        if err:
            if manual:
                self.update_lbl.configure(text="Update check failed: %s" % err, style="Bad.TLabel")
                self.log("Update check failed: %s" % err)
            return
        if not version:
            if manual:
                self.update_lbl.configure(text="You are on the latest version (%s)." % update.running_version(),
                                          style="Good.TLabel")
                self.log("No update: already on %s." % update.running_version())
            return
        self.update_ready = version
        self.update_lbl.configure(text="Update %s downloaded. Restart to use it." % version, style="Good.TLabel")
        self.update_restart_btn.pack(side="left", padx=self.pad(8, 0))
        self.restart_btn.pack(side="right", padx=self.pad(0, 10), pady=self.pad(4, 0))
        self.log("Update %s downloaded. Press 'Restart to update' to use it." % version)

    def _do_restart(self):
        if not self.update_ready:
            return
        self.log("Restarting into update %s..." % self.update_ready)
        self._closing = True
        try:
            self.root.after_cancel(self._after)
        except (tk.TclError, AttributeError):
            pass
        self.launches.cancel()
        self.multi.release()
        self.root.destroy()
        if getattr(sys, "frozen", False):
            args = [sys.executable] + sys.argv[1:]
        else:
            args = [sys.executable] + sys.argv
        try:
            os.execv(sys.executable, args)
        except OSError:
            subprocess.Popen(args)
            sys.exit(0)

    # accounts ---------------------------------------------------------------------------
    def _status_text(self, acc, st, main_job):
        if not st:
            return ("Puppy Admin not seen" if self.settings.get("workspace") else "-"), "idle"
        if not st["fresh"]:
            return "Not running", "gone"
        if not st["online"]:
            return "Left the game", "gone"
        text = "In game, place %d" % st["placeId"] if st["placeId"] else "In game"
        if acc.role == "alt" and main_job and st["jobId"] == main_job:
            text += " (main's server)"
        return text, "online"

    def refresh_status(self, force=False):
        self._last_refresh = time.time()
        ws = self.settings.get("workspace")
        try:
            self.statuses = workspace.read_statuses(ws) if ws else {}
        except OSError:
            self.statuses = {}
        accounts = sorted(self.store.accounts(), key=lambda a: (a.role != "main", a.label.lower()))
        main = self.store.main()
        main_st = self.statuses.get(main.user_id) if main else None
        main_job = main_st["jobId"] if main_st and main_st["fresh"] and main_st["online"] else ""
        wanted = [str(a.user_id) for a in accounts]
        if force or list(self.tree.get_children()) != wanted:
            sel = set(self.tree.selection())
            self.tree.delete(*self.tree.get_children())
            for a in accounts:
                self.tree.insert("", "end", iid=str(a.user_id))
            self.tree.selection_set([i for i in sel if i in wanted])
        now = time.time()
        for a in accounts:
            st = self.statuses.get(a.user_id)
            text, tag = self._status_text(a, st, main_job)
            seen = ago(now - st["time"]) if st and st["time"] else ""
            user = a.name if a.display_name in ("", a.name) else "%s (@%s)" % (a.display_name, a.name)
            self.tree.item(str(a.user_id), values=(a.label, user, a.role, text, seen), tags=(tag,))
        self.update_workspace_label()

    def write_roster(self):
        ws = self.settings.get("workspace")
        if ws and os.path.isdir(ws):
            try:
                workspace.write_roster(ws, self.store)
            except OSError as e:
                self.log("Could not write the account list for Puppy Admin: %s" % e)

    def accounts_changed(self):
        self.refresh_status(force=True)
        self.write_roster()

    def add_account(self):
        dlg = tk.Toplevel(self.root)
        dlg.title("Add account")
        dlg.configure(bg=BG)
        dlg.transient(self.root)
        dlg.resizable(False, False)
        body = ttk.Frame(dlg, padding=self.px(16))
        body.pack(fill="both", expand=True)
        ttk.Label(body, text="Login cookie (.ROBLOSECURITY) of the account").grid(row=0, column=0, columnspan=3, sticky="w")
        cookie_var = tk.StringVar()
        entry = ttk.Entry(body, textvariable=cookie_var, show="•", width=58)
        entry.grid(row=1, column=0, columnspan=2, sticky="we", pady=self.pad(6, 0))

        def paste():
            try:
                cookie_var.set(self.root.clipboard_get().strip())
            except tk.TclError:
                pass
        ttk.Button(body, text="Paste", command=paste).grid(row=1, column=2, padx=self.pad(6, 0), pady=self.pad(6, 0))
        ttk.Label(body, text=COOKIE_HELP, style="Dim.TLabel", wraplength=self.px(470)).grid(row=2, column=0, columnspan=3, sticky="w", pady=self.pad(8, 0))
        role_var = tk.StringVar(value="alt" if self.store.main() else "main")
        roles = ttk.Frame(body)
        roles.grid(row=3, column=0, columnspan=3, sticky="w", pady=self.pad(12, 0))
        ttk.Label(roles, text="Role").pack(side="left", padx=self.pad(0, 10))
        ttk.Radiobutton(roles, text="Alt", value="alt", variable=role_var).pack(side="left")
        ttk.Radiobutton(roles, text="Main", value="main", variable=role_var).pack(side="left", padx=self.pad(10, 0))
        ttk.Label(body, text="Name in the list (optional)").grid(row=4, column=0, sticky="w", pady=self.pad(12, 0))
        alias_var = tk.StringVar()
        ttk.Entry(body, textvariable=alias_var, width=26).grid(row=4, column=1, sticky="w", pady=self.pad(12, 0))
        msg = ttk.Label(body, text="", style="Dim.TLabel", wraplength=self.px(470))
        msg.grid(row=5, column=0, columnspan=3, sticky="w", pady=self.pad(12, 0))
        buttons = ttk.Frame(body)
        buttons.grid(row=6, column=0, columnspan=3, sticky="e", pady=self.pad(12, 0))
        add_btn = ttk.Button(buttons, text="Add", style="Accent.TButton")
        add_btn.pack(side="right")
        ttk.Button(buttons, text="Cancel", command=dlg.destroy).pack(side="right", padx=self.pad(0, 6))

        def done(cookie, user, err):
            if not dlg.winfo_exists():
                return
            if not err:
                try:
                    acc = self.store.add_or_update(cookie, user, role_var.get(), alias_var.get().strip())
                except (ProtectorError, OSError, ValueError) as e:
                    err = redact(str(e))
            if err:
                msg.configure(text=err, style="Bad.TLabel")
                add_btn.state(["!disabled"])
                entry.state(["!disabled"])
                return
            cookie_var.set("")
            self.log("Added %s (%s, user %d)." % (acc.label, acc.role, acc.user_id))
            self.accounts_changed()
            dlg.destroy()

        def submit(*_):
            if add_btn.instate(["disabled"]):
                return
            cookie = cookie_var.get().strip()
            if not cookie:
                msg.configure(text="Paste the cookie first.", style="Bad.TLabel")
                return
            add_btn.state(["disabled"])
            entry.state(["disabled"])
            msg.configure(text="Checking the login with Roblox...", style="Dim.TLabel")
            self.run_bg(lambda: RobloxSession(cookie, opener=self.opener).authenticated_user(),
                        lambda user, err: done(cookie, user, err))

        add_btn.configure(command=submit)
        entry.bind("<Return>", submit)
        self.center_over_root(dlg)
        entry.focus_set()
        try:
            dlg.wait_visibility()
            dlg.grab_set()
        except tk.TclError:
            pass

    def center_over_root(self, win):
        win.update_idletasks()
        x = self.root.winfo_rootx() + (self.root.winfo_width() - win.winfo_reqwidth()) // 2
        y = self.root.winfo_rooty() + (self.root.winfo_height() - win.winfo_reqheight()) // 3
        win.geometry("+%d+%d" % (max(0, x), max(0, y)))

    def remove_selected(self):
        ids = self.selected_ids()
        if not ids:
            self.log("Select the accounts to remove first.")
            return
        names = ", ".join(self.store.get(i).label for i in ids if self.store.get(i))
        if not messagebox.askyesno("Remove accounts", "Remove %s from the companion?\nTheir saved logins are deleted." % names,
                                   parent=self.root):
            return
        for i in ids:
            self.store.remove(i)
        self.log("Removed %s." % names)
        self.accounts_changed()

    def set_role(self, role):
        ids = self.selected_ids()
        if not ids:
            self.log("Select an account first.")
            return
        if role == "main":
            ids = ids[:1]
        for i in ids:
            self.store.set_role(i, role)
        self.log("%s: %s." % (", ".join(self.store.get(i).label for i in ids), role))
        self.accounts_changed()

    def rename_selected(self):
        ids = self.selected_ids()
        if len(ids) != 1:
            self.log("Select one account to rename.")
            return
        acc = self.store.get(ids[0])
        name = simpledialog.askstring("Rename", "Name in the list for %s:" % acc.name, initialvalue=acc.alias, parent=self.root)
        if name is None:
            return
        self.store.set_alias(acc.user_id, name)
        self.accounts_changed()

    def check_logins(self):
        accounts = self.store.accounts()
        if not accounts:
            self.log("No accounts yet.")
            return
        self.log("Checking %d login(s)..." % len(accounts))

        def work():
            out = []
            for a in accounts:
                try:
                    user = RobloxSession(self.store.cookie(a.user_id), opener=self.opener).authenticated_user()
                    ok = user["id"] == a.user_id
                    out.append("%s: %s" % (a.label, "login OK" if ok else "the cookie now belongs to %s" % user["name"]))
                except (RobloxError, ProtectorError, KeyError, ValueError) as e:
                    out.append("%s: %s" % (a.label, e))
            return out

        self.run_bg(work, lambda res, err: [self.log(x) for x in (res or [err])])

    # launching --------------------------------------------------------------------------
    def _save_delay(self):
        try:
            v = max(3, min(60, int(float(self.delay_var.get()))))
        except ValueError:
            v = int(self.settings.get("launch_delay"))
        self.delay_var.set(str(v))
        self.settings.set("launch_delay", v)

    def _target(self):
        place = launch.parse_place(self.place_var.get())
        if not place:
            self.log("Enter a game first: a place ID or a game link.")
            return None
        job_text = self.job_var.get().strip()
        job = launch.parse_job(job_text) if job_text else ""
        if job is None:
            self.log("That server ID does not look like one (it is a long ID like 1b2c3d4e-....). Leave it empty for any server.")
            return None
        self.settings.set("place", self.place_var.get().strip())
        self.settings.set("job", job_text)
        return place, job

    def _queue(self, accounts, place, job):
        jobs, skipped = [], []
        for a in accounts:
            st = self.statuses.get(a.user_id)
            live = st and st["fresh"] and st["online"]
            # launching an account that is already there would only end its session and rejoin
            if live and (st["jobId"].lower() == job if job else st["placeId"] == place):
                skipped.append(a.label)
                continue
            jobs.append(LaunchJob(a.user_id, a.label, place, job))
        if skipped:
            self.log("Already there: %s." % ", ".join(skipped))
        if jobs:
            self.log("Launching %s into %s..." % (", ".join(j.label for j in jobs),
                                                   ("server " + job[:8]) if job else "place %d" % place))
            self.launches.add(jobs)

    def launch_selected(self):
        accounts = [self.store.get(i) for i in self.selected_ids()]
        accounts = [a for a in accounts if a]
        if not accounts:
            self.log("Select the accounts to launch on the Accounts tab.")
            return
        t = self._target()
        if t:
            self._queue(accounts, *t)

    def launch_alts(self):
        alts = self.store.alts()
        if not alts:
            self.log("No alts yet: add accounts with the Alt role.")
            return
        t = self._target()
        if t:
            self._queue(alts, *t)

    def main_server(self, done):
        """done((place, job) or None, error) - from Puppy Admin's report, else Roblox presence."""
        main = self.store.main()
        if not main:
            done(None, "Mark one account as main first (Accounts > Make main).")
            return
        st = self.statuses.get(main.user_id)
        if st and st["fresh"] and st["online"] and st["placeId"] and st["jobId"]:
            if st["privateServer"]:
                done(None, "Your main is in a private server: alts cannot be sent there by server ID.")
            else:
                done((st["placeId"], st["jobId"].lower()), None)
            return

        def ask():
            pres = RobloxSession(self.store.cookie(main.user_id), opener=self.opener).presence([main.user_id])
            p = pres[0] if pres else {}
            if p.get("userPresenceType") == 2 and p.get("placeId") and p.get("gameId"):
                return int(p["placeId"]), str(p["gameId"]).lower()
            raise RobloxError("Roblox does not show which server your main is in (not in a game, or hidden by "
                              "its privacy settings). Run Puppy Admin on your main: it reports its server here.")
        self.run_bg(ask, done)

    def fill_main_server(self):
        def done(target, err):
            if err:
                self.log(err)
                return
            self.place_var.set(str(target[0]))
            self.job_var.set(target[1])
            self.log("Main's server: place %d, server %s." % target)
        self.main_server(done)

    def alts_to_main(self):
        alts = self.store.alts()
        if not alts:
            self.log("No alts yet: add accounts with the Alt role.")
            return

        def done(target, err):
            if err:
                self.log(err)
                return
            self.place_var.set(str(target[0]))
            self.job_var.set(target[1])
            self._queue(alts, target[0], target[1])
        self.main_server(done)

    def stop_queue(self):
        n = self.launches.cancel()
        self.log("Stopped: %d launch%s dropped." % (n, "" if n == 1 else "es") if n else "Nothing was waiting.")

    def close_all(self):
        if not messagebox.askyesno("Close Roblox", "Close every Roblox window on this PC?", parent=self.root):
            return
        self.run_bg(launch.close_all_roblox, lambda n, err: self.log(err or "Closed %d Roblox window%s." % (n, "" if n == 1 else "s")))

    # settings ---------------------------------------------------------------------------
    def set_workspace(self, path, quiet=False):
        path = (path or "").strip().strip('"')
        if path == (self.settings.get("workspace") or ""):
            return
        if path and not os.path.isdir(path):
            if not quiet:
                self.log("Folder not found: %s" % path)
            self.ws_var.set(self.settings.get("workspace") or "")
            return
        self.settings.set("workspace", path)
        self.ws_var.set(path)
        self.refresh_status(force=True)
        self.write_roster()
        self.log("Executor folder: %s" % (path or "none"))

    def update_workspace_label(self):
        ws = self.settings.get("workspace")
        if not ws:
            self.ws_lbl.configure(text="Not set. Status, \"main's server\" and auto-execute need it: it is the "
                                       "executor's workspace folder, the one that holds the PuppyAdmin folder.",
                                  style="Warn.TLabel")
        elif not os.path.isdir(os.path.join(ws, "PuppyAdmin")):
            self.ws_lbl.configure(text="No PuppyAdmin folder in it yet: run Puppy Admin once with this executor.",
                                  style="Warn.TLabel")
        else:
            n = len([s for s in self.statuses.values() if s["fresh"]])
            self.ws_lbl.configure(text="Puppy Admin found. %d window%s reporting right now." % (n, "" if n == 1 else "s"),
                                  style="Good.TLabel")

    def browse_workspace(self):
        path = filedialog.askdirectory(parent=self.root, title="The executor's workspace folder",
                                       initialdir=self.settings.get("workspace") or os.path.expanduser("~"))
        if path:
            self.set_workspace(os.path.normpath(path))

    def find_workspace(self):
        self.log("Looking for executor folders that hold Puppy Admin...")

        def done(found, err):
            if err or not found:
                self.log(err or "None found. Use Browse and pick the executor's workspace folder.")
                return
            self.set_workspace(found[0])
            if len(found) > 1:
                self.log("Also found: %s" % "; ".join(found[1:4]))
        self.run_bg(workspace.find_candidates, done)

    def install_autoexec(self):
        ws = self.settings.get("workspace")
        if not ws or not os.path.isdir(ws):
            self.log("Set the executor folder first.")
            return
        override = self.settings.get("autoexec_dir") or None
        if override and not os.path.isdir(override):
            override = None
        detected = bool(override) or bool(workspace.find_autoexec_dirs(ws))
        if not detected:
            # nothing found: auto-execute belongs to the EXECUTOR, so let the user point at it
            pick = messagebox.askyesno(
                "Auto-execute",
                "No auto-execute folder was found near the executor folder.\n\n"
                "Auto-execute is a feature of the EXECUTOR you inject Puppy Admin with "
                "(Fishstrap/Bloxstrap only launch Roblox, they have no auto-execute).\n\n"
                "Yes: pick your executor's autoexec folder.\n"
                "No: create %s and use that." % workspace.autoexec_dir(ws),
                parent=self.root)
            if pick:
                picked = filedialog.askdirectory(parent=self.root, title="Your executor's autoexec folder",
                                                 initialdir=os.path.dirname(os.path.normpath(ws)))
                if not picked:
                    return
                override = os.path.normpath(picked)
        try:
            path = workspace.install_autoexec(ws, LOADER, create=True, override=override)
        except OSError as e:
            self.log("Could not write the auto-execute file: %s" % e)
            return
        self.settings.set("autoexec_dir", os.path.dirname(path))
        self.log("Loader written to %s" % path)
        self.log("It runs through your EXECUTOR, not Fishstrap. If it doesn't auto-run: that folder "
                 "isn't your executor's autoexec (use Browse to pick the right one), or your executor "
                 "wants a .txt file - rename PuppyAdmin.lua to PuppyAdmin.txt there.")

    def choose_autoexec(self):
        start = self.settings.get("autoexec_dir") or os.path.dirname(os.path.normpath(self.settings.get("workspace") or os.path.expanduser("~")))
        picked = filedialog.askdirectory(parent=self.root, title="Your executor's autoexec folder", initialdir=start)
        if picked:
            self.settings.set("autoexec_dir", os.path.normpath(picked))
            self.log("Auto-execute folder set to %s" % picked)

    def update_bootstrapper_label(self):
        name, detail = self._bootstrapper
        if name in launch.BOOTSTRAPPERS:
            self.boot_lbl.configure(text="%s launches Roblox on this PC; it can manage the windows for you." % name, style="Good.TLabel")
        elif name == "Roblox":
            self.boot_lbl.configure(text="Vanilla Roblox launches on this PC. Use the companion's lock, or install Fishstrap for multi-window.", style="Dim.TLabel")
        elif name == "unknown":
            self.boot_lbl.configure(text="A custom launcher handles Roblox links here.", style="Dim.TLabel")
        else:
            self.boot_lbl.configure(text=str(detail), style="Dim.TLabel")

    def apply_multi_instance(self, initial=False):
        names = [n.strip() for n in self.names_var.get().split(",") if n.strip()]
        by_boot = bool(self.boot_var.get())
        if not initial:
            self.settings.set("singleton_names", ", ".join(names))
            self.settings.set("multi_instance", bool(self.multi_var.get()))
            self.settings.set("bootstrapper_multi", by_boot)
        self.update_bootstrapper_label()
        if not self.multi_var.get():
            self.multi.release()
            self.multi_lbl.configure(text="One Roblox window at a time", style="Dim.TLabel")
            return
        if by_boot:
            # Fishstrap/Bloxstrap holds the lock itself; the companion stays out of the way
            self.multi.release()
            name = self._bootstrapper[0] if self._bootstrapper else "the bootstrapper"
            self.multi_lbl.configure(text="Several windows: handled by %s" % name, style="Good.TLabel")
            return
        if sys.platform != "win32":
            self.multi_lbl.configure(text="Several windows: Windows only", style="Dim.TLabel")
            return
        report = self.multi.hold(names)
        states = [s for _, _, s in report]
        if "busy" in states:
            self.multi_lbl.configure(text="Roblox was already open: close it, then Apply in Settings", style="Warn.TLabel")
        elif "held" in states:
            self.multi_lbl.configure(text="Several Roblox windows: on", style="Good.TLabel")
        else:
            self.multi_lbl.configure(text="Could not take Roblox's window lock", style="Bad.TLabel")
        if not initial or "held" not in states:
            self.log("Window lock: " + ", ".join("%s %s %s" % (n, k, s) for n, k, s in report))

    def close(self):
        self._closing = True
        try:
            self.root.after_cancel(self._after)
        except (tk.TclError, AttributeError):
            pass
        self.launches.cancel()
        self.multi.release()
        self.root.destroy()


def _dpi_aware():
    if sys.platform == "win32":
        try:
            import ctypes
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except (AttributeError, OSError):
            pass


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "--selftest":
        from .selftest import run
        return run(argv[1] if len(argv) > 1 else None)
    _dpi_aware()
    root = tk.Tk()
    try:
        protector = default_protector()
        store = AccountStore(protector)
        settings = Settings()
    except (ProtectorError, OSError, ValueError) as e:
        root.withdraw()
        messagebox.showerror("Puppy Companion", str(e))
        return 1
    CompanionApp(root, store, settings)
    root.mainloop()
    return 0
