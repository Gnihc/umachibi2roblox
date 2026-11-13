"""Diagnostics: describe what mini clips (body / _face / _ear / *_driven) animate, as plain text/JSON.

Runs on the user's machine with their own game data and UmaViewer keys; the report contains only
channel names, ids and value ranges, no asset data.

  Uma2Roblox.exe inspect 1001                 # a character: its mini clips and their facial/ear siblings
  Uma2Roblox.exe inspect <dat file> [...]     # raw files from the game's dat folder (name = asset hash)
"""
from __future__ import annotations

import json
import os

import numpy as np

from .anim import _FACE_ATTRS, decode_clip

ATTR_NAMES = {1: "position", 2: "rotation", 3: "scale", 4: "euler"}
SIBLINGS = ("_face", "_face_driven", "_ear", "_ear_driven")


def _clip_report(tt: dict, name: str, skel=None, samples: int = 9) -> dict:
    c = decode_clip(tt, name)
    T = np.linspace(0, max(c.length, 1e-3), samples)
    from .anim import FACE_LOCATORS, path_hash
    known = {path_hash(n): n for n in list(FACE_LOCATORS.values()) + ["Cheek_Ctrl", "Ear_L_Ctrl", "Ear_R_Ctrl"]}
    names = (lambda h: skel.names[skel.by_hash[h]] if skel and h in skel.by_hash else known.get(h, f"hash:{h:08x}"))
    transforms = []
    for (h, attr), f in sorted(c.tracks.items(), key=lambda kv: names(kv[0][0])):
        v = np.asarray(f(T))
        transforms.append({"bone": names(h), "channel": ATTR_NAMES.get(attr, attr),
                           "first": np.round(v[0], 4).tolist(), "last": np.round(v[-1], 4).tolist(),
                           "range": float(np.ptp(v, axis=0).max()) if v.size else 0.0})
    other = []
    for o in c.other:
        v = np.asarray(o["f"](T))
        label = _FACE_ATTRS.get(o["attribute"])
        other.append({"target": names(o["path"]), "attribute": f"{o['attribute']:08x}",
                      "attributeGuess": f"{label[0]}.{label[1]}" if label else None,
                      "typeID": o["typeID"], "customType": o["customType"],
                      "samples": np.round(v, 4).tolist(), "distinct": sorted(set(np.round(v, 4).tolist()))[:24]})
    mc = tt.get("m_MuscleClip", {})
    return {"clip": name, "length": c.length, "sampleRate": c.sample_rate,
            "bindings": len((tt.get("m_ClipBindingConstant") or {}).get("genericBindings") or []),
            "loopTime": bool(mc.get("m_LoopTime", False)),
            "transformChannels": transforms, "otherChannels": other}


def _objects_report(env, name: str, skel=None) -> list:
    out = []
    for o in env.objects:
        t = o.type.name
        if t == "AnimationClip":
            out.append(_clip_report(o.read_typetree(), name, skel))
        elif t in ("GameObject",):
            try:
                out.append({"type": t, "name": o.read_typetree().get("m_Name")})
            except Exception:
                out.append({"type": t})
        elif t not in ("Transform", "AssetBundle"):
            out.append({"type": t})
    return out


def inspect_character(gd, chara_id: int, costume: str = "00", max_clips: int = 4, log=print) -> dict:
    from .rig import build_skeleton
    rep = {"chara": chara_id, "costume": costume}
    try:
        skel = build_skeleton(gd, chara_id, costume, log)
        rep["skeleton"] = [{"name": n, "path": p} for n, p in zip(skel.names, skel.paths)]
    except Exception as ex:
        skel = None
        rep["skeletonError"] = str(ex)
    body = [n for n in gd.mini_clips(chara_id) if "/body/" in n]
    rep["bodyClips"] = body
    rep["siblings"] = {n: [s for s in SIBLINGS if n.replace("/body/", "/facial/", 1) + s in gd.entries] for n in body}
    # all facial-ish entries for this character, in case they're named differently
    rep["facialEntries"] = sorted(n for n in gd.entries if n.startswith("3d/motion/mini/") and f"chr{chara_id}" in n
                                  and "/facial/" in n)
    detail = []
    pick = [n for n in body if n.endswith("_loop")][:max_clips] or body[:max_clips]
    for n in pick:
        for full in [n] + [n.replace("/body/", "/facial/", 1) + s for s in SIBLINGS]:
            if full not in gd.entries:
                continue
            try:
                detail += _objects_report(gd.load(full), full, skel)
            except Exception as ex:
                detail.append({"clip": full, "error": str(ex)})
    rep["clips"] = detail
    return rep


def inspect_files(gd, paths: list[str]) -> dict:
    by_hash = {e.hash: e for e in gd.entries.values()}
    rep = {"files": []}
    for p in paths:
        h = os.path.basename(p)
        e = by_hash.get(h)
        if not e:
            rep["files"].append({"file": h, "error": "hash not found in the game's meta (is this from the dat folder?)"})
            continue
        try:
            import UnityPy
            env = UnityPy.load(gd.bundle_bytes(e.name))
            rep["files"].append({"file": h, "name": e.name, "objects": _objects_report(env, e.name)})
        except Exception as ex:
            rep["files"].append({"file": h, "name": e.name, "error": str(ex)})
    return rep


def write_report(rep: dict, out_path: str) -> str:
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=1)
    return out_path
