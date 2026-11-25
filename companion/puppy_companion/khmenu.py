"""The Kingdom Hearts style's menu screen for the companion, laid out like the KH menu
(owner's reference screenshot, shapes only): a MENU capsule at the top left and the app's
name in orange at the top right, the pages as a stacked menu list on the left (the selected
one red, the glove pointing at it), the page itself in the middle, account cards (role,
status, last seen) above a description box at the bottom right, and an ONLINE / TIME
panel at the bottom left. Built once; shown and hidden by CompanionApp.apply_kh.
"""
import time
import tkinter as tk
from tkinter import font as tkfont
from tkinter import ttk

from . import fonts, khart

DESCRIPTIONS = {
    "Accounts": "Your Roblox accounts: add one, choose the main and the alts, check logins.",
    "Launch": "Send your accounts into a game or into the main's server, one by one or as a group.",
    "Manage": "Each account's own settings, its profile and its privacy.",
    "Look": "Change how Puppy Companion looks: UI style, theme, font, text size and cursor.",
    "Settings": "Change Puppy Companion's settings.",
}
ORANGE = "#ff8c28"
GOLD = "#ffc828"
GREEN = "#5ae05a"
CYAN = "#5ac8ff"
BLUE = "#3c8cff"
DESC_FG = "#82c8ff"


