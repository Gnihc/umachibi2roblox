"""Game-data rig helpers: full mini skeleton (body + head prefabs) and ear bones for the GLB.

UmaViewer's PMX export drops every bone whose name starts with "Ear" (ModelExporter.ReadPMXModel), so
the ears come out welded to the head. Here we take the ear bones from the mini head/hair prefab, place
them on the exported model, and skin the ear vertices to them, so the game's ear animation can play.
"""
from __future__ import annotations

import numpy as np

from .anim import Skeleton, fk, path_hash, skeleton_from_env


def head_prefabs(gd, chara_id: int, costume: str) -> list[str]:
    out = []
    for c in (costume, "00"):
        n = f"3d/chara/mini/head/mchr{chara_id}_{c}/pfb_mchr{chara_id}_{c}_hair"
        if n in gd.entries:
            out.append(n)
            break
    face = "3d/chara/mini/head/mchr0001_00/pfb_mchr0001_00_face0"
    if face in gd.entries:
        out.append(face)
    return out


def merge(body: Skeleton, other: Skeleton) -> Skeleton:
    """Attach bones that only exist in `other` (a head prefab) to the body skeleton, joining on bone names
    the way UmaViewer's MergeModel does. Clips address bones by the CRC32 of their path; head-side clips may
    use paths relative to the head prefab, so those hashes are registered too."""
    names, parents, paths = list(body.names), list(body.parents), list(body.paths)
    rp, rr, rs = list(body.rest_pos), list(body.rest_rot), list(body.rest_scl)
    extra_hash: dict[int, int] = {}
    mapping: dict[int, int] = {}
    for i, n in enumerate(other.names):
        p = other.parents[i]
        if p < 0:
            mapping[i] = 0                      # prefab root -> body animator root
            continue
        if n in body.by_name:
            mapping[i] = body.by_name[n]
        else:
            mapping[i] = len(names)
            names.append(n)
            parents.append(mapping[p])
            paths.append(f"{paths[mapping[p]]}/{n}" if paths[mapping[p]] else n)
            rp.append(other.rest_pos[i]); rr.append(other.rest_rot[i]); rs.append(other.rest_scl[i])
        extra_hash[path_hash(other.paths[i])] = mapping[i]
    sk = Skeleton(names, parents, paths, np.array(rp), np.array(rr), np.array(rs))
    for h, i in extra_hash.items():
        sk.by_hash.setdefault(h, i)
    return sk


def add_suffix_hashes(sk: Skeleton):
    """Also resolve paths relative to any ancestor (clips may be rooted at the head, not the body)."""
    for i, p in enumerate(sk.paths):
        parts = p.split("/") if p else []
        for k in range(1, len(parts)):
            sk.by_hash.setdefault(path_hash("/".join(parts[k:])), i)


def build_skeleton(gd, chara_id: int, costume: str, log=print) -> Skeleton:
    prefab = gd.mini_body_prefab(chara_id, costume)
    if not prefab:
        raise RuntimeError("No mini body prefab found in the game data.")
    sk = skeleton_from_env(gd.load(prefab))
    for hp in head_prefabs(gd, chara_id, costume):
        try:
            sk = merge(sk, skeleton_from_env(gd.load(hp)))
        except Exception as ex:
            log(f"  head prefab {hp.split('/')[-1]} skipped: {ex}")
    add_suffix_hashes(sk)
    return sk


def ear_chains(sk: Skeleton) -> list[list[int]]:
    """Chains of bones named Ear* (root .. tip), one per ear."""
    ears = [i for i, n in enumerate(sk.names) if n.lower().startswith("ear")]
    eset = set(ears)
    roots = [i for i in ears if sk.parents[i] not in eset]
    chains = []
    for r in roots:
        chain, cur = [r], r
        while True:
            kids = [j for j in ears if sk.parents[j] == cur]
            if not kids:
                break
            cur = kids[0]
            chain.append(cur)
        chains.append(chain)
    return chains


