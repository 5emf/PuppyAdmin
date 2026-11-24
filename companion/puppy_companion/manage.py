"""Manage tab: per-account settings, Roblox profile and privacy, login housekeeping.

Per-account app settings live in accounts.json (prefs) and reach that account's
Puppy Admin through roster.json. Profile, privacy and sign-out go to roblox.com
with that account's own saved login (roblox.ENDPOINTS, unverified until tested).
"""
import base64
import tkinter as tk
from tkinter import messagebox, ttk

from .redact import redact
from .roblox import RobloxError, RobloxSession, fetch_image, headshot_url
from .secure import ProtectorError

INHERIT = "Use Puppy Admin's switch"
ON, OFF = "On", "Off"
TRI = (INHERIT, ON, OFF)
MUTE_CHOICES = ("Muted (default)", "Keep game sound")
FPS_DEFAULT = "Default (30)"
FPS_CHOICES = (FPS_DEFAULT, "15", "20", "24", "30", "40", "45", "60", "90", "120", "144", "240")


def tri_text(v):
    return ON if v is True else OFF if v is False else INHERIT


def tri_value(text):
    return True if text == ON else False if text == OFF else None


def fps_value(text):
    try:
        v = int(float(str(text).strip()))
    except ValueError:
        return None
    return max(15, min(240, v))


def _int(text, lo, hi, default=0):
    try:
        return max(lo, min(hi, int(float(str(text).strip()))))
    except ValueError:
        return default


