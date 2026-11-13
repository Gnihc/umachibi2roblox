"""Reads the game's asset index (meta) and asset bundles the same way UmaViewer does.

Keys are not stored in this tool: they are read from UmaViewer's own Config.json
(DBBaseKeyText / DBKeyText / GlobalDBKeyText / ABKeyText), which UmaViewer writes on first start.
"""
from __future__ import annotations

import os
import sqlite3
from dataclasses import dataclass

import numpy as np

from . import catalog


@dataclass
class Entry:
    name: str
    hash: str
    key: int


def _hex(s) -> bytes:
    s = (s or "").replace(" ", "").replace("-", "").replace("0x", "")
    return bytes.fromhex(s) if s else b""


class GameData:
    def __init__(self, game_dir: str, umaviewer_dir: str):
        self.game_dir = game_dir
        self.cfg = catalog.read_umaviewer_config(umaviewer_dir)
        self.entries: dict[str, Entry] = {}
        self._load_meta()

    # ---------------------------------------------------------------- meta
    def _db_key(self) -> bytes:
        region = int(self.cfg.get("Region", 1))
        key = _hex(self.cfg.get("GlobalDBKeyText") if region == 0 else self.cfg.get("DBKeyText"))
        base = _hex(self.cfg.get("DBBaseKeyText"))
        if not key or len(base) < 13:
            raise RuntimeError("The game's meta DB is encrypted and UmaViewer's Config.json has no DB keys. "
                               "Start UmaViewer once so it writes them, then retry.")
        return bytes(b ^ base[i % 13] for i, b in enumerate(key))

    def _rows_plain(self, path):
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            cols = [r[1] for r in con.execute("PRAGMA table_info('a')")]
            q = "SELECT n,h,e FROM a" if "e" in cols else "SELECT n,h,0 FROM a"
            return con.execute(q).fetchall()
        finally:
            con.close()

    def _rows_encrypted(self, path):
        try:
            import apsw  # apsw-sqlite3mc
        except ImportError as ex:
            raise RuntimeError("Encrypted meta DB: install 'apsw-sqlite3mc' (pip install apsw-sqlite3mc).") from ex
        con = apsw.Connection(path, flags=apsw.SQLITE_OPEN_READONLY)
        try:
            con.execute("PRAGMA cipher='chacha20'")          # UmaViewer: MC_Config(db, "cipher", 3)
            con.execute(f"PRAGMA hexkey='{self._db_key().hex()}'")
            return list(con.execute("SELECT n,h,e FROM a"))
        finally:
            con.close()

    def _load_meta(self):
        rows = None
        for name in ("meta", "meta_umaviewer"):
            path = os.path.join(self.game_dir, name)
            if not os.path.exists(path):
                continue
            try:
                rows = self._rows_plain(path)
            except sqlite3.DatabaseError:
                rows = self._rows_encrypted(path)
            break
        if rows is None:
            raise FileNotFoundError(f"No meta DB in {self.game_dir}")
        for n, h, e in rows:
            if n and h:
                self.entries[n] = Entry(n, h, int(e or 0))

    # ---------------------------------------------------------------- bundles
    def _ab_keys(self, key: int) -> bytes:
        base = _hex(self.cfg.get("ABKeyText"))
        if not base:
            raise RuntimeError("Encrypted asset bundle but UmaViewer's Config.json has no ABKeyText.")
        kb = int(key & 0xFFFFFFFFFFFFFFFF).to_bytes(8, "little")
        return bytes(b ^ kb[j] for b in base for j in range(8))

    def bundle_bytes(self, name: str) -> bytes:
        e = self.entries.get(name)
        if not e:
            raise KeyError(name)
        path = os.path.join(self.game_dir, "dat", e.hash[:2], e.hash)
        with open(path, "rb") as f:
            data = bytearray(f.read())
        if e.key and len(data) > 256:
            keys = np.frombuffer(self._ab_keys(e.key), np.uint8)
            arr = np.frombuffer(data, np.uint8).copy()
            idx = np.arange(256, len(arr))
            arr[256:] ^= keys[idx % len(keys)]
            data = arr.tobytes()
        return bytes(data)

    def load(self, name: str):
        import UnityPy
        return UnityPy.load(self.bundle_bytes(name))

    # ---------------------------------------------------------------- queries
    def mini_costumes(self) -> dict[int, list[str]]:
        out: dict[int, list[str]] = {}
        for n in self.entries:
            m = catalog.MINI_RE.match(n)
            if m:
                out.setdefault(int(m.group(1)), []).append(m.group(2))
        return {k: sorted(set(v)) for k, v in out.items()}

    def mini_clips(self, chara_id: int, include_general: bool = False) -> list[str]:
        """Same filter as UmaViewer's Animations > Mini list."""
        out = []
        for n in self.entries:
            if not n.startswith("3d/motion/") or "mini" not in n:
                continue
            if any(x in n for x in ("mirror", "facial", "_cam")) or n.endswith("_s") or n.endswith("_e"):
                continue
            if f"chara/chr{chara_id}" in n and "pose" not in n:
                out.append(n)
            elif include_general and ("/type0" in n or "/type99" in n or "anm_sty_" in n) and not any(
                    x in n for x in ("/tail", "prop")) and not n.endswith(("_pos", "_pose")):
                out.append(n)
        # UmaViewer plays <x>_s (start) before <x>_loop and <x>_e at the end: port them as separate clips
        for n in list(out):
            if n.endswith("_loop"):
                for suffix in ("_s", "_e"):
                    sib = n[:-5] + suffix
                    if sib in self.entries and sib not in out:
                        out.append(sib)
        return sorted(out)

    def mini_body_prefab(self, chara_id: int, costume: str) -> str | None:
        cands = [f"3d/chara/mini/body/mbdy{chara_id}_{costume}/pfb_mbdy{chara_id}_{costume}",
                 f"3d/chara/mini/body/mbdy{chara_id}_00/pfb_mbdy{chara_id}_00"]
        for c in cands:
            if c in self.entries:
                return c
        for n in sorted(self.entries):   # any mini body: mini rigs share their skeleton
            if catalog.MINI_RE.match(n):
                return n
        return None