def ear_rig(sk: Skeleton) -> dict | None:
    """Ear bones in Unity space (rest pose) plus common bones for aligning with the PMX."""
    chains = ear_chains(sk)
    if not chains:
        return None
    X = fk(sk, None, np.zeros(1)).X[0]
    bones = []
    for ch in chains:
        for i in ch:
            bones.append({"name": sk.names[i], "parent": sk.names[sk.parents[i]], "unity": X[i].tolist()})
    common = {n: X[i].tolist() for i, n in enumerate(sk.names) if n in ("Hip", "Spine", "Chest", "Neck", "Head",
                                                                      "Shoulder_L", "Shoulder_R", "Arm_L", "Arm_R",
                                                                      "Thigh_L", "Thigh_R", "Knee_L", "Knee_R")}
    return {"chains": [[sk.names[i] for i in ch] for ch in chains], "bones": bones, "common": common}


def ear_rig_for(gd, pmx_path: str, log=print) -> dict | None:
    """Ear rig for a UmaViewer PMX export, or None (not a mini / no ears / no game data)."""
    from .convert import identify
    from .pmx import read_pmx
    cid, costume, _, is_mini = identify(pmx_path, read_pmx(pmx_path))
    if not is_mini or not cid:
        return None
    return ear_rig(build_skeleton(gd, cid, costume, log))


# ----------------------------------------------------------------------------- skinning
def _smooth(e0, e1, x):
    t = np.clip((x - e0) / max(e1 - e0, 1e-9), 0, 1)
    return t * t * (3 - 2 * t)


def ear_weights(pos: np.ndarray, candidates: np.ndarray, chains_pos: list[np.ndarray], head_pos: np.ndarray):
    """For each chain (array of joint positions root..tip) -> (vertex ids, segment index per vertex, ear weight).

    Geometric skinning: a vertex belongs to an ear if it lies along the ear's axis (past the root) and
    within a radius of the bone chain; the weight ramps up from the ear root so the base blends into the head.
    """
    out = []
    best_d = np.full(len(pos), np.inf)
    owner = np.full(len(pos), -1)
    per_chain = []
    for ci, P in enumerate(chains_pos):
        P = np.asarray(P, np.float64)
        if len(P) == 1:   # single bone: extend away from the head centre
            d = P[0] - head_pos
            P = np.vstack([P, P[0] + d / (np.linalg.norm(d) + 1e-9) * max(np.linalg.norm(d) * 0.6, 1e-3)])
        else:
            P = np.vstack([P, P[-1] + (P[-1] - P[-2]) * 0.6])   # extend past the tip bone
        length = float(np.linalg.norm(np.diff(P, axis=0), axis=1).sum())
        radius = max(0.45 * length, 1e-4)
        v = pos[candidates]
        seg_d = np.full((len(v), len(P) - 1), np.inf)
        for s in range(len(P) - 1):
            a, b = P[s], P[s + 1]
            ab = b - a
            t = np.clip(((v - a) @ ab) / max(ab @ ab, 1e-12), 0, 1)
            seg_d[:, s] = np.linalg.norm(v - (a + t[:, None] * ab), axis=1)
        seg = np.argmin(seg_d, 1)
        dist = seg_d[np.arange(len(v)), seg]
        axis = P[1] - P[0]
        t_root = ((v - P[0]) @ axis) / max(axis @ axis, 1e-12)
        w = _smooth(-0.1, 0.35, t_root) * (1 - _smooth(radius * 0.7, radius, dist))
        per_chain.append((seg, dist, w))
        closer = dist < best_d[candidates]
        best_d[candidates] = np.where(closer, dist, best_d[candidates])
        owner[candidates] = np.where(closer, ci, owner[candidates])
    for ci, (seg, dist, w) in enumerate(per_chain):
        mine = (owner[candidates] == ci) & (w > 0.02)
        out.append((candidates[mine], np.minimum(seg[mine], len(chains_pos[ci]) - 1), w[mine]))
    return out
