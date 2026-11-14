"""Swing-bone physics of a mini, read from the game's cloth prefabs, for SmartBone 2 in Studio.

The game simulates the Sp_* bones (hair, ribbons, skirt/jacket, belts, bust, tail) with CySpring. Its settings
live in a CySpringDataContainer MonoBehaviour in a "cloth" prefab per part:
    3d/chara/mini/body/mbdy<id>_<costume>/clothes/pfb_mbdy<id>_<costume>_cloth00
    3d/chara/mini/head/mchr<id>_<costume>/clothes/pfb_mchr<id>_<costume>_cloth00
    3d/chara/mini/tail/mtail<tail>_00/clothes/pfb_mtail<tail>_00_cloth00   (tail id: master.mdb chara_data)

springParam holds one element per chain root plus _childElements for the rest of the chain, each with the
game's per-bone values (_stiffnessForce, _dragForce, _gravity, _collisionRadius, angle limits); collisionParam
holds spheres and capsules on body bones that the chains collide with. Those values are written to the model's
sidecar as they are (the plugin maps them to SmartBone), with every length converted to GLB metres and every
collider offset to a GLB-space vector, the same way animations are converted.
"""
from __future__ import annotations

import json
import os
import sqlite3

import numpy as np

COLLIDER_TYPES = {0: "sphere", 2: "capsule"}      # 1 = None, 3 = Plane (not used by mini chains)


def tail_model_id(game_dir: str, chara_id: int) -> int | None:
    path = os.path.join(game_dir, "master", "master.mdb")
    if not os.path.exists(path):
        return None
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        row = con.execute("SELECT tail_model_id FROM chara_data WHERE id = ?", (chara_id,)).fetchone()
    except sqlite3.DatabaseError:
        return None
    finally:
        con.close()
    return int(row[0]) if row and row[0] is not None else None


def cloth_prefabs(gd, chara_id: int, costume: str, tail_id: int | None) -> list[tuple[str, str]]:
    """(part, bundle name) of the cloth prefabs that exist for this costume (falling back to costume 00)."""
    out = []
    for part, pattern in (("body", "3d/chara/mini/body/mbdy{i}_{c}/clothes/pfb_mbdy{i}_{c}_cloth00"),
                          ("head", "3d/chara/mini/head/mchr{i}_{c}/clothes/pfb_mchr{i}_{c}_cloth00")):
        for c in dict.fromkeys((costume, "00")):
            n = pattern.format(i=chara_id, c=c)
            if n in gd.entries:
                out.append((part, n))
                break
    if tail_id:
        t = f"mtail{tail_id:04d}_00"
        n = f"3d/chara/mini/tail/{t}/clothes/pfb_{t}_cloth00"
        if n in gd.entries:
            out.append(("tail", n))
    return out


def read_container(env) -> dict | None:
    """The CySpringDataContainer of a cloth prefab, as its typetree."""
    for o in env.objects:
        if o.type.name == "MonoBehaviour":
            try:
                tt = o.read_typetree()
            except Exception:
                continue
            if "springParam" in tt:
                return tt
    return None


def _vec(d) -> np.ndarray:
    return np.array([d["x"], d["y"], d["z"]], np.float64)


def _bone(e: dict, name: str, k: float) -> dict:
    lim = None
    if e.get("_isLimit"):
        lim = [round(float(v), 3) for v in (*_vec(e["_limitAngleMin"]), *_vec(e["_limitAngleMax"]))]
    return {"name": name,
            "stiffness": round(float(e["_stiffnessForce"]), 4),
            "drag": round(float(e["_dragForce"]), 4),
            "gravity": round(float(e["_gravity"]), 4),
            "radius": round(float(e["_collisionRadius"]) * k, 6),     # GLB metres
            "limit": lim}                                              # degrees: min x,y,z, max x,y,z