class ManageTab:
    def __init__(self, app):
        from . import app as appmod  # loaded by now (the app builds this tab)
        self.c = {"bg": appmod.BG, "card": appmod.CARD, "fg": appmod.FG, "accent": getattr(appmod, "ACCENT", "#6c5ce7")}
        self.app = app
        self.store = app.store
        self.current = None       # user id shown on the right
        self.privacy_rows = []    # [(key, var, {label: value}, original_label)]
        self._photo = None
        self._ids = []
        tab = ttk.Frame(app.nb, padding=app.px(12))
        app.nb.add(tab, text="Manage")
        self.tab = tab

        left = ttk.Frame(tab)
        left.grid(row=0, column=0, sticky="nsw")
        ttk.Label(left, text="Account").pack(anchor="w")
        self.listbox = tk.Listbox(left, height=16, width=24, exportselection=False, activestyle="none",
                                  bg=self.c["card"], fg=self.c["fg"], selectbackground=self.c["accent"], relief="flat",
                                  highlightthickness=0)
        self.listbox.pack(fill="y", expand=True, pady=app.pad(6, 0))
        app.raw(self.listbox, bg="CARD", fg="FG", selectbackground="ACCENT", selectforeground="ON_ACCENT")
        self.listbox.bind("<<ListboxSelect>>", lambda e: self._picked())

        self.sub = ttk.Notebook(tab)
        self.sub.grid(row=0, column=1, sticky="nsew", padx=app.pad(12, 0))
        tab.columnconfigure(1, weight=1)
        tab.rowconfigure(0, weight=1)
        self._build_app_page()
        self._build_profile_page()
        self._build_privacy_page()
        self._build_login_page()
        self.reload()

    # pages ------------------------------------------------------------------------------
    def _page(self, title):
        f = ttk.Frame(self.sub, padding=self.app.px(12))
        self.sub.add(f, text=title)
        return f

    def _build_app_page(self):
        app, f = self.app, self._page("This app")
        self.lite_var = tk.StringVar(value=INHERIT)
        self.fps_var = tk.StringVar(value=FPS_DEFAULT)
        self.mute_var = tk.StringVar(value=MUTE_CHOICES[0])
        self.vc_var = tk.StringVar(value=INHERIT)
        self.order_var = tk.StringVar(value="0")
        self.delay_var = tk.StringVar(value="0")
        self.rejoin_var = tk.BooleanVar(value=False)
        self.group_var = tk.StringVar(value="")
        rows = (
            ("Low power (FPS cap, lowest graphics)", ttk.Combobox(f, textvariable=self.lite_var, values=TRI, state="readonly", width=26)),
            ("FPS cap in low power", ttk.Combobox(f, textvariable=self.fps_var, values=FPS_CHOICES, width=26)),
            ("Sound", ttk.Combobox(f, textvariable=self.mute_var, values=MUTE_CHOICES, state="readonly", width=26)),
            ("Auto VC-ban bypass", ttk.Combobox(f, textvariable=self.vc_var, values=TRI, state="readonly", width=26)),
            ("Launch order (lower goes first)", ttk.Spinbox(f, from_=-99, to=99, textvariable=self.order_var, width=6)),
            ("Extra seconds after its launch", ttk.Spinbox(f, from_=0, to=120, textvariable=self.delay_var, width=6)),
        )
        for i, (text, widget) in enumerate(rows):
            ttk.Label(f, text=text).grid(row=i, column=0, sticky="w", pady=app.pad(0, 6))
            widget.grid(row=i, column=1, sticky="w", padx=app.pad(10, 0), pady=app.pad(0, 6))
        r = len(rows)
        ttk.Checkbutton(f, text="Auto-rejoin: relaunch into the main's server if it drops out",
                        variable=self.rejoin_var).grid(row=r, column=0, columnspan=2, sticky="w", pady=app.pad(2, 6))
        ttk.Label(f, text="Group (launch a set together)").grid(row=r + 1, column=0, sticky="w")
        self.group_box = ttk.Combobox(f, textvariable=self.group_var, width=26)
        self.group_box.grid(row=r + 1, column=1, sticky="w", padx=app.pad(10, 0))
        ttk.Label(f, text="Notes").grid(row=r + 2, column=0, sticky="nw", pady=app.pad(8, 0))
        self.notes = tk.Text(f, height=3, width=40, bg=self.c["card"], fg=self.c["fg"], insertbackground=self.c["fg"],
                             relief="flat", wrap="word")
        app.raw(self.notes, bg="CARD", fg="FG", insertbackground="FG")
        self.notes.grid(row=r + 2, column=1, sticky="we", padx=app.pad(10, 0), pady=app.pad(8, 0))
        ttk.Button(f, text="Save", style="Accent.TButton", command=self.save_app).grid(
            row=r + 3, column=1, sticky="e", pady=app.pad(10, 0))
        self.app_hint = ttk.Label(f, style="Dim.TLabel", wraplength=app.px(470), text=(
            "Low power, FPS, sound and VC-ban apply to this account when it runs as an alt; Puppy Admin picks "
            "them up from the roster within a few seconds. Launch order, delay and auto-rejoin are used here."))
        self.app_hint.grid(row=r + 4, column=0, columnspan=2, sticky="w", pady=app.pad(10, 0))
        f.columnconfigure(1, weight=1)

    def _build_profile_page(self):
        app, f = self.app, self._page("Profile")
        self.pic = ttk.Label(f, text="(no picture)", style="Dim.TLabel")
        self.pic.grid(row=0, column=0, rowspan=3, sticky="nw", padx=app.pad(0, 12))
        self.who = ttk.Label(f, text="")
        self.who.grid(row=0, column=1, columnspan=2, sticky="w")
        ttk.Label(f, text="Display name").grid(row=1, column=1, sticky="w", pady=app.pad(8, 0))
        self.dn_var = tk.StringVar()
        ttk.Entry(f, textvariable=self.dn_var, width=28).grid(row=1, column=2, sticky="w", padx=app.pad(8, 0), pady=app.pad(8, 0))
        ttk.Button(f, text="Save display name", command=self.save_display_name).grid(
            row=2, column=2, sticky="w", padx=app.pad(8, 0), pady=app.pad(6, 0))
        ttk.Label(f, text="About").grid(row=3, column=0, sticky="nw", pady=app.pad(12, 0))
        self.about = tk.Text(f, height=6, width=50, bg=self.c["card"], fg=self.c["fg"], insertbackground=self.c["fg"],
                             relief="flat", wrap="word")
        self.app.raw(self.about, bg="CARD", fg="FG", insertbackground="FG")
        self.about.grid(row=3, column=1, columnspan=2, sticky="we", pady=app.pad(12, 0))
        row = ttk.Frame(f)
        row.grid(row=4, column=1, columnspan=2, sticky="e", pady=app.pad(8, 0))
        ttk.Button(row, text="Load from Roblox", command=self.load_profile).pack(side="left")
        ttk.Button(row, text="Save About", command=self.save_about).pack(side="left", padx=app.pad(6, 0))
        self.profile_msg = ttk.Label(f, text="", style="Dim.TLabel", wraplength=app.px(470))
        self.profile_msg.grid(row=5, column=0, columnspan=3, sticky="w", pady=app.pad(8, 0))
        f.columnconfigure(2, weight=1)

    def _build_privacy_page(self):
        app, f = self.app, self._page("Privacy")
        top = ttk.Frame(f)
        top.pack(fill="x")
        ttk.Button(top, text="Load from Roblox", command=self.load_privacy).pack(side="left")
        ttk.Button(top, text="Save changes", style="Accent.TButton", command=self.save_privacy).pack(side="left", padx=app.pad(6, 0))
        self.privacy_msg = ttk.Label(f, text="Load to see this account's privacy and social settings. The choices "
                                             "come from Roblox itself.", style="Dim.TLabel", wraplength=app.px(470))
        self.privacy_msg.pack(anchor="w", pady=app.pad(8, 6))
        self.privacy_box = ttk.Frame(f)
        self.privacy_box.pack(fill="both", expand=True)

    def _build_login_page(self):
        app, f = self.app, self._page("Login")
        self.login_msg = ttk.Label(f, text="", wraplength=app.px(470))
        self.login_msg.pack(anchor="w")
        for text, cmd, style in (("Check login", self.check_login, "TButton"),
                                 ("Update login cookie", self.update_cookie, "TButton"),
                                 ("Sign out everywhere", self.sign_out_everywhere, "Danger.TButton")):
            ttk.Button(f, text=text, command=cmd, style=style).pack(anchor="w", pady=app.pad(8, 0))
        ttk.Label(f, style="Dim.TLabel", wraplength=app.px(470), text=(
            "Update login: paste a fresh cookie when this one expired; it must be the same account. "
            "Sign out everywhere ends the account's sessions on every device and keeps a new login here "
            "if Roblox sends one; open Roblox windows of this account are signed out.")).pack(anchor="w", pady=app.pad(12, 0))

    # selection ----------------------------------------------------------------------------
    def reload(self):
        accounts = sorted(self.store.accounts(), key=lambda a: (a.role != "main", a.label.lower()))
        self._ids = [a.user_id for a in accounts]
        self.listbox.delete(0, "end")
        for a in accounts:
            self.listbox.insert("end", "%s%s" % (a.label, "  (main)" if a.role == "main" else ""))
        self.group_box.configure(values=self.store.groups())
        if self.current in self._ids:
            i = self._ids.index(self.current)
            self.listbox.selection_set(i)
        elif self._ids:
            self.listbox.selection_set(0)
            self.current = None
            self._picked()
        else:
            self.current = None

    def _picked(self):
        sel = self.listbox.curselection()
        if not sel:
            return
        uid = self._ids[sel[0]]
        if uid == self.current:
            return
        self.current = uid
        self.show(uid)

    def select(self, uid):
        if uid in self._ids:
            self.listbox.selection_clear(0, "end")
            self.listbox.selection_set(self._ids.index(uid))
            self.current = None
            self._picked()

    def account(self):
        return self.store.get(self.current) if self.current is not None else None

    def show(self, uid):
        a = self.store.get(uid)
        if not a:
            return
        p = a.prefs
        self.lite_var.set(tri_text(p.get("lite")))
        self.fps_var.set(str(p["fps"]) if p.get("fps") else FPS_DEFAULT)
        self.mute_var.set(MUTE_CHOICES[1] if p.get("mute") is False else MUTE_CHOICES[0])
        self.vc_var.set(tri_text(p.get("vc_auto")))
        self.order_var.set(str(p.get("launch_order") or 0))
        self.delay_var.set(str(p.get("extra_delay") or 0))
        self.rejoin_var.set(bool(p.get("auto_rejoin")))
        self.group_var.set(a.group)
        self.notes.delete("1.0", "end")
        self.notes.insert("1.0", p.get("notes") or "")
        self.who.configure(text="%s  (@%s, user %d)" % (a.display_name or a.name, a.name, a.user_id))
        self.dn_var.set(a.display_name or "")
        self.about.delete("1.0", "end")
        self.pic.configure(image="", text="(no picture)")
        self._photo = None
        self.profile_msg.configure(text="Load from Roblox to see the current About and picture.", style="Dim.TLabel")
        self._clear_privacy()
        self.privacy_msg.configure(text="Load to see this account's privacy and social settings. The choices "
                                        "come from Roblox itself.", style="Dim.TLabel")
        self.login_msg.configure(text="Role: %s. Login saved encrypted for your Windows user." % a.role, style="TLabel")

    # this app -----------------------------------------------------------------------------
    def save_app(self):
        a = self.account()
        if not a:
            self.app.log("Pick an account on the left first.")
            return
        changes = {
            "lite": tri_value(self.lite_var.get()),
            "fps": None if self.fps_var.get() == FPS_DEFAULT else fps_value(self.fps_var.get()),
            "mute": False if self.mute_var.get() == MUTE_CHOICES[1] else None,
            "vc_auto": tri_value(self.vc_var.get()),
            "launch_order": _int(self.order_var.get(), -99, 99),
            "extra_delay": _int(self.delay_var.get(), 0, 120),
            "auto_rejoin": bool(self.rejoin_var.get()),
            "notes": self.notes.get("1.0", "end").strip(),
        }
        self.store.set_prefs(a.user_id, changes)
        self.store.set_group(a.user_id, self.group_var.get())
        self.app.log("Saved settings for %s." % a.label)
        self.app.accounts_changed()
        self.show(a.user_id)

    # roblox helpers ---------------------------------------------------------------------------
    def _session(self, uid):
        return RobloxSession(self.store.cookie(uid), opener=self.app.opener)

    def _bg(self, label_widget, busy_text, work, done):
        a = self.account()
        if not a:
            self.app.log("Pick an account on the left first.")
            return None
        label_widget.configure(text=busy_text, style="Dim.TLabel")
        uid = a.user_id

        def wrapped():
            try:
                return work(uid)
            except ProtectorError as e:
                raise RobloxError("The saved login could not be read (%s)." % e)

        def finish(res, err):
            if self.current != uid:
                return  # the user picked another account meanwhile
            done(a, res, err)
        self.app.run_bg(wrapped, finish)
        return uid

    def _error(self, widget, a, what, err):
        text = "%s: %s" % (what, redact(err))
        widget.configure(text=text, style="Bad.TLabel")
        self.app.log("%s - %s" % (a.label, text))

    # profile ----------------------------------------------------------------------------------
    def load_profile(self):
        opener = self.app.opener

        def work(uid):
            prof = self._session(uid).profile(uid)
            img = None
            try:
                url = headshot_url(uid, opener=opener)
                if url:
                    img = fetch_image(url, opener=opener)
            except Exception:
                img = None  # the picture is optional
            return prof, img

        def done(a, res, err):
            if err:
                self._error(self.profile_msg, a, "Could not load the profile", err)
                return
            prof, img = res
            self.dn_var.set(prof["displayName"])
            self.about.delete("1.0", "end")
            self.about.insert("1.0", prof["description"])
            self.who.configure(text="%s  (@%s, user %d)" % (prof["displayName"] or a.name, prof["name"] or a.name, a.user_id))
            if img:
                try:
                    self._photo = tk.PhotoImage(data=base64.b64encode(img).decode("ascii"))
                    self.pic.configure(image=self._photo, text="")
                except tk.TclError:
                    self.pic.configure(text="(picture format not supported)")
            self.profile_msg.configure(text="Loaded from Roblox.", style="Good.TLabel")
        self._bg(self.profile_msg, "Loading from Roblox...", work, done)

    def save_display_name(self):
        name = self.dn_var.get().strip()

        def work(uid):
            s = self._session(uid)
            s.set_display_name(uid, name)
            return s.authenticated_user()

        def done(a, user, err):
            if err:
                self._error(self.profile_msg, a, "Display name not changed", err)
                return
            try:
                self.store.add_or_update(self.store.cookie(a.user_id), user, a.role)
            except (ProtectorError, OSError, ValueError):
                pass
            self.profile_msg.configure(text="Display name is now %s." % user.get("displayName", name), style="Good.TLabel")
            self.app.log("%s: display name changed to %s." % (a.label, user.get("displayName", name)))
            self.app.accounts_changed()
        self._bg(self.profile_msg, "Changing the display name...", work, done)

    def save_about(self):
        text = self.about.get("1.0", "end").strip()

        def work(uid):
            return self._session(uid).set_description(text)

        def done(a, res, err):
            if err:
                self._error(self.profile_msg, a, "About not saved", err)
                return
            self.profile_msg.configure(text="About saved (Roblox may filter some words).", style="Good.TLabel")
            self.app.log("%s: About updated." % a.label)
        self._bg(self.profile_msg, "Saving About...", work, done)

    # privacy ----------------------------------------------------------------------------------
    def _clear_privacy(self):
        for c in self.privacy_box.winfo_children():
            c.destroy()
        self.privacy_rows = []

    def load_privacy(self):
        def work(uid):
            return self._session(uid).privacy_settings()

        def done(a, items, err):
            self._clear_privacy()
            if err:
                self._error(self.privacy_msg, a, "Could not load privacy settings", err)
                return
            if not items:
                self.privacy_msg.configure(text="Roblox returned no settings this app can show.", style="Warn.TLabel")
                return
            for i, it in enumerate(items):
                labels = {lab: val for val, lab in it["options"]}
                cur = next((lab for val, lab in it["options"] if val == it["current"]), "")
                var = tk.StringVar(value=cur)
                ttk.Label(self.privacy_box, text=it["label"]).grid(row=i, column=0, sticky="w", pady=self.app.pad(0, 4))
                box = ttk.Combobox(self.privacy_box, textvariable=var, values=list(labels), state="readonly", width=30)
                box.grid(row=i, column=1, sticky="w", padx=self.app.pad(10, 0), pady=self.app.pad(0, 4))
                if len(labels) < 2:
                    box.state(["disabled"])
                self.privacy_rows.append((it["key"], var, labels, cur))
            self.privacy_msg.configure(text="%d settings loaded. Change any and press Save changes." % len(items),
                                       style="Good.TLabel")
        self._bg(self.privacy_msg, "Loading privacy settings...", work, done)

    def privacy_changes(self):
        out = {}
        for key, var, labels, original in self.privacy_rows:
            if var.get() != original and var.get() in labels:
                out[key] = labels[var.get()]
        return out

    def save_privacy(self):
        changes = self.privacy_changes()
        if not changes:
            self.privacy_msg.configure(text="Nothing changed.", style="Dim.TLabel")
            return

        def work(uid):
            self._session(uid).update_privacy(changes)
            return len(changes)

        def done(a, n, err):
            if err:
                self._error(self.privacy_msg, a, "Privacy not changed", err)
                return
            self.app.log("%s: %d privacy setting%s changed." % (a.label, n, "" if n == 1 else "s"))
            self.load_privacy()
        self._bg(self.privacy_msg, "Saving...", work, done)

    # login --------------------------------------------------------------------------------------
    def check_login(self):
        def work(uid):
            return self._session(uid).authenticated_user()

        def done(a, user, err):
            if err:
                self._error(self.login_msg, a, "Login check failed", err)
            elif user["id"] != a.user_id:
                self.login_msg.configure(text="This cookie now belongs to %s, not %s." % (user["name"], a.name), style="Bad.TLabel")
            else:
                self.login_msg.configure(text="Login OK (%s)." % user["name"], style="Good.TLabel")
        self._bg(self.login_msg, "Checking with Roblox...", work, done)

    def update_cookie(self):
        a = self.account()
        if not a:
            self.app.log("Pick an account on the left first.")
            return
        app = self.app
        dlg = tk.Toplevel(app.root)
        dlg.title("Update login")
        from . import app as appmod
        dlg.configure(bg=appmod.BG, cursor=app.cursor_spec)
        dlg.transient(app.root)
        dlg.resizable(False, False)
        body = ttk.Frame(dlg, padding=app.px(16))
        body.pack(fill="both", expand=True)
        ttk.Label(body, text="New login cookie (.ROBLOSECURITY) for %s" % a.name).grid(row=0, column=0, columnspan=2, sticky="w")
        var = tk.StringVar()
        entry = ttk.Entry(body, textvariable=var, show="•", width=58)
        entry.grid(row=1, column=0, sticky="we", pady=app.pad(6, 0))

        def paste():
            try:
                var.set(app.root.clipboard_get().strip())
            except tk.TclError:
                pass
        ttk.Button(body, text="Paste", command=paste).grid(row=1, column=1, padx=app.pad(6, 0), pady=app.pad(6, 0))
        msg = ttk.Label(body, text="", style="Dim.TLabel", wraplength=app.px(470))
        msg.grid(row=2, column=0, columnspan=2, sticky="w", pady=app.pad(10, 0))
        btn = ttk.Button(body, text="Save", style="Accent.TButton")
        btn.grid(row=3, column=1, sticky="e", pady=app.pad(10, 0))

        def done(cookie, user, err):
            if not dlg.winfo_exists():
                return
            if not err and user["id"] != a.user_id:
                err = "That cookie is for %s, not %s." % (user["name"], a.name)
            if not err:
                try:
                    self.store.replace_cookie(a.user_id, cookie)
                except (ProtectorError, OSError, KeyError) as e:
                    err = redact(str(e))
            if err:
                msg.configure(text=redact(err), style="Bad.TLabel")
                btn.state(["!disabled"])
                return
            var.set("")
            app.log("%s: login updated." % a.label)
            self.login_msg.configure(text="Login updated.", style="Good.TLabel")
            dlg.destroy()

        def submit(*_):
            cookie = var.get().strip()
            if not cookie:
                msg.configure(text="Paste the cookie first.", style="Bad.TLabel")
                return
            btn.state(["disabled"])
            msg.configure(text="Checking the login with Roblox...", style="Dim.TLabel")
            app.run_bg(lambda: RobloxSession(cookie, opener=app.opener).authenticated_user(),
                       lambda user, err: done(cookie, user, err))
        btn.configure(command=submit)
        entry.bind("<Return>", submit)
        app.center_over_root(dlg)
        entry.focus_set()

    def sign_out_everywhere(self, confirm=None):
        a = self.account()
        if not a:
            self.app.log("Pick an account on the left first.")
            return
        ask = confirm or (lambda: messagebox.askyesno(
            "Sign out everywhere",
            "Sign %s out on every device (browsers, phones, open Roblox windows)?\n\n"
            "The companion keeps a new login if Roblox sends one; otherwise add the cookie again "
            "with Update login." % a.label, parent=self.app.root))
        if not ask():
            return

        def work(uid):
            s = self._session(uid)
            fresh = s.logout_everywhere()
            if not fresh:
                return None
            user = s.authenticated_user()
            if user["id"] != uid:
                raise RobloxError("Roblox's new login belongs to another account; it was not saved.")
            self.store.replace_cookie(uid, fresh)
            return user

        def done(acc, user, err):
            if err:
                self._error(self.login_msg, acc, "Sign out everywhere", err)
            elif user:
                self.login_msg.configure(text="Signed out everywhere. The new login is saved here.", style="Good.TLabel")
                self.app.log("%s: signed out on every device; new login saved." % acc.label)
            else:
                self.login_msg.configure(text="Signed out everywhere, but Roblox sent no new login: use Update login.",
                                         style="Warn.TLabel")
                self.app.log("%s: signed out everywhere; add a fresh cookie with Update login." % acc.label)
        self._bg(self.login_msg, "Signing out everywhere...", work, done)
