"""Uma2Roblox desktop app (tkinter).

Lists characters from the game data, shows which mini models are not ported yet, and watches
for PMX files saved by UmaViewer's "Export Model" button. Every new export is converted to a
cartoon-shaded, Roblox-ready GLB automatically.
"""
from __future__ import annotations

import os
import queue
import shutil
import subprocess
import sys
import threading
import time
import traceback
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from . import catalog
from .convert import Options, convert, is_character
from .pmx import read_pmx
from .registry import PORT, Registry
from .settings import load_settings, save_settings

APP = "Uma2Roblox"


def open_folder(path: str):
    os.makedirs(path, exist_ok=True)
    if sys.platform == "win32":
        os.startfile(path)  # noqa
    elif sys.platform == "darwin":
        subprocess.Popen(["open", path])
    else:
        subprocess.Popen(["xdg-open", path])


# --------------------------------------------------------------------------- watcher
class Watcher(threading.Thread):
    """Polls folders for new *.pmx files and converts them once they stop growing."""

    def __init__(self, app: "App"):
        super().__init__(daemon=True)
        self.app = app
        self.seen: dict[str, float] = {}
        self.pending: dict[str, tuple[int, float]] = {}
        self.stop_flag = threading.Event()
        self.manual: "queue.Queue[str]" = queue.Queue()
        for d in self.app.watch_dirs():
            for p in self._list(d):
                self.seen[p] = os.path.getmtime(p)   # ignore exports that existed before start

    @staticmethod
    def _list(d):
        try:
            return [os.path.join(d, f) for f in os.listdir(d) if f.lower().endswith(".pmx")]
        except OSError:
            return []

    def run(self):
        while not self.stop_flag.is_set():
            try:
                while not self.manual.empty():
                    self.process(self.manual.get(), move=False)
                for d in self.app.watch_dirs():
                    for p in self._list(d):
                        try:
                            st = os.stat(p)
                        except OSError:
                            continue
                        if self.seen.get(p) == st.st_mtime:
                            continue
                        prev = self.pending.get(p)
                        if prev and prev[0] == st.st_size and time.time() - prev[1] >= 1.0:
                            self.pending.pop(p, None)
                            self.seen[p] = st.st_mtime
                            self.process(p, move=True)
                        elif not prev or prev[0] != st.st_size:
                            self.pending[p] = (st.st_size, time.time())
            except Exception:
                self.app.post("log", traceback.format_exc())
            self.stop_flag.wait(1.0)

    def process(self, pmx: str, move: bool):
        app = self.app
        try:
            model = read_pmx(pmx)
            if move and not is_character(pmx, model):
                # watched folder: leave props / stages / other exports alone
                app.post("log", f"Skipped (not a character export, left in place): {os.path.basename(pmx)}")
                return
            app.post("log", f"Found export: {pmx}")
            stem = os.path.splitext(os.path.basename(pmx))[0]
            work = os.path.join(app.out_dir(), "work", f"{stem}_{time.strftime('%Y%m%d-%H%M%S')}")
            os.makedirs(work, exist_ok=True)
            src_dir = os.path.dirname(pmx)
            # copy the textures the PMX references (+ the shad_c / _all companions the converter uses)
            for rel in model.textures:
                rel = rel.replace("\\", "/")
                base, ext = os.path.splitext(rel)
                for cand in {rel, base.replace("_diff", "_shad_c") + ext, base + "_all" + ext}:
                    s = os.path.join(src_dir, cand)
                    if os.path.exists(s):
                        dst = os.path.join(work, cand)
                        os.makedirs(os.path.dirname(dst), exist_ok=True)
                        shutil.copy2(s, dst)
            dst_pmx = os.path.join(work, os.path.basename(pmx))
            if move:
                try:
                    shutil.move(pmx, dst_pmx)
                except OSError:
                    shutil.copy2(pmx, dst_pmx)
            else:
                shutil.copy2(pmx, dst_pmx)
            ear = None
            if app.options().ear_bones:
                try:
                    from .rig import ear_rig_for
                    ear = ear_rig_for(app.gamedata(), dst_pmx, log=lambda s: app.post("log", s))
                except Exception as ex:
                    app.post("log", f"  ears: game rig not available ({ex}); ears stay fixed to the head")
            res = convert(dst_pmx, app.out_dir(), app.options(), log=lambda s: app.post("log", s), ear_rig=ear)
            app.registry.mark_exported(res.chara_id, res.name, res.costume, os.path.basename(res.glb))
            app.post("converted", res)
            if app.options().port_animations:
                app.port_animations(res.meta)
        except Exception as ex:
            app.post("log", f"FAILED {os.path.basename(pmx)}: {ex}\n{traceback.format_exc()}")