def uptime_text(seconds):
    """Like the KH clock: h:mm."""
    m = max(0, int(seconds)) // 60
    return "%d:%02d" % (m // 60, m % 60)


class KHMenu:
    CARD_W = 150

    def __init__(self, app):
        self.app = app
        self.root = app.root
        self.started = time.time()
        self.hover = None
        px = app.px
        c = app.colour
        nb = app.nb
        self.pages = [nb.tab(i, "text") for i in range(len(nb.tabs()))]

        self.menu = tk.Frame(self.root, bg=c("BG"))
        app.raw(self.menu, bg="BG")
        self.buttons = []
        for i, name in enumerate(self.pages):
            b = ttk.Button(self.menu, text=name, style="KHMenu.TButton", width=14, command=lambda n=i: self.select(n))
            b.pack(fill="x", pady=(0, px(4)))
            b.bind("<Enter>", lambda e, n=name: self.set_hover(n), add="+")
            b.bind("<Leave>", lambda e, n=name: self.set_hover(None, n), add="+")
            self.buttons.append(b)

        self.bottom = tk.Frame(self.root, bg=c("BG"))
        app.raw(self.bottom, bg="BG")
        self.info = tk.Canvas(self.bottom, highlightthickness=px(2), borderwidth=0, width=px(196), height=px(112))
        self.info.pack(side="left", fill="y", padx=(0, px(10)))
        right = tk.Frame(self.bottom, bg=c("BG"))
        app.raw(right, bg="BG")
        right.pack(side="left", fill="both", expand=True)
        self.cards = tk.Canvas(right, highlightthickness=0, borderwidth=0, height=px(66))
        self.cards.pack(fill="x")
        self.cards.bind("<Configure>", lambda e: self.draw_cards())
        self.desc = tk.Label(right, anchor="nw", justify="left", padx=px(14), pady=px(8), highlightthickness=px(2))
        self.desc.pack(fill="both", expand=True, pady=(px(4), 0))
        self.desc.bind("<Configure>", lambda e: self.desc.configure(wraplength=max(50, e.width - px(30))))

        self.place = tk.Canvas(app.top_frame, highlightthickness=0, borderwidth=0, height=px(40))
        nb.bind("<<NotebookTabChanged>>", lambda e: self.sync(), add="+")

    # ------------------------------------------------------------------ state
    def selected_index(self):
        try:
            return self.app.nb.index("current")
        except tk.TclError:
            return 0

    def selected_button(self):
        i = self.selected_index()
        return self.buttons[i] if 0 <= i < len(self.buttons) else None

    def select(self, i):
        self.app.nb.select(i)
        self.sync()

    def set_hover(self, name, leaving=None):
        if name is None and self.hover != leaving:
            return
        self.hover = name
        self.draw_desc()

    def sync(self):
        cur = self.selected_index()
        for i, b in enumerate(self.buttons):
            b.state(["selected"] if i == cur else ["!selected"])
        self.draw_desc()

    # ------------------------------------------------------------------ drawing
    def fonts(self):
        scale = self.app.text_scale()
        gummi = fonts.family_for("KH Gummi", lambda: tkfont.families(self.root))
        body = self.app.font_family()
        return gummi, body, scale

    def theme(self):
        """Colours and fonts after a theme / font / size change."""
        c = self.app.colour
        gummi, body, scale = self.fonts()
        style = ttk.Style(self.root)
        style.configure("KHMenu.TButton", anchor="w", padding=(self.app.px(12), self.app.px(1)),
                        font=(body, max(8, round(13 * scale))), foreground="#d8dcf0")
        style.map("KHMenu.TButton", foreground=[("selected", "#ffffff"), ("active", "#ffffff")])
        for w in (self.info, self.cards, self.place):
            w.configure(bg=c("BG"))
        self.info.configure(highlightbackground=c("ACCENT"), highlightcolor=c("ACCENT"), bg=c("CARD"))
        self.desc.configure(bg=c("CARD"), fg=DESC_FG, highlightbackground=c("ACCENT"), highlightcolor=c("ACCENT"),
                            font=(body, max(8, round(15 * scale))))
        self.draw_place()
        self.draw_info()
        self.draw_cards()
        self.sync()

    def draw_place(self):
        app, px = self.app, self.app.px
        gummi, _body, scale = self.fonts()
        cv = self.place
        cv.delete("all")
        f = tkfont.Font(root=self.root, family=gummi, size=max(8, round(14 * scale)))
        text = "Puppy Companion"
        ver = "v" + app.version()
        fv = tkfont.Font(root=self.root, family=gummi, size=max(6, round(9 * scale)))
        tw = f.measure(text) + px(8) + fv.measure(ver)
        w = tw + px(140)
        h = f.metrics("linespace") + px(10)
        cv.configure(width=w, height=h)
        line = khart.underline(w, khart.hex_rgb(app.colour("BG")), app.k, reverse=True)
        self._place_img = khart.photo(self.root, line)
        cv.create_image(0, h - len(line) - px(2), image=self._place_img, anchor="nw")
        cv.create_text(w - px(4), h - len(line) - px(4), text=ver, font=fv, fill=ORANGE, anchor="se")
        cv.create_text(w - px(8) - fv.measure(ver), h - len(line) - px(3), text=text, font=f, fill=ORANGE, anchor="se")
        self._place_fonts = (f, fv)

    def draw_info(self):
        app, px = self.app, self.app.px
        gummi, _body, scale = self.fonts()
        cv = self.info
        cv.delete("all")
        w = int(cv.cget("width"))
        label = tkfont.Font(root=self.root, family=gummi, size=max(7, round(12 * scale)), slant="italic")
        big = tkfont.Font(root=self.root, family=gummi, size=max(9, round(20 * scale)), weight="bold", slant="italic")
        alts = app.store.accounts()
        online = sum(1 for a in alts if app.is_online(a.user_id))
        cv.create_text(px(14), px(8), text="ONLINE", font=label, fill=ORANGE, anchor="nw")
        cv.create_line(px(8), px(28), w - px(8), px(28), fill=ORANGE, width=max(1, px(2)))
        cv.create_text(w - px(12), px(26), text="%d/%d" % (online, len(alts)), font=big, fill=GOLD, anchor="ne")
        cv.create_text(px(14), px(58), text="TIME", font=label, fill=BLUE, anchor="nw")
        cv.create_line(px(8), px(78), w - px(8), px(78), fill=BLUE, width=max(1, px(2)))
        cv.create_text(w - px(12), px(76), text=uptime_text(time.time() - self.started), font=big, fill=CYAN, anchor="ne")
        self._info_fonts = (label, big)

    def draw_cards(self):
        app, px = self.app, self.app.px
        gummi, body, scale = self.fonts()
        cv = self.cards
        cv.delete("all")
        width = cv.winfo_width() if cv.winfo_width() > 1 else px(600)
        cw = px(self.CARD_W)
        gap = px(6)
        n = max(1, (width + gap) // (cw + gap))
        head = tkfont.Font(root=self.root, family=body, size=max(7, round(11 * scale)), weight="bold")
        small = tkfont.Font(root=self.root, family=gummi, size=max(6, round(9 * scale)))
        accs = sorted(app.store.accounts(), key=lambda a: (a.role != "main", a.label.lower()))[:n]
        c = app.colour
        for i, a in enumerate(accs):
            x = i * (cw + gap)
            cv.create_rectangle(x, 0, x + cw, px(20), fill=c("FIELD"), outline=c("LINE"))
            cv.create_text(x + cw // 2, px(10), text=a.label[:18], font=head, fill="#ffffff")
            cv.create_rectangle(x, px(20), x + cw, px(64), fill=c("CARD"), outline=c("LINE"))
            on = app.is_online(a.user_id)
            seen = app.seen_text(a.user_id)
            rows = (("ROLE", a.role, GOLD), ("STATUS", "online" if on else "offline", GREEN if on else c("DIM")),
                    ("SEEN", seen or "-", CYAN))
            for r, (k, v, col) in enumerate(rows):
                y = px(31) + r * px(12)
                cv.create_text(x + px(6), y, text=k, font=small, fill=col, anchor="w")
                cv.create_text(x + cw - px(6), y, text=v, font=small, fill=col, anchor="e")
                cv.create_line(x + px(6), y + px(6), x + cw - px(6), y + px(6), fill=col)
        if not accs:
            cv.create_text(px(4), px(30), text="No accounts yet: add one on the Accounts page.", font=small,
                           fill=c("DIM"), anchor="w")
        self._card_fonts = (head, small)

    def draw_desc(self):
        name = self.hover or (self.pages[self.selected_index()] if self.pages else "")
        self.desc.configure(text=DESCRIPTIONS.get(name, name))

    # ------------------------------------------------------------------ layout
    def show(self, on):
        app = self.app
        for w in (app.top_frame, app.log_frame, app.nb, self.menu, self.bottom):
            w.pack_forget()
        app.top_frame.pack(fill="x")
        app.log_frame.pack(side="bottom", fill="x")
        px = app.px
        if on:
            self.bottom.pack(side="bottom", fill="x", padx=px(16), pady=(0, px(8)))
            # room on the left for the glove pointing at the chosen entry
            self.menu.pack(side="left", fill="y", padx=(px(46), 0), pady=(px(10), px(8)))
            # the menu list takes width: grow a small window so the pages still fit beside it
            try:
                w, h = app.root.winfo_width(), app.root.winfo_height()
                if w > 1 and (w < px(1040) or h < px(720)):
                    app.root.geometry("%dx%d" % (max(w, px(1040)), max(h, px(720))))
            except tk.TclError:
                pass
            app.nb.pack(side="left", fill="both", expand=True, padx=(px(10), px(16)), pady=(px(10), px(8)))
            app.nb.configure(style="KHMenu.TNotebook")
            app.version_lbl.pack_forget()
            self.place.pack(side="right", before=app.multi_lbl)
            app.log_text.configure(height=3)
            self.theme()
        else:
            app.nb.pack(fill="both", expand=True, padx=px(16), pady=(px(10), px(8)))
            app.nb.configure(style="TNotebook")
            self.place.pack_forget()
            app.version_lbl.pack(side="left", padx=(px(8), 0), pady=(px(6), 0))
            app.log_text.configure(height=5)

    def tick(self):
        """Every few seconds: account cards and the ONLINE / TIME panel."""
        self.draw_info()
        self.draw_cards()
