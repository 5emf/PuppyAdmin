"""The Sword Art Online-inspired UI style for the companion (the same style as Puppy Admin's
UIAPI.SAOStyle; original, nothing from the show): light theme, square buttons and frames with
thin grey lines, orange hover / press, the owner's SAO UI fan font, and the window laid out
after the owner's reference screenshot (shapes only): an orange stripe on the left, a column of
round icon buttons for the pages (the chosen one orange with a ring), the page beside it, a
slanted bar at the top right (your accounts in game, like an HP bar) and a description line at
the bottom. Built once by CompanionApp; switched on and off by apply().
"""
import os
import time
import tkinter as tk
from tkinter import font as tkfont
from tkinter import ttk

from . import fonts, khart

NAME = "Sword Art Online"
ORANGE = (238, 166, 0)
ORANGE_HEX = "#eea600"
PLATE_TOP, PLATE_BOTTOM, PLATE_EDGE = (252, 252, 252), (232, 233, 236), (188, 192, 200)
INK = "#464646"
ICON_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sao")
ICONS = ("character", "look", "alts", "games", "server", "owner", "commands", "config", "close")
PAGE_ICONS = {"Accounts": "alts", "Launch": "server", "Manage": "character", "Look": "look", "Settings": "config"}
DESCRIPTIONS = {
    "Accounts": "Your Roblox accounts: add one, choose the main and the alts, check logins.",
    "Launch": "Send your accounts into a game or into the main's server.",
    "Manage": "Each account's own settings, its profile and its privacy.",
    "Look": "UI style, theme, font, text size and cursor.",
    "Settings": "Puppy Companion's settings.",
}


def icon_index(name):
    return ICONS.index(name) if name in ICONS else ICONS.index("commands")


def slanted(x, y, w, h, slant):
    """The SAO bar shape: a parallelogram leaning right (canvas polygon points)."""
    return [x + slant, y, x + w, y, x + w - slant, y + h, x, y + h]


def bar_rgb(frac):
    if frac > 0.5:
        return (110, 200, 80)
    if frac > 0.2:
        return (240, 205, 60)
    return (230, 70, 60)


def button_face(back, k, state):
    w, h = round(44 * k), round(30 * k)
    if state in ("hover", "pressed"):
        top = ORANGE if state == "hover" else khart.mix(ORANGE, (0, 0, 0), 0.15)
        return khart.shape(w, h, 0, top, khart.mix(top, (0, 0, 0), 0.08), khart.mix(ORANGE, (0, 0, 0), 0.2), max(1.0, k), back)
    if state == "accent":
        return khart.shape(w, h, 0, ORANGE, khart.mix(ORANGE, (0, 0, 0), 0.1), khart.mix(ORANGE, (0, 0, 0), 0.2), max(1.0, k), back)
    if state == "disabled":
        return khart.shape(w, h, 0, (236, 236, 238), (236, 236, 238), (214, 216, 220), max(1.0, k), back)
    return khart.shape(w, h, 0, PLATE_TOP, PLATE_BOTTOM, PLATE_EDGE, max(1.0, k), back)


def frame_face(back, k):
    s = round(40 * k)
    return khart.shape(s, s, 0, back, back, PLATE_EDGE, max(1.0, k), back)