# --------------------------------------------------------------------------- options dialog
class OptionsDialog(tk.Toplevel):
    def __init__(self, app: "App"):
        super().__init__(app.root)
        self.app = app
        self.title("Cartoon / export options")
        self.resizable(False, False)
        o = app.options()
        self.v = {
            "shade": tk.StringVar(value=o.shade),
            "flatten_normals": tk.BooleanVar(value=o.flatten_normals),
            "outline": tk.BooleanVar(value=o.outline),
            "outline_width": tk.DoubleVar(value=o.outline_width),
            "outline_color": tk.StringVar(value="#%02x%02x%02x" % tuple(o.outline_color)),
            "cel_on_face": tk.BooleanVar(value=o.cel_on_face),
            "cel_threshold": tk.DoubleVar(value=o.cel_threshold),
            "cel_softness": tk.DoubleVar(value=o.cel_softness),
            "light": tk.StringVar(value=", ".join(str(x) for x in o.light_dir)),
            "max_texture": tk.IntVar(value=o.max_texture),
            "prune_bones": tk.BooleanVar(value=o.prune_bones),
            "colorkey_parts": tk.StringVar(value=o.colorkey_parts),
            "port_animations": tk.BooleanVar(value=o.port_animations),
            "general_animations": tk.BooleanVar(value=o.general_animations),
            "anim_fps": tk.DoubleVar(value=o.anim_fps),
            "root_motion": tk.StringVar(value=o.root_motion),
            "ear_bones": tk.BooleanVar(value=o.ear_bones),
            "face_variants": tk.BooleanVar(value=o.face_variants),
            "outline_exclude": tk.StringVar(value=o.outline_exclude),
            "cel_exclude": tk.StringVar(value=o.cel_exclude),
        }
        f = ttk.Frame(self, padding=12)
        f.pack(fill="both", expand=True)
        r = 0

        def row(label, widget):
            nonlocal r
            ttk.Label(f, text=label).grid(row=r, column=0, sticky="w", pady=2, padx=(0, 10))
            widget.grid(row=r, column=1, sticky="we", pady=2)
            r += 1

        row("Shading", ttk.Combobox(f, textvariable=self.v["shade"], values=["cel", "flat"], state="readonly", width=10))
        row("Disable Roblox shading (normals up)", ttk.Checkbutton(f, variable=self.v["flatten_normals"]))
        row("Outline (inverted hull)", ttk.Checkbutton(f, variable=self.v["outline"]))
        row("Outline width (x model height)", ttk.Spinbox(f, textvariable=self.v["outline_width"], from_=0.001, to=0.03, increment=0.001, width=10))
        row("Outline colour (#rrggbb)", ttk.Entry(f, textvariable=self.v["outline_color"], width=12))
        row("Outline exclude", ttk.Entry(f, textvariable=self.v["outline_exclude"], width=34))
        row("Cel shadow on face", ttk.Checkbutton(f, variable=self.v["cel_on_face"]))
        row("Shadow threshold", ttk.Spinbox(f, textvariable=self.v["cel_threshold"], from_=-0.5, to=0.5, increment=0.05, width=10))
        row("Shadow edge softness", ttk.Spinbox(f, textvariable=self.v["cel_softness"], from_=0.001, to=0.2, increment=0.01, width=10))
        row("Light dir x, y(up), z(front)", ttk.Entry(f, textvariable=self.v["light"], width=20))
        row("Cel exclude", ttk.Entry(f, textvariable=self.v["cel_exclude"], width=34))
        row("Max texture size", ttk.Combobox(f, textvariable=self.v["max_texture"], values=[256, 512, 1024], state="readonly", width=10))
        row("Prune unused bones", ttk.Checkbutton(f, variable=self.v["prune_bones"]))
        row("Key out background (no alpha)", ttk.Entry(f, textvariable=self.v["colorkey_parts"], width=34))
        row("Ear bones from game rig (for ear motion)", ttk.Checkbutton(f, variable=self.v["ear_bones"]))
        row("Face expression variants (eyes/mouth/mayu)", ttk.Checkbutton(f, variable=self.v["face_variants"]))
        row("Port mini animations", ttk.Checkbutton(f, variable=self.v["port_animations"]))
        row("  …include General mini animations", ttk.Checkbutton(f, variable=self.v["general_animations"]))
        row("  Animation keyframes per second", ttk.Combobox(f, textvariable=self.v["anim_fps"], values=[10, 15, 20, 30], width=10))
        row("  Root motion (inplace = stay in place)", ttk.Combobox(f, textvariable=self.v["root_motion"], values=["inplace", "full", "none"], state="readonly", width=10))
        b = ttk.Frame(f)
        b.grid(row=r, column=0, columnspan=2, sticky="e", pady=(10, 0))
        ttk.Button(b, text="Defaults", command=self.defaults).pack(side="left", padx=4)
        ttk.Button(b, text="Save", command=self.save).pack(side="left")
        self.transient(app.root)
        self.grab_set()

    def defaults(self):
        self.app.settings["options"] = {}
        self.destroy()
        OptionsDialog(self.app)

    def save(self):
        try:
            c = self.v["outline_color"].get().lstrip("#")
            light = [float(x) for x in self.v["light"].get().split(",")]
            assert len(light) == 3
            opts = {
                "shade": self.v["shade"].get(),
                "flatten_normals": self.v["flatten_normals"].get(),
                "outline": self.v["outline"].get(),
                "outline_width": float(self.v["outline_width"].get()),
                "outline_color": [int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16)],
                "cel_on_face": self.v["cel_on_face"].get(),
                "cel_threshold": float(self.v["cel_threshold"].get()),
                "cel_softness": float(self.v["cel_softness"].get()),
                "light_dir": light,
                "max_texture": int(self.v["max_texture"].get()),
                "prune_bones": self.v["prune_bones"].get(),
                "colorkey_parts": self.v["colorkey_parts"].get(),
                "port_animations": self.v["port_animations"].get(),
                "general_animations": self.v["general_animations"].get(),
                "anim_fps": float(self.v["anim_fps"].get()),
                "root_motion": self.v["root_motion"].get(),
                "ear_bones": self.v["ear_bones"].get(),
                "face_variants": self.v["face_variants"].get(),
                "outline_exclude": self.v["outline_exclude"].get(),
                "cel_exclude": self.v["cel_exclude"].get(),
            }
        except Exception:
            messagebox.showerror(APP, "Check the values (colour like #291c21, light like 0, 0.85, 0.55).", parent=self)
            return
        self.app.settings["options"] = opts
        self.app.save()
        self.destroy()