def convert_container(tt: dict, part: str, skel, ex, A: np.ndarray, gltf_names: dict) -> tuple[list, list]:
    """Spring chains and colliders of one container, in GLB units/axes. gltf_names: game bone -> GLB bone."""
    k = ex.k
    chains = []
    for e in tt.get("springParam") or []:
        elems = [e] + list(e.get("_childElements") or [])
        bones = [_bone(x, gltf_names.get(x["_boneName"], x["_boneName"]), k) for x in elems]
        chains.append({"part": part, "root": bones[0]["name"],
                       "inRig": [b["name"] in gltf_names.values() for b in bones],
                       "moveRate": round(float(e.get("MoveSpringApplyRate", 1.0)), 4),
                       "colliders": list(e.get("_collisionNameList") or []),
                       "bones": bones})
    colliders = []
    for c in tt.get("collisionParam") or []:
        kind = COLLIDER_TYPES.get(int(c.get("_type", -1)))
        target = c.get("_targetObjectName")
        b = skel.by_name.get(target)
        if kind is None or b is None or target not in gltf_names:
            continue
        L = ex.L[b]                                    # bone's world linear part at export (Unity axes, with scale)
        scale = float(np.linalg.norm(L[:, 1])) or 1.0
        to_glb = lambda v: (A @ L @ v * k).round(6).tolist()   # bone-local offset -> GLB world vector
        col = {"name": c["_collisionName"], "bone": gltf_names[target], "type": kind,
               "a": to_glb(_vec(c["_offset"])), "radius": round(float(c["_radius"]) * scale * k, 6),
               "inner": bool(c.get("_isInner"))}
        if kind == "capsule":
            col["b"] = to_glb(_vec(c["_offset2"]))
        colliders.append(col)
    return chains, colliders


def physics_for(gd, meta: dict, skel, ex, game_dir: str = "", log=print) -> dict | None:
    """Physics block for a converted model's sidecar, or None if the game has no cloth data for it."""
    from .anim import _axis
    cid, costume = meta["charaId"], meta["costume"]
    tail = tail_model_id(game_dir or getattr(gd, "game_dir", ""), cid)
    prefabs = cloth_prefabs(gd, cid, costume, tail)
    if not prefabs:
        return None
    A = _axis(meta)
    gltf_names = {b["source"]: b["name"] for b in meta["skeleton"] if b.get("source")}
    chains, colliders, sources = [], [], []
    for part, name in prefabs:
        try:
            tt = read_container(gd.load(name))
        except Exception as e:
            log(f"  physics: {name.split('/')[-1]} skipped: {e}")
            continue
        if tt is None:
            continue
        ch, co = convert_container(tt, part, skel, ex, A, gltf_names)
        chains += ch
        colliders += [c for c in co if c["name"] not in {x["name"] for x in colliders}]
        sources.append(name)
    if not chains:
        return None
    return {"version": 1, "unitScale": round(float(ex.k), 6), "sources": sources,
            "chains": chains, "colliders": colliders}


def port_physics(gd, meta_path: str, log=print, skel=None, ex=None) -> dict | None:
    """Read the model's swing-bone physics from the game and store it in its sidecar ("physics")."""
    with open(meta_path, "r", encoding="utf-8") as f:
        meta = json.load(f)
    if not meta.get("isMini"):
        return None
    if skel is None:
        from .rig import build_skeleton
        skel = build_skeleton(gd, meta["charaId"], meta["costume"], log)
    if ex is None:
        from .anim import match_export_pose
        ex = match_export_pose(skel, meta, [])          # orientation of the rest pose; scale from the rig
    phys = physics_for(gd, meta, skel, ex, log=log)
    if phys is None:
        meta.pop("physics", None)
        log("  physics: no swing-bone data in the game for this costume")
    else:
        meta["physics"] = phys
        rigged = sum(1 for c in phys["chains"] if c["inRig"][0])
        log(f"  physics: {len(phys['chains'])} spring chain(s) ({rigged} on this rig), "
            f"{len(phys['colliders'])} collider(s) from {', '.join(s.split('/')[-1] for s in phys['sources'])}")
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
    return phys