class SAOStyle:
    def __init__(self, app):
        self.app = app
        self.active = False
        self.made = False
        self.imgs = {}
        self.icon_imgs = {}
        self.buttons = []
        self.hover = None
        root = app.root
        c = app.colour
        self.column = tk.Frame(root, bg=c("BG"))
        app.raw(self.column, bg="BG")
        self.stripe = tk.Frame(root, bg=ORANGE_HEX, width=app.px(10))
        self.bottom = tk.Label(root, anchor="w", padx=app.px(14), pady=app.px(8), bg="#ffffff", fg=INK,
                               highlightthickness=1, highlightbackground=khart.to_hex(PLATE_EDGE))
        self.hud = tk.Canvas(app.top_frame, highlightthickness=0, borderwidth=0, height=app.px(56), width=app.px(330))
        app.nb.bind("<<NotebookTabChanged>>", lambda e: self.sync(), add="+")

    # ------------------------------------------------------------------ helpers
    def pages(self):
        nb = self.app.nb
        return [nb.tab(i, "text") for i in range(len(nb.tabs()))]

    def font(self, size, bold=False, title=False):
        fam = fonts.family_for("SAO Welcome" if title else "SAO UI", lambda: tkfont.families(self.app.root))
        scale = self.app.text_scale()
        return (fam, max(7, round(size * scale)), "bold" if bold else "normal")

    def _icon(self, sheet, idx, size):
        """One icon from a sheet (grey or white), as its own PhotoImage."""
        key = (sheet, idx)
        if key in self.icon_imgs:
            return self.icon_imgs[key]
        path = os.path.join(ICON_DIR, "icons_%s.png" % sheet)
        try:
            src = self.imgs.get(sheet) or tk.PhotoImage(master=self.app.root, file=path)
            self.imgs[sheet] = src
            img = tk.PhotoImage(master=self.app.root, width=size, height=size)
            img.tk.call(img, "copy", src, "-from", idx * size, 0, idx * size + size, size)
        except tk.TclError:
            img = None
        self.icon_imgs[key] = img
        return img

    # ------------------------------------------------------------------ the column of round icons
    def _build_column(self):
        for w in self.column.winfo_children():
            w.destroy()
        self.buttons = []
        px = self.app.px
        size = px(56)
        for i, name in enumerate(self.pages()):
            cv = tk.Canvas(self.column, width=size + px(12), height=size + px(12), highlightthickness=0, borderwidth=0,
                           bg=self.app.colour("BG"), cursor="hand2")
            cv.pack(pady=(0, px(8)))
            cv.bind("<Button-1>", lambda e, n=i: self.choose(n))
            cv.bind("<Enter>", lambda e, n=name: self.set_hover(n))
            cv.bind("<Leave>", lambda e, n=name: self.set_hover(None, n))
            self.buttons.append((cv, name))
        self.sync()

    def _draw_icon(self, cv, name, chosen):
        px = self.app.px
        cv.delete("all")
        cv.configure(bg=self.app.colour("BG"))
        size = px(56)
        o = px(6)
        if chosen:
            cv.create_oval(1, 1, size + 2 * o - 1, size + 2 * o - 1, outline=ORANGE_HEX, width=max(1, px(1.5)))
        fill = ORANGE_HEX if chosen else "#9a9a9a"
        ring = ORANGE_HEX if chosen else "#d2d2d2"
        cv.create_oval(o, o, o + size, o + size, fill=fill, outline=ring, width=max(2, px(3)))
        img = self._icon("white" if chosen else "grey", icon_index(PAGE_ICONS.get(name, "commands")), 32)
        if img is not None:
            cv.create_image(o + size // 2, o + size // 2, image=img)
            cv.image = img

    def choose(self, i):
        self.app.kh_sound("select")
        self.app.nb.select(i)
        self.sync()

    def set_hover(self, name, leaving=None):
        if name is None and self.hover != leaving:
            return
        if name is not None and name != self.hover:
            self.app.kh_sound("move")
        self.hover = name
        self.draw_bottom()

    def sync(self):
        if not self.active:
            return
        try:
            cur = self.app.nb.index("current")
        except tk.TclError:
            cur = 0
        for i, (cv, name) in enumerate(self.buttons):
            self._draw_icon(cv, name, i == cur)
        self.draw_bottom()

    def draw_bottom(self):
        pages = self.pages()
        try:
            cur = pages[self.app.nb.index("current")]
        except (tk.TclError, IndexError):
            cur = ""
        name = self.hover or cur
        self.bottom.configure(text="%s   %s" % (name.upper(), DESCRIPTIONS.get(name, "")), font=self.font(12))

    # ------------------------------------------------------------------ the slanted bar (top right)
    def draw_hud(self):
        app, px = self.app, self.app.px
        cv = self.hud
        cv.delete("all")
        cv.configure(bg=app.colour("BG"))
        accounts = app.store.accounts()
        online = sum(1 for a in accounts if app.is_online(a.user_id))
        frac = (online / len(accounts)) if accounts else 0.0
        main = app.store.main()
        name = main.label if main else "Puppy Companion"
        w, h = px(240), px(18)
        x, y = px(70), px(20)
        cv.create_text(x + px(4), px(2), text=name, anchor="nw", font=self.font(11, bold=True), fill=INK)
        cv.create_rectangle(0, y, px(62), y + h, fill="#ffffff", outline=khart.to_hex(PLATE_EDGE))
        cv.create_text(px(31), y + h // 2, text="Lv %d" % max(1, len(accounts)), font=self.font(10, bold=True), fill=INK)
        cv.create_polygon(*slanted(x, y, w, h, px(8)), fill="#2a2c32", outline="#e8eaf0", width=max(1, px(1.5)))
        if frac > 0:
            fw = max(px(10), int((w - px(6)) * frac))
            cv.create_polygon(*slanted(x + px(3), y + px(3), fw, h - px(6), px(6)), fill=khart.to_hex(bar_rgb(frac)), outline="")
        cv.create_text(x + w - px(10), y + h + px(1), text="%d / %d in game" % (online, len(accounts)), anchor="ne",
                       font=self.font(9), fill=INK)

    # ------------------------------------------------------------------ ttk look
    def _ttk(self, on):
        app = self.app
        style = ttk.Style(app.root)
        st = app._kh
        if not on:
            for name, layout in st["saved"].items():
                style.layout(name, layout)
            style.configure("TLabelframe", padding=st["lf"][0], labelmargins=st["lf"][1])
            app.nb.configure(style="TNotebook")
            return
        k = app.k
        bg = khart.hex_rgb(app.colour("BG"))
        faces = {"btn": button_face(bg, k, "normal"), "btn_h": button_face(bg, k, "hover"),
                 "btn_p": button_face(bg, k, "pressed"), "btn_d": button_face(bg, k, "disabled"),
                 "acc": button_face(bg, k, "accent"), "frame": frame_face(bg, k)}
        for key, rows in faces.items():
            if key in self.imgs:
                khart.fill_photo(self.imgs[key], rows)
            else:
                self.imgs[key] = khart.photo(app.root, rows)
        im = self.imgs
        if not self.made:
            b = max(2, round(4 * k))
            for el, face in (("SAOButton.bg", "btn"), ("SAOAccent.bg", "acc")):
                style.element_create(el, "image", im[face], ("disabled", im["btn_d"]), ("pressed", im["btn_p"]),
                                     ("active", im["btn_h"]), border=b, sticky="nsew")
            style.element_create("SAOFrame.border", "image", im["frame"], border=b, sticky="nsew")
            self.made = True

        def button_layout(el):
            return [(el, {"sticky": "nsew", "children": [("Button.padding", {"sticky": "nsew", "children": [
                ("Button.label", {"sticky": "nsew"})]})]})]
        style.layout("TButton", button_layout("SAOButton.bg"))
        style.layout("Accent.TButton", button_layout("SAOAccent.bg"))
        style.layout("Danger.TButton", button_layout("SAOButton.bg"))
        style.layout("TLabelframe", [("SAOFrame.border", {"sticky": "nsew"})])
        style.layout("SAOMenu.TNotebook.Tab", [])  # the icon column replaces the tabs
        style.configure("SAOMenu.TNotebook", background=app.colour("BG"), bordercolor=khart.to_hex(PLATE_EDGE),
                        lightcolor=app.colour("BG"), darkcolor=app.colour("BG"), tabmargins=(0, 0, 0, 0))
        style.configure("TButton", padding=(app.px(10), app.px(4)), foreground=INK)
        style.map("TButton", foreground=[("disabled", "#a0a0a8"), ("active", "#ffffff"), ("pressed", "#ffffff")])
        style.configure("Accent.TButton", foreground="#ffffff")
        style.configure("TLabelframe", padding=app.px(12), labelmargins=(app.px(6), 0, 0, 0))
        style.configure("TLabelframe.Label", foreground="#80848e", font=self.font(10, bold=True))
        app.nb.configure(style="SAOMenu.TNotebook")

    def _title(self, on):
        app, px = self.app, self.app.px
        if not on:
            return
        cv = app.kh_title
        cv.delete("all")
        cv.configure(bg=app.colour("BG"))
        f = tkfont.Font(root=app.root, family=self.font(18, title=True)[0], size=self.font(18)[1])
        text = "PUPPY COMPANION"
        w = f.measure(text) + px(8)
        h = f.metrics("linespace") + px(8)
        cv.configure(width=w + px(40), height=h)
        cv.create_text(0, h // 2 - px(2), text=text, font=f, fill=INK, anchor="w")
        cv.create_line(0, h - px(2), w + px(36), h - px(2), fill=ORANGE_HEX, width=max(1, px(1.5)))
        self._title_font = f

    # ------------------------------------------------------------------ on / off
    def apply(self, on):
        app = self.app
        if not on:
            if not self.active:
                return
            self.active = False
            self._ttk(False)
            for w in (self.column, self.stripe, self.bottom, self.hud):
                w.pack_forget()
            app.kh_title.pack_forget()
            app.khmenu.show(False)  # the standard pack layout
            app.title_lbl.pack(side="left", before=app.version_lbl)
            return
        was = self.active
        self.active = True
        self._ttk(True)
        self._title(True)
        if not was:
            for w in (app.top_frame, app.log_frame, app.nb, self.column, self.stripe, self.bottom, self.hud):
                w.pack_forget()
            app.title_lbl.pack_forget()
            app.version_lbl.pack_forget()
            app.top_frame.pack(fill="x")
            app.kh_title.pack(side="left", before=app.multi_lbl)
            self.hud.pack(side="right", before=app.multi_lbl)
            app.log_frame.pack(side="bottom", fill="x")
            self.bottom.pack(side="bottom", fill="x", padx=app.px(16), pady=(0, app.px(8)))
            self.stripe.pack(side="left", fill="y")
            self.column.pack(side="left", fill="y", padx=(app.px(18), 0), pady=(app.px(12), app.px(8)))
            app.nb.pack(side="left", fill="both", expand=True, padx=(app.px(10), app.px(16)), pady=(app.px(10), app.px(8)))
            app.log_text.configure(height=4)
            self._build_column()
            # the column takes width: grow a small window so the pages still fit beside it
            try:
                w, h = app.root.winfo_width(), app.root.winfo_height()
                if w > 1 and (w < app.px(1000) or h < app.px(700)):
                    app.root.geometry("%dx%d" % (max(w, app.px(1000)), max(h, app.px(700))))
            except tk.TclError:
                pass
        self.bottom.configure(bg="#ffffff", fg=INK)
        self.sync()
        self.draw_hud()

    def tick(self):
        if self.active:
            self.draw_hud()
