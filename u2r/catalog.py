"""Finds UmaViewer's settings and the game's data, and lists characters / mini models."""
from __future__ import annotations

import json
import os
import re
import sqlite3

DEFAULT_UMAVIEWER_DIR = r"C:\Users\Admin\Documents\Project\Umaviewer"


def read_umaviewer_config(umaviewer_dir: str) -> dict:
    """UmaViewer writes Config.json next to UmaViewer.exe (Application.dataPath/../Config.json)."""
    for p in (os.path.join(umaviewer_dir, "Config.json"), os.path.join(umaviewer_dir, "UmaViewer_Data", "..", "Config.json")):
        try:
            with open(p, "r", encoding="utf-8-sig") as f:
                return json.load(f)
        except Exception:
            continue
    return {}


def candidate_game_dirs(umaviewer_dir: str) -> list[str]:
    out = []
    main = read_umaviewer_config(umaviewer_dir).get("MainPath")
    if main:
        out.append(main)
    local_low = os.path.join(os.path.expanduser("~"), "AppData", "LocalLow", "Cygames")
    for sub in ("umamusume", "Umamusume"):
        out.append(os.path.join(local_low, sub))
    return [p for p in out if p]


def find_game_dir(umaviewer_dir: str) -> str:
    for p in candidate_game_dirs(umaviewer_dir):
        if os.path.exists(os.path.join(p, "master", "master.mdb")):
            return p
    c = candidate_game_dirs(umaviewer_dir)
    return c[0] if c else ""


def load_characters(game_dir: str) -> list[tuple[int, str]]:
    path = os.path.join(game_dir, "master", "master.mdb")
    if not os.path.exists(path):
        raise FileNotFoundError(f"master.mdb not found in {game_dir}\\master")
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        rows = con.execute(
            'SELECT C.id, T.text FROM chara_data C LEFT JOIN text_data T ON T.id = 6 AND T."index" = C.id ORDER BY C.id'
        ).fetchall()
    finally:
        con.close()
    return [(int(i), n or str(i)) for i, n in rows]


MINI_RE = re.compile(r"^3d/chara/mini/body/mbdy(\d{4})_(\d{2})/pfb_mbdy\1_\2$")


def load_mini_costumes(game_dir: str, umaviewer_dir: str | None = None) -> dict[int, list[str]] | None:
    """{chara_id: [costume, ...]} from the game's meta DB (also the encrypted one, using UmaViewer's keys)."""
    if umaviewer_dir:
        try:
            from .gamedata import GameData
            return GameData(game_dir, umaviewer_dir).mini_costumes()
        except Exception:
            pass
    for name in ("meta", "meta_umaviewer"):
        path = os.path.join(game_dir, name)
        if not os.path.exists(path):
            continue
        try:
            con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
            try:
                rows = con.execute("SELECT n FROM a WHERE n LIKE '3d/chara/mini/body/mbdy%'").fetchall()
            finally:
                con.close()
        except sqlite3.DatabaseError:
            continue
        out: dict[int, list[str]] = {}
        for (n,) in rows:
            m = MINI_RE.match(n)
            if m:
                out.setdefault(int(m.group(1)), []).append(m.group(2))
        return {k: sorted(set(v)) for k, v in out.items()}
    return None