# --------------------------------------------------------------------------- general animations
class GeneralDialog(tk.Toplevel):
    """Pick Mini > General clips (not tied to a character). They ride along with the next export's animation
    port, or are ported onto an already converted model right away. Each model remembers its General clips."""

    def __init__(self, app: "App"):
        super().__init__(app.root)
        self.app = app
        self.title("General mini animations")
        self.geometry("620x560")
        self.minsize(480, 400)
        self.clips: list[str] = []
        self.picked: set[str] = set(app.settings.get("general_picks", []))

        f = ttk.Frame(self, padding=10)
        f.pack(fill="both", expand=True)
        ttk.Label(f, text="Animations not tied to a character. Every mini shares one skeleton, so any of these "
                          "plays on any model. Click a row to pick it.", wraplength=590, justify="left"
                  ).pack(anchor="w")
        flt = ttk.Frame(f)
        flt.pack(fill="x", pady=6)
        ttk.Label(flt, text="Search").pack(side="left")
        self.search = tk.StringVar()
        self.search.trace_add("write", lambda *_: self.refresh())
        ttk.Entry(flt, textvariable=self.search, width=24).pack(side="left", padx=6)
        ttk.Label(flt, text="Category").pack(side="left", padx=(8, 0))
        self.cat = tk.StringVar(value="All")
        self.cat_box = ttk.Combobox(flt, textvariable=self.cat, values=["All"], state="readonly", width=12)
        self.cat_box.pack(side="left", padx=6)
        self.cat_box.bind("<<ComboboxSelected>>", lambda _e: self.refresh())
        self.only_picked = tk.BooleanVar(value=False)
        ttk.Checkbutton(flt, text="Picked only", variable=self.only_picked, command=self.refresh).pack(side="left")

        bottom = ttk.Frame(f)
        bottom.pack(side="bottom", fill="x", pady=(8, 0))
        lst = ttk.Frame(f)
        lst.pack(fill="both", expand=True)
        cols = ("pick", "name", "category", "kind")
        self.tree = ttk.Treeview(lst, columns=cols, show="headings", selectmode="browse")
        for c, w, t in (("pick", 40, "✓"), ("name", 300, "Animation"), ("category", 90, "Category"),
                        ("kind", 110, "Plays")):
            self.tree.heading(c, text=t)
            self.tree.column(c, width=w, anchor="center" if c == "pick" else "w", stretch=(c == "name"))
        sb = ttk.Scrollbar(lst, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=sb.set)
        self.tree.pack(side="left", fill="both", expand=True)
        sb.pack(side="left", fill="y")
        self.tree.bind("<ButtonRelease-1>", self.click)
        self.tree.bind("<space>", lambda _e: self.toggle(self.tree.focus()))
        self.tree.tag_configure("picked", foreground="#1565c0")

        row1 = ttk.Frame(bottom)
        row1.pack(fill="x")
        self.count = ttk.Label(row1, text="Loading…")
        self.count.pack(side="left")
        ttk.Button(row1, text="Clear picks", command=self.clear).pack(side="right")
        self.keep = tk.BooleanVar(value=app.settings.get("general_keep", False))
        ttk.Checkbutton(bottom, text="Keep picks for every export (otherwise they go with the next one only)",
                        variable=self.keep).pack(anchor="w", pady=(6, 0))
        row2 = ttk.Frame(bottom)
        row2.pack(fill="x", pady=(6, 0))
        ttk.Button(row2, text="Attach to next export", command=self.attach).pack(side="right")
        row3 = ttk.Frame(bottom)
        row3.pack(fill="x", pady=(8, 0))
        ttk.Label(row3, text="Or port now onto converted model").pack(side="left")
        self.models = app.converted_models()
        self.target = tk.StringVar(value=self.models[0] if self.models else "")
        ttk.Combobox(row3, textvariable=self.target, values=self.models, state="readonly", width=30
                     ).pack(side="left", padx=6)
        ttk.Button(row3, text="Port now", command=self.port_now,
                   state="normal" if self.models else "disabled").pack(side="left")

        self.transient(app.root)
        self._result = None   # (clips, error) from the loader thread; Tk is only touched from the UI thread
        threading.Thread(target=self._load, daemon=True).start()
        self.after(100, self._poll)

    def _load(self):
        try:
            self._result = (self.app.gamedata().general_clips(), None)
        except Exception as ex:
            self._result = ([], ex)

    def _poll(self):
        if self._result is None:
            self.after(100, self._poll)
        else:
            self._loaded(*self._result)

    def _loaded(self, clips, err):
        if err is not None:
            self.count.config(text=f"Could not read game data: {err}")
            return
        from .gamedata import clip_category
        self.clips = clips
        self.cat_box.config(values=["All"] + sorted({clip_category(n) for n in clips}))
        self.refresh()

    def refresh(self):
        from .gamedata import clip_category
        q = self.search.get().strip().lower()
        cat = self.cat.get()
        self.tree.delete(*self.tree.get_children())
        for n in self.clips:
            short = n.split("/")[-1]
            if q and q not in short.lower():
                continue
            if cat != "All" and clip_category(n) != cat:
                continue
            on = n in self.picked
            if self.only_picked.get() and not on:
                continue
            kind = "start, loop, end" if n.endswith("_loop") else "once"
            self.tree.insert("", "end", iid=n, values=("✓" if on else "", short, clip_category(n), kind),
                             tags=("picked",) if on else ())
        self.count.config(text=f"{len(self.picked)} picked · {len(self.tree.get_children())} shown "
                               f"of {len(self.clips)}")

    def click(self, event):
        if self.tree.identify_region(event.x, event.y) in ("cell", "tree"):
            self.toggle(self.tree.identify_row(event.y))

    def toggle(self, iid):
        if not iid:
            return
        self.picked.symmetric_difference_update({iid})
        on = iid in self.picked
        self.tree.set(iid, "pick", "✓" if on else "")
        self.tree.item(iid, tags=("picked",) if on else ())
        self.count.config(text=f"{len(self.picked)} picked · {len(self.tree.get_children())} shown "
                               f"of {len(self.clips)}")

    def clear(self):
        self.picked.clear()
        self.refresh()

    def _store(self):
        self.app.settings["general_picks"] = sorted(self.picked)
        self.app.settings["general_keep"] = self.keep.get()
        self.app.save()
        self.app.refresh_queue()

    def attach(self):
        self._store()
        if self.picked:
            self.app.log(f"{len(self.picked)} General animation(s) attached to the next export"
                         + (" (and every one after)" if self.keep.get() else ""))
        self.destroy()

    def port_now(self):
        if not self.picked:
            messagebox.showinfo(APP, "Pick at least one animation first.", parent=self)
            return
        meta = os.path.join(self.app.out_dir(), self.target.get())
        picks = sorted(self.picked)
        self._store()
        self.app.log(f"Porting {len(picks)} General animation(s) onto {self.target.get()[:-5]} …")
        threading.Thread(target=lambda: self.app.port_animations(meta, extra=picks, consume=False),
                         daemon=True).start()


