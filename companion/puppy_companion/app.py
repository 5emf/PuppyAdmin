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

from . import fonts, kh_data, khart, launch, look, manage, update, workspace
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


# colours in use (the Look tab replaces them through apply_theme)
HOVER, ACCENT_HI, ACCENT_LO, ON_ACCENT, TAB_HOVER = "#2f303c", "#74b7ff", "#3f8fe6", "#0b0d12", "#23242c"


def apply_theme(root, k=1.0, family=None, pal=None, scale=1.0):
    """pal: look.palette(...) colours (None keeps the current ones); scale: text size."""
    global BG, CARD, FIELD, LINE, FG, DIM, ACCENT, GOOD, SELECT, HOVER, ACCENT_HI, ACCENT_LO, ON_ACCENT, TAB_HOVER
    if pal:
        BG, CARD, FIELD, LINE = pal["BG"], pal["CARD"], pal["FIELD"], pal["LINE"]
        FG, DIM, ACCENT, GOOD, SELECT = pal["FG"], pal["DIM"], pal["ACCENT"], pal["GOOD"], pal["SELECT"]
        HOVER, ACCENT_HI, ACCENT_LO = pal["HOVER"], pal["ACCENT_HI"], pal["ACCENT_LO"]
        ON_ACCENT, TAB_HOVER = pal["ON_ACCENT"], pal["TAB_HOVER"]

    def p(n):
        return int(round(n * k))

    def fs(n):
        return max(6, int(round(n * scale)))
    style = ttk.Style(root)
    try:
        style.theme_use("clam")
    except tk.TclError:
        pass
    family = family or fonts.default_family()
    base = (family, fs(10))
    root.configure(bg=BG)
    # named fonts, not the option database: an option-database font would override every ttk style's font
    for name in ("TkDefaultFont", "TkTextFont", "TkMenuFont", "TkHeadingFont", "TkCaptionFont", "TkTooltipFont"):
        try:
            tkfont.nametofont(name, root=root).configure(family=family, size=fs(10))
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
    style.configure("Title.TLabel", font=(family, fs(15), "bold"))
    style.configure("TLabelframe", background=BG, bordercolor=LINE, relief="solid", borderwidth=1)
    style.configure("TLabelframe.Label", background=BG, foreground=DIM, font=(family, fs(9), "bold"))
    style.configure("TButton", background=FIELD, foreground=FG, bordercolor=LINE, padding=(p(12), p(6)), focusthickness=0)
    style.map("TButton", background=[("disabled", CARD), ("pressed", LINE), ("active", HOVER)],
              foreground=[("disabled", DIM)])
    style.configure("Accent.TButton", background=ACCENT, foreground=ON_ACCENT, bordercolor=ACCENT)
    style.map("Accent.TButton", background=[("pressed", ACCENT_LO), ("active", ACCENT_HI)])
    style.configure("Danger.TButton", background="#47222a", foreground="#ffd9d9", bordercolor="#5c2a33")
    style.map("Danger.TButton", background=[("pressed", "#3a1b21"), ("active", "#5c2a33")])
    style.configure("TEntry", fieldbackground=FIELD, foreground=FG, bordercolor=LINE, insertcolor=FG, padding=p(5))
    style.map("TEntry", bordercolor=[("focus", ACCENT)], lightcolor=[("focus", FIELD)])
    style.configure("TCombobox", fieldbackground=FIELD, background=FIELD, foreground=FG, bordercolor=LINE,
                    arrowcolor=FG, selectbackground=FIELD, selectforeground=FG, padding=p(4))
    style.map("TCombobox", fieldbackground=[("readonly", FIELD), ("disabled", CARD)],
              foreground=[("disabled", DIM), ("readonly", FG)], background=[("readonly", FIELD)],
              selectbackground=[("readonly", FIELD)], selectforeground=[("readonly", FG)],
              bordercolor=[("focus", ACCENT)])
    root.option_add("*TCombobox*Listbox.background", CARD)
    root.option_add("*TCombobox*Listbox.foreground", FG)
    root.option_add("*TCombobox*Listbox.selectBackground", ACCENT)
    root.option_add("*TCombobox*Listbox.selectForeground", ON_ACCENT)
    style.configure("TSpinbox", fieldbackground=FIELD, foreground=FG, bordercolor=LINE, arrowcolor=FG,
                    insertcolor=FG, padding=p(4), background=FIELD)
    style.map("TSpinbox", bordercolor=[("focus", ACCENT)], lightcolor=[("focus", FIELD)])
    style.configure("Horizontal.TScale", background=ACCENT, troughcolor=FIELD, bordercolor=LINE,
                    lightcolor=ACCENT, darkcolor=ACCENT)
    # clam draws check and radio indicators with -indicatorbackground (box) and -indicatorforeground (mark)
    for cls in ("TCheckbutton", "TRadiobutton"):
        style.configure(cls, background=BG, foreground=FG, indicatorbackground=FIELD, indicatorforeground=ACCENT,
                        upperbordercolor=LINE, lowerbordercolor=LINE, padding=p(2))
        style.map(cls, background=[("active", BG)], foreground=[("disabled", DIM)],
                  indicatorbackground=[("pressed", LINE), ("disabled", CARD)])
    style.configure("TNotebook", background=BG, bordercolor=LINE, tabmargins=(0, 0, 0, 0))
    style.configure("TNotebook.Tab", background=CARD, foreground=DIM, padding=(p(18), p(7)), bordercolor=LINE)
    # clam shrinks the selected tab and gives it a light top edge: keep it the same size and dark
    style.map("TNotebook.Tab", background=[("selected", FIELD), ("active", TAB_HOVER)], foreground=[("selected", FG)],
              lightcolor=[("selected", FIELD), ("", CARD)], padding=[("selected", (p(18), p(7)))])
    style.configure("Treeview", background=CARD, fieldbackground=CARD, foreground=FG, rowheight=p(int(26 * max(1.0, scale))),
                    bordercolor=LINE)
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
        self._rejoin = {}
        self.script_latest = None  # newest Puppy Admin SCRIPT_BUILD on GitHub, once known
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
        self._raw = []            # plain Tk widgets that ttk styles do not reach: (widget, {option: colour name})
        self._header_photo = None
        self.cursor_spec = ""
        apply_theme(root, self.k, self._font_family(self.settings.get("font")), self.look_palette(),
                    look.text_scale(self.settings.get("text_scale")))
        try:
            self._icons = [tk.PhotoImage(master=root, data=ICON_64), tk.PhotoImage(master=root, data=ICON_32)]
            root.iconphoto(True, *self._icons)
        except tk.TclError:
            self._icons = []
        self._kh = None           # Kingdom Hearts style state (images, saved layouts), see apply_kh
        self._kh_target = None
        self._kh_ticking = False
        self._build()
        self.apply_kh()
        self.apply_cursor()
        self.apply_header_image()
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
        self.title_lbl = ttk.Label(top, text="Puppy Companion", style="Title.TLabel")
        self.title_lbl.pack(side="left")
        # the Kingdom Hearts style's title: glossy capsule + orange line (packed by apply_kh)
        self.kh_title = tk.Canvas(top, highlightthickness=0, borderwidth=0, bg=BG)
        self.version_lbl = ttk.Label(top, text="v" + update.running_version(), style="Dim.TLabel")
        self.version_lbl.pack(side="left", padx=self.pad(8, 0), pady=self.pad(6, 0))
        self.restart_btn = ttk.Button(top, text="Restart to update", style="Accent.TButton", command=self._do_restart)
        # packed only once an update has been downloaded
        self.multi_lbl = ttk.Label(top, text="", style="Dim.TLabel")
        self.multi_lbl.pack(side="right", pady=self.pad(6, 0))
        self.header_lbl = ttk.Label(top)  # the Look tab's top-bar picture

        self.nb = ttk.Notebook(self.root)
        self.nb.pack(fill="both", expand=True, padx=self.px(16), pady=self.pad(10, 8))
        self._build_accounts()
        self._build_launch()
        self.manage = manage.ManageTab(self)
        self._build_look()
        self._build_settings()

        logf = ttk.Frame(self.root, padding=self.pad(16, 0, 16, 14))
        # packed before the tabs claim their space, so the log always stays on screen
        logf.pack(side="bottom", fill="x", before=self.nb)
        mono = ("Consolas", 9) if sys.platform == "win32" else ("DejaVu Sans Mono", 9)
        self.log_text = tk.Text(logf, height=5, bg=CARD, fg=DIM, relief="flat", wrap="word", font=mono,
                                highlightthickness=1, highlightbackground=LINE, highlightcolor=LINE,
                                insertbackground=FG, padx=self.px(8), pady=self.px(6))
        self.raw(self.log_text, bg="CARD", fg="DIM", highlightbackground="LINE", highlightcolor="LINE", insertbackground="FG")
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
        tab = self._scroll_tab("Launch")
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
        grow = ttk.Frame(act)
        grow.pack(fill="x", pady=self.pad(12, 0))
        ttk.Label(grow, text="Group").pack(side="left")
        self.group_launch_var = tk.StringVar()
        self.group_box = ttk.Combobox(grow, textvariable=self.group_launch_var, values=self.store.groups(),
                                      state="readonly", width=20)
        self.group_box.pack(side="left", padx=self.px(8))
        ttk.Button(grow, text="Launch group", command=self.launch_group).pack(side="left")
        ttk.Label(grow, text="Set groups on the Manage tab.", style="Dim.TLabel").pack(side="left", padx=self.px(10))
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
        tab = self._scroll_tab("Settings")
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

    def _font_family(self, label):
        return fonts.family_for(label, available=lambda: set(tkfont.families(self.root)))

    def set_font(self, label):
        family = self._font_family(label)
        self.settings.set("font", label)
        self.apply_look()
        if label != fonts.DEFAULT and family == fonts.default_family():
            self.log("%s could not be loaded on this PC; using the normal font." % label)
        else:
            self.log("App font: %s." % label)

    # look -------------------------------------------------------------------------------
    def raw(self, widget, **colours):
        """Registers a plain Tk widget to be recoloured with the theme (values: colour names)."""
        self._raw.append((widget, colours))
        return widget

    def look_roles(self):
        return look.roles_for(self.settings.get("theme_preset"), self.settings.get("theme_colors") or {})

    def look_palette(self):
        return look.palette(self.look_roles())

    def apply_look(self):
        """Re-applies theme, font and text size everywhere, plus cursor and top-bar picture."""
        apply_theme(self.root, self.k, self._font_family(self.settings.get("font")), self.look_palette(),
                    look.text_scale(self.settings.get("text_scale")))
        names = globals()
        alive = []
        for widget, colours in self._raw:
            try:
                widget.configure(**{opt: names[c] for opt, c in colours.items()})
                alive.append((widget, colours))
            except tk.TclError:
                pass  # destroyed
        self._raw = alive
        try:
            self.tree.tag_configure("online", foreground=GOOD)
            self.tree.tag_configure("idle", foreground=FG)
            self.tree.tag_configure("gone", foreground=DIM)
        except (tk.TclError, AttributeError):
            pass
        if getattr(self, "_swatches", None):
            roles = self.look_roles()
            for role, (sw, var) in self._swatches.items():
                sw.configure(bg=look.to_hex(roles[role]))
                var.set(look.to_hex(roles[role]))
        self.apply_kh()
        self.apply_cursor()
        self.apply_header_image()

    # Kingdom Hearts style --------------------------------------------------------------
    def kh_on(self):
        return self.settings.get("ui_style") == "Kingdom Hearts"

    KH_LAYOUTS = ("TButton", "Accent.TButton", "Danger.TButton", "TNotebook.Tab", "TLabelframe")

    def apply_kh(self):
        """Puppy Admin's Kingdom Hearts menu look on the ttk widgets (see khart): shaded
        buttons that turn deep red with a red outline on hover, red selected tabs, framed
        panels, the title capsule and the pointing glove. Off restores the normal layouts."""
        style = ttk.Style(self.root)
        st = self._kh
        if st is None:
            st = self._kh = {"imgs": {}, "made": False, "active": False,
                             "saved": {n: style.layout(n.split(".", 1)[-1] if n.endswith("TButton") else n)
                                       for n in self.KH_LAYOUTS},
                             "lf": (style.lookup("TLabelframe", "padding") or 0, style.lookup("TLabelframe", "labelmargins") or 0)}
        if not self.kh_on():
            if st["active"]:
                for name, layout in st["saved"].items():
                    style.layout(name, layout)
                style.configure("TLabelframe", padding=st["lf"][0], labelmargins=st["lf"][1])
                self.kh_title.pack_forget()
                self.title_lbl.pack(side="left", before=self.version_lbl)
                st["active"] = False
            self._kh_target = None
            self._kh_hide_glove()
            return
        k = self.k
        bg, card, field, line = (khart.hex_rgb(c) for c in (BG, CARD, FIELD, LINE))
        accent, accent_lo = khart.hex_rgb(ACCENT), khart.hex_rgb(ACCENT_LO)
        danger = (71, 34, 42)
        pieces = {
            "btn": khart.button(field, line, bg, k), "btn_h": khart.button(field, line, bg, k, "hover"),
            "btn_p": khart.button(field, line, bg, k, "pressed"), "btn_d": khart.button(card, line, bg, k, "disabled"),
            "acc": khart.button(accent, accent_lo, bg, k), "dan": khart.button(danger, (92, 42, 51), bg, k),
            "tab": khart.tab(card, line, bg, k), "tab_h": khart.tab(card, line, bg, k, "hover"),
            "tab_s": khart.tab(card, line, bg, k, "selected"), "panel": khart.panel(bg, accent, bg, k),
        }
        imgs = st["imgs"]
        for name, rows in pieces.items():
            if name in imgs:
                khart.fill_photo(imgs[name], rows)  # elements keep pointing at the same image
            else:
                imgs[name] = khart.photo(self.root, rows)
        if not st["made"]:
            b = khart.button_border(k)
            for el, face in (("KHButton.bg", "btn"), ("KHAccent.bg", "acc"), ("KHDanger.bg", "dan")):
                style.element_create(el, "image", imgs[face], ("disabled", imgs["btn_d"]), ("pressed", imgs["btn_p"]),
                                     ("active", imgs["btn_h"]), border=b, sticky="nsew")
            style.element_create("KHTab.bg", "image", imgs["tab"], ("selected", imgs["tab_s"]), ("active", imgs["tab_h"]),
                                 border=b, sticky="nsew")
            style.element_create("KHPanel.border", "image", imgs["panel"], border=khart.panel_border(k), sticky="nsew")
            st["made"] = True

        def button_layout(el):
            return [(el, {"sticky": "nsew", "children": [("Button.padding", {"sticky": "nsew", "children": [
                ("Button.label", {"sticky": "nsew"})]})]})]
        style.layout("TButton", button_layout("KHButton.bg"))
        style.layout("Accent.TButton", button_layout("KHAccent.bg"))
        style.layout("Danger.TButton", button_layout("KHDanger.bg"))
        style.layout("TNotebook.Tab", [("KHTab.bg", {"sticky": "nsew", "children": [("Notebook.padding", {
            "side": "top", "sticky": "nsew", "children": [("Notebook.label", {"side": "top", "sticky": ""})]})]})])
        style.layout("TLabelframe", [("KHPanel.border", {"sticky": "nsew"})])
        style.map("TButton", foreground=[("disabled", DIM), ("active", "#ffffff")])
        style.map("Accent.TButton", foreground=[("disabled", DIM), ("active", "#ffffff")])
        style.map("TNotebook.Tab", foreground=[("selected", "#ffffff"), ("active", FG)])
        scale = look.text_scale(self.settings.get("text_scale"))
        gummi = fonts.family_for("KH Gummi", lambda: tkfont.families(self.root))
        style.configure("TLabelframe", padding=self.px(12), labelmargins=(self.px(14), 0, 0, 0))
        # the image border already pads the label: keep buttons the size they are in the standard style
        style.configure("TButton", padding=(self.px(3), 0))
        style.configure("TLabelframe.Label", foreground=FG, font=(gummi, max(6, round(10 * scale))))
        self._kh_draw_title(gummi, scale)
        if st["active"] is False:
            self.title_lbl.pack_forget()
            self.kh_title.pack(side="left", before=self.version_lbl)
        st["active"] = True
        self._kh_make_glove()

    def _kh_draw_title(self, family, scale):
        k = self.k
        c = self.kh_title
        c.delete("all")
        c.configure(bg=BG)
        text = "PUPPY COMPANION"
        size = max(8, round(15 * scale))
        fnt = tkfont.Font(root=self.root, family=family, size=size)
        pad = self.px(18)
        w = fnt.measure(text) + pad * 2
        h = max(round(34 * k), fnt.metrics("linespace") + self.px(6))
        bg = khart.hex_rgb(BG)
        cap = khart.capsule(w, khart.hex_rgb(ACCENT), bg, h / 34.0)
        line = khart.underline(w + self.px(60), bg, k)
        self._kh_title_imgs = (khart.photo(self.root, cap), khart.photo(self.root, line))
        ch = len(cap)
        c.configure(width=w + self.px(60), height=ch + self.px(8))
        c.create_image(0, 0, image=self._kh_title_imgs[0], anchor="nw")
        c.create_image(self.px(4), ch + self.px(2), image=self._kh_title_imgs[1], anchor="nw")
        c.create_text(pad, ch // 2, text=text, font=fnt, fill="#ffffff", anchor="w")
        self._kh_title_font = fnt

    def _kh_make_glove(self):
        size = khart.glove_size(self.k)
        if getattr(self, "kh_glove", None) is None:
            self._kh_glove_img = tk.PhotoImage(master=self.root, data="".join(kh_data.GLOVE[size]))
            self._kh_glove_win = None
            if sys.platform == "win32":
                # its own borderless window whose background colour is see-through and click-through,
                # so the glove can overlap the next button without a box around it
                try:
                    win = tk.Toplevel(self.root)
                    win.overrideredirect(True)
                    win.withdraw()
                    win.configure(bg=BG)
                    win.wm_attributes("-transparentcolor", BG)
                    win.transient(self.root)
                    self._kh_glove_win = win
                except tk.TclError:
                    self._kh_glove_win = None
            parent = self._kh_glove_win or self.root
            self.kh_glove = tk.Label(parent, image=self._kh_glove_img, bd=0, highlightthickness=0, bg=BG)
            if self._kh_glove_win is not None:
                self.kh_glove.pack()
            for cls in ("TButton",):
                self.root.bind_class(cls, "<Enter>", self._kh_enter, add="+")
                self.root.bind_class(cls, "<Leave>", self._kh_leave, add="+")
        self.kh_glove.configure(bg=BG)
        if self._kh_glove_win is not None:
            try:
                self._kh_glove_win.configure(bg=BG)
                self._kh_glove_win.wm_attributes("-transparentcolor", BG)
            except tk.TclError:
                pass

    def kh_glove_shown(self):
        try:
            if getattr(self, "_kh_glove_win", None) is not None:
                return self._kh_glove_win.winfo_ismapped()
            return getattr(self, "kh_glove", None) is not None and self.kh_glove.winfo_ismapped()
        except tk.TclError:
            return False

    def _kh_hide_glove(self):
        if getattr(self, "kh_glove", None) is None:
            return
        try:
            if self._kh_glove_win is not None:
                self._kh_glove_win.withdraw()
            else:
                self.kh_glove.place_forget()
        except tk.TclError:
            pass

    def _kh_enter(self, e):
        if not self.kh_on():
            return
        w = e.widget if not isinstance(e.widget, str) else self.root.nametowidget(e.widget)
        self._kh_target = w
        if not self._kh_ticking:
            self._kh_ticking = True
            self._kh_tick()

    def _kh_leave(self, e):
        w = e.widget if not isinstance(e.widget, str) else self.root.nametowidget(e.widget)
        if self._kh_target is w:
            self._kh_target = None

    def _kh_tick(self):
        """Places the glove left of the hovered button, bobbing, every 40 ms while one is hovered."""
        w = self._kh_target
        try:
            shown = (w is not None and self.kh_on() and not self._closing and w.winfo_exists() and w.winfo_ismapped())
        except tk.TclError:
            shown = False
        if not shown:
            self._kh_ticking = False
            self._kh_target = None
            self._kh_hide_glove()
            return
        gw, gh = self._kh_glove_img.width(), self._kh_glove_img.height()
        x = w.winfo_rootx() - gw - self.px(3) + khart.bob(time.time(), self.k)
        y = w.winfo_rooty() + (w.winfo_height() - gh) // 2
        if self._kh_glove_win is not None:
            self._kh_glove_win.geometry("+%d+%d" % (x, y))
            self._kh_glove_win.deiconify()
            self._kh_glove_win.lift()
        else:
            self.kh_glove.place(x=x - self.root.winfo_rootx(), y=y - self.root.winfo_rooty())
            self.kh_glove.lift()
        self.root.after(40, self._kh_tick)

    def apply_cursor(self):
        spec = look.cursor_spec(self.settings.get("cursor"), self.settings.get("cursor_file"))
        try:
            self.root.configure(cursor=spec)
            self.cursor_spec = spec
        except tk.TclError:
            self.root.configure(cursor="")
            self.cursor_spec = ""
            if self.settings.get("cursor") != "Default":
                self.log("That cursor could not be loaded; using the normal one.")

    def apply_header_image(self):
        path = self.settings.get("header_image") or ""
        if not path:
            self.header_lbl.pack_forget()
            self._header_photo = None
            return
        try:
            img = tk.PhotoImage(master=self.root, file=path)
            limit = self.px(56)
            factor = max(1, -(-img.height() // limit))
            if factor > 1:
                img = img.subsample(factor, factor)
        except tk.TclError:
            self.header_lbl.pack_forget()
            self._header_photo = None
            self.log("The top-bar picture could not be opened (PNG or GIF only).")
            return
        self._header_photo = img
        self.header_lbl.configure(image=img)
        self.header_lbl.pack(side="right", padx=self.pad(0, 12))

    def _scroll_tab(self, title):
        """A notebook tab whose content scrolls (mouse wheel or scrollbar) when the window is
        smaller than it; returns the frame to build into."""
        outer = ttk.Frame(self.nb)
        self.nb.add(outer, text=title)
        canvas = tk.Canvas(outer, highlightthickness=0, borderwidth=0, bg=BG, height=self.px(200))
        self.raw(canvas, bg="BG")
        sb = ttk.Scrollbar(outer, orient="vertical", command=canvas.yview)
        canvas.configure(yscrollcommand=sb.set)
        sb.pack(side="right", fill="y")
        canvas.pack(side="left", fill="both", expand=True)
        inner = ttk.Frame(canvas, padding=self.px(12))
        item = canvas.create_window((0, 0), window=inner, anchor="nw")
        inner.bind("<Configure>", lambda e: canvas.configure(scrollregion=canvas.bbox("all")))
        canvas.bind("<Configure>", lambda e: canvas.itemconfigure(item, width=e.width))

        def wheel(e):
            if canvas.yview() == (0.0, 1.0):
                return
            step = -1 if (getattr(e, "num", 0) == 4 or getattr(e, "delta", 0) > 0) else 1
            canvas.yview_scroll(step * max(1, abs(getattr(e, "delta", 120)) // 120), "units")

        def enter(_e):
            for seq in ("<MouseWheel>", "<Button-4>", "<Button-5>"):
                self.root.bind_all(seq, wheel)

        def leave(_e):
            for seq in ("<MouseWheel>", "<Button-4>", "<Button-5>"):
                self.root.unbind_all(seq)
        outer.bind("<Enter>", enter)
        outer.bind("<Leave>", leave)
        inner.scroll_canvas = canvas
        return inner

    def _build_look(self):
        tab = self._scroll_tab("Look")
        th = ttk.LabelFrame(tab, text="THEME (PUPPY ADMIN'S PRESETS) - COLOURS: #HEX, R,G,B OR A NAME, THEN ENTER", padding=self.px(10))
        th.pack(fill="x")
        srow = ttk.Frame(th)
        srow.pack(anchor="w", pady=self.pad(0, 8))
        ttk.Label(srow, text="UI style").pack(side="left", padx=self.pad(0, 8))
        ttk.Button(srow, text="Kingdom Hearts", style="Accent.TButton",
                   command=lambda: self.set_style("Kingdom Hearts")).pack(side="left", padx=self.pad(0, 6))
        ttk.Button(srow, text="Standard", command=lambda: self.set_style("Standard")).pack(side="left")
        ttk.Label(th, style="Dim.TLabel", wraplength=self.px(760), text="Kingdom Hearts = Puppy Admin's KH menu look: "
                  "red hover with a pointing glove, framed panels, the title capsule, plus the KH theme, font and cursor. "
                  "Standard brings back your look from before.").pack(anchor="w", pady=self.pad(0, 8))
        prow = ttk.Frame(th)
        prow.pack(anchor="w")
        for i, name in enumerate(look.PRESET_NAMES):  # two rows, so every preset fits
            ttk.Button(prow, text=name, width=15, command=lambda n=name: self.set_preset(n)).grid(
                row=i // 4, column=i % 4, padx=self.pad(0, 6), pady=self.pad(0, 4), sticky="w")
        grid = ttk.Frame(th)
        grid.pack(anchor="w", pady=self.pad(10, 0))
        self._swatches = {}
        roles = self.look_roles()
        for i, role in enumerate(look.ROLES):
            r, c = i % 4, (i // 4) * 3
            ttk.Label(grid, text=look.LABELS[role]).grid(row=r, column=c, sticky="w", padx=self.pad(0, 8), pady=self.pad(0, 4))
            sw = tk.Label(grid, width=3, bg=look.to_hex(roles[role]), relief="solid", borderwidth=1)
            sw.grid(row=r, column=c + 1, sticky="w")
            var = tk.StringVar(value=look.to_hex(roles[role]))
            ent = ttk.Entry(grid, textvariable=var, width=12)
            ent.grid(row=r, column=c + 2, sticky="w", padx=self.pad(6, 22), pady=self.pad(0, 4))
            ent.bind("<Return>", lambda e, ro=role, v=var: self.set_role_colour(ro, v.get()))
            ent.bind("<FocusOut>", lambda e, ro=role, v=var: self.set_role_colour(ro, v.get(), quiet=True))
            self._swatches[role] = (sw, var)

        bottom = ttk.Frame(tab)  # text and cursor side by side, so the tab fits the default window
        bottom.pack(fill="x", pady=self.pad(8, 0))
        bottom.columnconfigure(0, weight=1)
        bottom.columnconfigure(1, weight=1)
        tx = ttk.LabelFrame(bottom, text="TEXT", padding=self.px(10))
        tx.grid(row=0, column=0, sticky="nsew", padx=self.pad(0, 8))
        ttk.Label(tx, text="App font").grid(row=0, column=0, sticky="w")
        self.font_var = tk.StringVar(value=self.settings.get("font") if self.settings.get("font") in fonts.choices() else fonts.DEFAULT)
        fbox = ttk.Combobox(tx, textvariable=self.font_var, values=fonts.choices(), state="readonly", width=24)
        fbox.grid(row=0, column=1, sticky="w", padx=self.px(10))
        fbox.bind("<<ComboboxSelected>>", lambda e: self.set_font(self.font_var.get()))
        ttk.Label(tx, text="Text size").grid(row=1, column=0, sticky="w", pady=self.pad(10, 0))
        self.scale_var = tk.DoubleVar(value=look.text_scale(self.settings.get("text_scale")) * 100)
        self.scale_lbl = ttk.Label(tx, text="%d%%" % self.scale_var.get(), width=5)
        sc = ttk.Scale(tx, from_=50, to=200, variable=self.scale_var, length=self.px(170),
                       command=lambda v: self.scale_lbl.configure(text="%d%%" % round(float(v))))
        sc.grid(row=1, column=1, sticky="w", padx=self.px(10), pady=self.pad(10, 0))
        sc.bind("<ButtonRelease-1>", lambda e: self.set_text_scale(self.scale_var.get() / 100))
        self.scale_lbl.grid(row=1, column=2, sticky="w", pady=self.pad(10, 0))
        ttk.Button(tx, text="Reset", command=lambda: self.set_text_scale(1.0)).grid(row=2, column=1, sticky="w", padx=self.px(10), pady=self.pad(8, 0))

        cu = ttk.LabelFrame(bottom, text="CURSOR AND TOP-BAR PICTURE", padding=self.px(10))
        cu.grid(row=0, column=1, sticky="nsew")
        ttk.Label(cu, text="Cursor").grid(row=0, column=0, sticky="w")
        self.cursor_var = tk.StringVar(value=self.settings.get("cursor") if self.settings.get("cursor") in look.CURSOR_CHOICES else "Default")
        cbox = ttk.Combobox(cu, textvariable=self.cursor_var, values=look.CURSOR_CHOICES, state="readonly", width=14)
        cbox.grid(row=0, column=1, sticky="w", padx=self.px(10))
        cbox.bind("<<ComboboxSelected>>", lambda e: self.set_cursor(self.cursor_var.get()))
        ttk.Button(cu, text=".cur / .ani file", command=self.choose_cursor_file).grid(row=0, column=2, sticky="w")
        ttk.Label(cu, text="Top-bar picture").grid(row=1, column=0, sticky="w", pady=self.pad(10, 0))
        ttk.Button(cu, text="Choose PNG / GIF", command=self.choose_header_image).grid(
            row=1, column=1, sticky="w", padx=self.px(10), pady=self.pad(10, 0))
        ttk.Button(cu, text="Remove", command=lambda: self.set_header_image("")).grid(row=1, column=2, sticky="w", pady=self.pad(10, 0))
        ttk.Label(cu, style="Dim.TLabel", wraplength=self.px(360), text="The picture sits in the top bar: Windows apps "
                  "can't draw one behind their buttons.").grid(row=2, column=0, columnspan=3, sticky="w", pady=self.pad(8, 0))

    LOOK_KEYS = ("theme_preset", "theme_colors", "font", "cursor")

    def set_style(self, name):
        """Kingdom Hearts: saves the current look, then the KH theme, font, cursor and menu
        look (apply_kh). Standard: the look from before the KH style, else the app's default."""
        st = look.STYLES[name]
        was_kh = self.kh_on()
        if name == "Kingdom Hearts" and not was_kh:
            self.settings.set("kh_prev", {key: self.settings.get(key) for key in self.LOOK_KEYS})
        values = {"theme_preset": st["preset"], "theme_colors": {}, "font": st["font"], "cursor": st["cursor"]}
        if name == "Standard":
            prev = self.settings.get("kh_prev") or {}
            if was_kh and isinstance(prev, dict) and prev:
                values.update({key: prev[key] for key in self.LOOK_KEYS if key in prev})
            self.settings.set("kh_prev", {})
        for key, value in values.items():
            self.settings.set(key, value)
        self.settings.set("ui_style", name)
        self.font_var.set(values["font"] if values["font"] in fonts.choices() else fonts.DEFAULT)
        self.cursor_var.set(values["cursor"] if values["cursor"] in look.CURSOR_CHOICES else "Default")
        self.apply_look()
        self.log("UI style: %s." % name)

    def set_preset(self, name):
        self.settings.set("theme_preset", name)
        self.settings.set("theme_colors", {})
        self.apply_look()
        self.log("Theme: %s." % name)

    def set_role_colour(self, role, text, quiet=False):
        rgb = look.parse_color(text)
        cur = self.look_roles()[role]
        if not rgb:
            if not quiet:
                self.log("Colour: #hex, r,g,b or a name (for example #ff88cc or pink).")
            self._swatches[role][1].set(look.to_hex(cur))
            return
        if tuple(rgb) == tuple(cur):
            return
        colours = dict(self.settings.get("theme_colors") or {})
        colours[role] = look.to_hex(rgb)
        self.settings.set("theme_colors", colours)
        self.apply_look()
        self.log("%s: %s." % (look.LABELS[role], look.to_hex(rgb)))

    def set_text_scale(self, value):
        v = look.text_scale(value)
        self.settings.set("text_scale", v)
        self.scale_var.set(v * 100)
        self.scale_lbl.configure(text="%d%%" % round(v * 100))
        self.apply_look()
        self.log("Text size: %d%%." % round(v * 100))

    def set_cursor(self, choice):
        if choice == "Custom file" and not self.settings.get("cursor_file"):
            self.choose_cursor_file()
            return
        self.settings.set("cursor", choice)
        self.apply_cursor()
        if sys.platform != "win32" and choice != "Default":
            self.log("Custom cursors work on Windows only.")
        else:
            self.log("Cursor: %s." % choice)

    def choose_cursor_file(self):
        path = filedialog.askopenfilename(parent=self.root, title="Cursor file",
                                          filetypes=[("Windows cursors", "*.cur *.ani"), ("All files", "*.*")])
        if not path:
            return
        self.settings.set("cursor_file", path)
        self.cursor_var.set("Custom file")
        self.set_cursor("Custom file")

    def choose_header_image(self):
        path = filedialog.askopenfilename(parent=self.root, title="Top-bar picture",
                                          filetypes=[("Pictures", "*.png *.gif"), ("All files", "*.*")])
        if path:
            self.set_header_image(path)

    def set_header_image(self, path):
        self.settings.set("header_image", path or "")
        self.apply_header_image()
        if path and self._header_photo:
            self.log("Top-bar picture set.")

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
            try:
                build = update.latest_script_build(opener=self._http_opener())
            except update.UpdateError:
                build = None
            self.ui.put(("call", (self._script_build_known, (build,))))
            manifest = update.check(opener=self._http_opener())
            if not manifest:
                return None
            return update.download(manifest, opener=self._http_opener())

        self.run_bg(work, lambda version, err: self._update_done(version, err, manual))

    def _script_build_known(self, build):
        if not build:
            return
        changed = build != self.script_latest
        self.script_latest = build
        self.refresh_status()
        old = self.outdated_windows()
        if changed:
            self.log("Latest Puppy Admin on GitHub: build %s." % build)
            if old:
                self.log("%d window%s still run%s an older Puppy Admin: execute it again there (or rejoin) to update."
                         % (len(old), "" if len(old) == 1 else "s", "s" if len(old) == 1 else ""))

    def outdated_windows(self):
        """User ids whose running Puppy Admin is older than the newest build on GitHub."""
        if not self.script_latest:
            return []
        latest = update.build_tuple(self.script_latest)
        return [uid for uid, st in self.statuses.items()
                if st.get("fresh") and st.get("online") and st.get("build")
                and update.build_tuple(st["build"]) < latest]

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
        script = (" Puppy Admin's latest build is %s; it updates itself when you execute it again in game."
                  % self.script_latest) if self.script_latest else ""
        if not version:
            if manual:
                self.update_lbl.configure(text="The app is on the latest version (%s).%s"
                                          % (update.running_version(), script), style="Good.TLabel")
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
        if (self.script_latest and st.get("build")
                and update.build_tuple(st["build"]) < update.build_tuple(self.script_latest)):
            text += " - old Puppy Admin, execute again"
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
        self.auto_rejoin_tick(now)

    REJOIN_AFTER = 45      # seconds an alt must be gone before it is relaunched
    REJOIN_WAIT = 120      # seconds between two relaunches of the same alt
    REJOIN_MAX = 3         # relaunches per alt in REJOIN_WINDOW
    REJOIN_WINDOW = 600

    def auto_rejoin_tick(self, now):
        """Alts with auto-rejoin on are relaunched into the main's server when they drop
        out of it (crash, kick, disconnect). Only alts seen in a game since the app
        started count, and each gets at most REJOIN_MAX tries per REJOIN_WINDOW."""
        main = self.store.main()
        mst = self.statuses.get(main.user_id) if main else None
        main_live = bool(mst and mst["fresh"] and mst["online"] and mst["placeId"] and mst["jobId"]
                         and not mst.get("privateServer"))
        for a in self.store.alts():
            if not a.prefs.get("auto_rejoin"):
                self._rejoin.pop(a.user_id, None)
                continue
            rec = self._rejoin.setdefault(a.user_id, {"seen": False, "lost": None, "tries": [], "last": 0.0})
            st = self.statuses.get(a.user_id)
            if st and st["fresh"] and st["online"]:
                rec["seen"], rec["lost"] = True, None
                continue
            if not rec["seen"]:
                continue
            if rec["lost"] is None:
                rec["lost"] = now
                continue
            rec["tries"] = [t for t in rec["tries"] if now - t < self.REJOIN_WINDOW]
            if (now - rec["lost"] < self.REJOIN_AFTER or now - rec["last"] < self.REJOIN_WAIT
                    or len(rec["tries"]) >= self.REJOIN_MAX or not main_live):
                continue
            rec["tries"].append(now)
            rec["last"] = now
            self.log("Auto-rejoin: %s left the game, sending it back to the main's server (try %d of %d)."
                     % (a.label, len(rec["tries"]), self.REJOIN_MAX))
            self.launches.add([LaunchJob(a.user_id, a.label, mst["placeId"], mst["jobId"].lower(),
                                         extra_delay=a.prefs.get("extra_delay") or 0)])

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
        if getattr(self, "manage", None):
            self.manage.reload()
        if getattr(self, "group_box", None):
            self.group_box.configure(values=self.store.groups())

    def add_account(self):
        dlg = tk.Toplevel(self.root)
        dlg.title("Add account")
        dlg.configure(bg=BG, cursor=self.cursor_spec)
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
        # each account's launch order (Manage tab) first, then the list order
        accounts = sorted(accounts, key=lambda a: (a.prefs.get("launch_order") or 0))
        for a in accounts:
            st = self.statuses.get(a.user_id)
            live = st and st["fresh"] and st["online"]
            # launching an account that is already there would only end its session and rejoin
            if live and (st["jobId"].lower() == job if job else st["placeId"] == place):
                skipped.append(a.label)
                continue
            jobs.append(LaunchJob(a.user_id, a.label, place, job, extra_delay=a.prefs.get("extra_delay") or 0))
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

    def launch_group(self):
        group = self.group_launch_var.get().strip()
        accounts = [a for a in self.store.accounts() if group and a.group == group]
        if not accounts:
            self.log("Pick a group first (groups are set per account on the Manage tab).")
            return
        t = self._target()
        if t:
            self._queue(accounts, *t)

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