# --------------------------------------------------------------------------- main window
class App:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.settings = load_settings()
        # UmaViewer is standalone and can be anywhere: use the saved folder if still valid, else look for it
        uv = self.settings.get("umaviewer_dir", "")
        if not catalog.is_umaviewer_dir(uv):
            uv = catalog.find_umaviewer_dir(uv)
        self.settings["umaviewer_dir"] = uv
        if not self.settings.get("game_dir") or not os.path.isdir(self.settings["game_dir"]):
            self.settings["game_dir"] = catalog.find_game_dir(uv) if uv else ""
        self.settings.setdefault("out_dir", catalog.default_output_dir())
        self.settings.setdefault("only_unported", True)
        self.events: "queue.Queue[tuple[str, object]]" = queue.Queue()
        self.registry = Registry()
        self.registry.load(self.out_dir())
        try:
            os.makedirs(self.inbox(), exist_ok=True)
        except OSError:
            pass
        self.registry.on_change = lambda: self.post("refresh", None)
        self.chars: list[tuple[int, str, list[str] | None]] = []
        self.queue_ids: list[int] = list(self.settings.get("queue", []))

        root.title("Uma2Roblox — UmaViewer mini → Roblox")
        root.geometry("980x680")
        root.minsize(820, 520)
        self._build()
        err = self.registry.start_server()
        self.log(err or f"Studio sync server: http://localhost:{PORT}/uma2roblox/status")
        self.reload_characters()
        self.watcher = Watcher(self)
        self.watcher.start()
        self.log("Watching for UmaViewer exports in:\n  " + "\n  ".join(self.watch_dirs()))
        root.after(200, self._pump)
        if not self.settings["umaviewer_dir"]:
            root.after(400, self.ask_umaviewer)
        root.protocol("WM_DELETE_WINDOW", self.close)

    # ---------------------------------------------------------------- settings helpers
    def out_dir(self) -> str:
        return self.settings["out_dir"]

    def inbox(self) -> str:
        return os.path.join(self.out_dir(), "inbox")

    def options(self) -> Options:
        return Options.from_dict(self.settings.get("options", {}))

    def watch_dirs(self) -> list[str]:
        ds = [self.settings.get("game_dir", ""), self.inbox(), self.settings.get("umaviewer_dir", "")]
        out = []
        for d in ds:
            if d and os.path.isdir(d) and os.path.normcase(os.path.abspath(d)) not in [os.path.normcase(os.path.abspath(x)) for x in out]:
                out.append(d)
        return out

    def save(self):
        self.settings["queue"] = self.queue_ids
        save_settings(self.settings)

    def post(self, kind, payload):
        self.events.put((kind, payload))

    # ---------------------------------------------------------------- UI
    def _build(self):
        style = ttk.Style()
        try:
            style.theme_use("vista" if sys.platform == "win32" else "clam")
        except tk.TclError:
            pass
        top = ttk.Frame(self.root, padding=(10, 8, 10, 0))
        top.pack(fill="x")
        self.path_vars = {}
        for i, (key, label) in enumerate([("umaviewer_dir", "UmaViewer folder"), ("game_dir", "Game data (master.mdb)"), ("out_dir", "Output folder")]):
            ttk.Label(top, text=label).grid(row=i, column=0, sticky="w", padx=(0, 8), pady=2)
            v = tk.StringVar(value=self.settings.get(key, ""))
            self.path_vars[key] = v
            e = ttk.Entry(top, textvariable=v)
            e.grid(row=i, column=1, sticky="we", pady=2)
            e.bind("<FocusOut>", lambda _e, k=key: self.set_path(k, self.path_vars[k].get()))
            e.bind("<Return>", lambda _e, k=key: self.set_path(k, self.path_vars[k].get()))
            ttk.Button(top, text="Browse…", command=lambda k=key: self.browse(k)).grid(row=i, column=2, padx=(6, 0))
        top.columnconfigure(1, weight=1)

        bar = ttk.Frame(self.root, padding=(10, 6))
        bar.pack(fill="x")
        ttk.Button(bar, text="Options…", command=lambda: OptionsDialog(self)).pack(side="left")
        ttk.Button(bar, text="Convert PMX file…", command=self.convert_file).pack(side="left", padx=6)
        ttk.Button(bar, text="Open output folder", command=lambda: open_folder(self.out_dir())).pack(side="left")
        ttk.Button(bar, text="Reload characters", command=self.reload_characters).pack(side="left", padx=6)
        ttk.Button(bar, text="Port animations for converted", command=self.port_all_animations).pack(side="left")
        ttk.Button(bar, text="General animations…", command=lambda: GeneralDialog(self)).pack(side="left", padx=6)

        # --- log (packed before the panes so it keeps its height)
        logf = ttk.Frame(self.root, padding=(10, 6, 10, 10))
        logf.pack(side="bottom", fill="x")
        self.logbox = tk.Text(logf, height=9, wrap="word", state="disabled", bg="#1e1e1e", fg="#d4d4d4", relief="flat")
        self.logbox.pack(fill="both", expand=True)

        pan = ttk.PanedWindow(self.root, orient="horizontal")
        pan.pack(fill="both", expand=True, padx=10)

        # --- characters
        left = ttk.Frame(pan)
        pan.add(left, weight=3)
        fl = ttk.Frame(left)
        fl.pack(fill="x", pady=(0, 4))
        ttk.Label(fl, text="Search").pack(side="left")
        self.search = tk.StringVar()
        self.search.trace_add("write", lambda *_: self.refresh_list())
        ttk.Entry(fl, textvariable=self.search, width=22).pack(side="left", padx=6)
        self.only_unported = tk.BooleanVar(value=self.settings.get("only_unported", True))
        ttk.Checkbutton(fl, text="Only not ported", variable=self.only_unported, command=self._toggle_only).pack(side="left")
        self.count_lbl = ttk.Label(fl, text="")
        self.count_lbl.pack(side="right")
        cols = ("id", "name", "mini", "status")
        self.tree = ttk.Treeview(left, columns=cols, show="headings", selectmode="extended")
        for c, w, t in (("id", 60, "ID"), ("name", 220, "Name"), ("mini", 90, "Mini costumes"), ("status", 90, "Status")):
            self.tree.heading(c, text=t)
            self.tree.column(c, width=w, anchor="w", stretch=(c == "name"))
        sb = ttk.Scrollbar(left, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=sb.set)
        self.tree.pack(side="left", fill="both", expand=True)
        sb.pack(side="left", fill="y")
        self.tree.bind("<Double-1>", lambda _e: self.add_selected())
        self.tree.tag_configure("done", foreground="#2e7d32")
        self.tree.tag_configure("exported", foreground="#1565c0")

        # --- queue
        right = ttk.Frame(pan, padding=(10, 0, 0, 0))
        pan.add(right, weight=2)
        ttk.Button(right, text="Add selected to queue  →", command=self.add_selected).pack(fill="x")
        self.next_lbl = tk.Label(right, text="", justify="left", anchor="w", wraplength=330,
                                 bg="#fff8e1", fg="#3e2723", padx=8, pady=8, relief="groove")
        self.next_lbl.pack(fill="x", pady=(6, 0))
        ttk.Label(right, text="Queue (export these from UmaViewer):").pack(anchor="w", pady=(8, 2))
        qb = ttk.Frame(right)
        qb.pack(side="bottom", fill="x", pady=4)
        self.qlist = tk.Listbox(right, height=4, activestyle="none")
        self.qlist.pack(fill="both", expand=True)
        ttk.Button(qb, text="Remove", command=self.remove_queued).pack(side="left")
        ttk.Button(qb, text="Clear", command=self.clear_queue).pack(side="left", padx=4)
        ttk.Button(qb, text="Copy next name", command=self.copy_next).pack(side="right")


    def _toggle_only(self):
        self.settings["only_unported"] = self.only_unported.get()
        self.save()
        self.refresh_list()

    def browse(self, key):
        p = filedialog.askdirectory(initialdir=self.path_vars[key].get() or os.path.expanduser("~"))
        if p:
            self.path_vars[key].set(os.path.normpath(p))
            self.set_path(key, p)

    def ask_umaviewer(self):
        messagebox.showinfo(APP, "Where is UmaViewer?\n\nPick the folder that contains UmaViewer.exe "
                                 "(it can be anywhere). Uma2Roblox reads its Config.json to find your game data.",
                            parent=self.root)
        p = filedialog.askdirectory(title="Folder containing UmaViewer.exe", parent=self.root)
        if not p:
            self.log("UmaViewer folder not set. Use 'Browse…' next to 'UmaViewer folder' when ready.")
            return
        if not catalog.is_umaviewer_dir(p):
            self.log(f"Note: {p} doesn't contain UmaViewer.exe; using it anyway.")
        self.path_vars["umaviewer_dir"].set(os.path.normpath(p))
        self.set_path("umaviewer_dir", p)

    def set_path(self, key, value):
        value = os.path.normpath(value) if value else value
        if self.settings.get(key) == value:
            return
        self.settings[key] = value
        if key == "umaviewer_dir":
            g = catalog.find_game_dir(value)
            if g:
                self.settings["game_dir"] = g
                self.path_vars["game_dir"].set(g)
        if key == "out_dir":
            self.registry.load(value)
            os.makedirs(self.inbox(), exist_ok=True)
        self.save()
        if key in ("umaviewer_dir", "game_dir"):
            self.reload_characters()
        self.log("Watching: " + ", ".join(self.watch_dirs()))

    # ---------------------------------------------------------------- data
    def reload_characters(self):
        gd = self.settings.get("game_dir", "")
        try:
            chars = catalog.load_characters(gd)
        except Exception as ex:
            self.chars = []
            self.log(f"Could not read characters: {ex}\nSet 'Game data' to the folder that contains master\\master.mdb "
                     f"(UmaViewer's Settings → Other → DataPath).")
            self.refresh_list()
            return
        minis = catalog.load_mini_costumes(gd, self.settings.get("umaviewer_dir"))
        if minis is None:
            self.log("Note: the game's meta DB couldn't be read (encrypted, and no keys in UmaViewer's Config.json), "
                     "so mini availability can't be checked; all characters are listed.")
        self.chars = [(i, n, (minis.get(i, []) if minis is not None else None)) for i, n in chars]
        if minis is not None:
            self.chars = [c for c in self.chars if c[2]]
        self.registry.catalog = [(i, n, c or []) for i, n, c in self.chars]
        self.log(f"Loaded {len(self.chars)} characters from {gd}")
        self.refresh_list()

    def refresh_list(self):
        q = self.search.get().strip().lower()
        only = self.only_unported.get()
        self.tree.delete(*self.tree.get_children())
        shown = notported = 0
        for cid, name, costumes in self.chars:
            st = self.registry.status_of(cid)
            if not st:
                notported += 1
            if only and st:
                continue
            if q and q not in name.lower() and q not in str(cid):
                continue
            mini = "?" if costumes is None else " ".join(costumes)
            tag = ("done",) if st == "in Studio" else ("exported",) if st else ()
            self.tree.insert("", "end", iid=str(cid), values=(cid, name, mini, st or "not ported"), tags=tag)
            shown += 1
        self.count_lbl.config(text=f"{notported} not ported · {shown} shown")
        self.refresh_queue()

    def name_of(self, cid):
        return next((n for i, n, _ in self.chars if i == cid), str(cid))

    def add_selected(self):
        for iid in self.tree.selection():
            cid = int(iid)
            if cid not in self.queue_ids:
                self.queue_ids.append(cid)
        self.save()
        self.refresh_queue()

    def remove_queued(self):
        for i in reversed(self.qlist.curselection()):
            del self.queue_ids[i]
        self.save()
        self.refresh_queue()

    def clear_queue(self):
        self.queue_ids.clear()
        self.save()
        self.refresh_queue()

    def copy_next(self):
        if self.queue_ids:
            self.root.clipboard_clear()
            self.root.clipboard_append(self.name_of(self.queue_ids[0]))

    def refresh_queue(self):
        self.qlist.delete(0, "end")
        for cid in self.queue_ids:
            self.qlist.insert("end", f"{cid}  {self.name_of(cid)}")
        if self.queue_ids:
            cid = self.queue_ids[0]
            self.next_lbl.config(text=(
                f"NEXT: {self.name_of(cid)} ({cid})\n\n"
                f"In UmaViewer: pick {self.name_of(cid)} in the Mini list → choose a costume → "
                f"Settings → Model → Export Model → Save.\n"
                f"Keep the suggested file name ({cid}_….pmx). The default save folder is watched; "
                f"you can also save into:\n{self.inbox()}"))
        else:
            self.next_lbl.config(text="Queue is empty. Select characters on the left and add them, "
                                      "or just export any mini from UmaViewer: every export is converted.")
        picks = self.settings.get("general_picks", [])
        if picks:
            names = ", ".join(p.split("/")[-1] for p in picks[:3]) + (f" +{len(picks) - 3} more" if len(picks) > 3 else "")
            when = "every export" if self.settings.get("general_keep") else "the next export"
            self.next_lbl.config(text=self.next_lbl.cget("text")
                                 + f"\n\nGeneral animations going with {when}: {names}")

    # ---------------------------------------------------------------- actions
    # ---------------------------------------------------------------- animations
    _gamedata = None
    _gd_lock = threading.Lock()

    def gamedata(self):
        from .gamedata import GameData
        with self._gd_lock:
            key = (self.settings.get("game_dir"), self.settings.get("umaviewer_dir"))
            if self._gamedata is None or self._gamedata[0] != key:
                self._gamedata = (key, GameData(*key))
            return self._gamedata[1]

    def converted_models(self) -> list[str]:
        """Sidecar names (Uma_*.json) of the models in the output folder."""
        d = self.out_dir()
        return sorted(f for f in os.listdir(d) if f.startswith("Uma_") and f.endswith(".json")) \
            if os.path.isdir(d) else []

    def port_animations(self, meta_path: str, extra=None, consume=True) -> bool:
        """Runs off the UI thread. extra: General clips to attach (default: the picks from General animations…);
        consume: the picks were used, so clear them unless they are kept for every export."""
        from .anim import port_character_animations
        o = self.options()
        picks = list(self.settings.get("general_picks", [])) if extra is None else list(extra)
        try:
            self.post("log", f"Porting mini animations for {os.path.basename(meta_path)[:-5]} …")
            port_character_animations(self.gamedata(), meta_path, o.general_animations, o.anim_fps,
                                      log=lambda m: self.post("log", m), root_motion=o.root_motion,
                                      extra_clips=picks)
        except Exception as ex:
            self.post("log", f"Animations skipped: {ex}")
            return False
        if picks and consume:
            self.post("general_used", picks)
        return True

    def port_all_animations(self):
        metas = [os.path.join(self.out_dir(), f) for f in self.converted_models()]
        if not metas:
            self.log("Nothing converted yet.")
            return
        picks = list(self.settings.get("general_picks", []))

        def work():
            ok = False
            for m in metas:
                ok = self.port_animations(m, extra=picks, consume=False) or ok
            if picks and ok:
                self.post("general_used", picks)
        threading.Thread(target=work, daemon=True).start()

    def convert_file(self):
        p = filedialog.askopenfilename(filetypes=[("PMX", "*.pmx")])
        if p:
            self.watcher.manual.put(p)

    def log(self, msg):
        self.logbox.configure(state="normal")
        self.logbox.insert("end", time.strftime("%H:%M:%S  ") + str(msg).rstrip() + "\n")
        self.logbox.see("end")
        self.logbox.configure(state="disabled")

    def _pump(self):
        try:
            while True:
                kind, payload = self.events.get_nowait()
                if kind == "log":
                    self.log(payload)
                elif kind == "refresh":
                    self.refresh_list()
                elif kind == "general_used":
                    # picks travel with one export only, unless kept for every export
                    if not self.settings.get("general_keep"):
                        left = [p for p in self.settings.get("general_picks", []) if p not in payload]
                        self.settings["general_picks"] = left
                        self.save()
                        self.log("General animations attached; the model keeps them when re-ported.")
                        self.refresh_queue()
                elif kind == "converted":
                    r = payload
                    self.log(f"✔ {os.path.basename(r.glb)}  —  {r.meshes} meshes, {r.triangles} tris, {r.bones} bones"
                             + ("" if r.is_mini else "  (NOT a mini model)"))
                    if r.chara_id in self.queue_ids:
                        self.queue_ids.remove(r.chara_id)
                        self.save()
                    self.refresh_list()
        except queue.Empty:
            pass
        self.root.after(200, self._pump)

    def close(self):
        self.save()
        self.watcher.stop_flag.set()
        self.registry.stop_server()
        self.root.destroy()


def main():
    root = tk.Tk()
    App(root)
    root.mainloop()
