"""Mini (chibi) animation porting: game AnimationClip -> retargeted data for the Roblox plugin.

Pipeline
  1. skeleton  : Transform hierarchy + rest pose from the character's mini body prefab
  2. decode    : Mecanim clip (streamed / dense / constant curves + generic bindings, paths are CRC32)
  3. FK        : world rotation/position of every bone per sample, in Unity space
  4. bind pose : find which pose the PMX was exported in (rest pose or a frame of a clip) by
                 matching FK bone positions against the PMX bone positions
  5. retarget  : per bone world *delta* rotation D(t) = W(t) * W_export^-1 and world position,
                 converted to the GLB's axes. The Studio plugin turns this into Bone Transforms.
"""
from __future__ import annotations

import json
import math
import os
import struct
import zlib
from dataclasses import dataclass, field

import numpy as np


# ------------------------------------------------------------------------- math
def quat_to_mat(q: np.ndarray) -> np.ndarray:
    """(...,4) xyzw -> (...,3,3)"""
    q = q / (np.linalg.norm(q, axis=-1, keepdims=True) + 1e-12)
    x, y, z, w = q[..., 0], q[..., 1], q[..., 2], q[..., 3]
    m = np.empty(q.shape[:-1] + (3, 3), np.float64)
    m[..., 0, 0] = 1 - 2 * (y * y + z * z); m[..., 0, 1] = 2 * (x * y - z * w); m[..., 0, 2] = 2 * (x * z + y * w)
    m[..., 1, 0] = 2 * (x * y + z * w); m[..., 1, 1] = 1 - 2 * (x * x + z * z); m[..., 1, 2] = 2 * (y * z - x * w)
    m[..., 2, 0] = 2 * (x * z - y * w); m[..., 2, 1] = 2 * (y * z + x * w); m[..., 2, 2] = 1 - 2 * (x * x + y * y)
    return m


def mat_to_quat(m: np.ndarray) -> np.ndarray:
    """(...,3,3) -> (...,4) xyzw"""
    m = np.asarray(m, np.float64)
    out = np.empty(m.shape[:-2] + (4,), np.float64)
    tr = m[..., 0, 0] + m[..., 1, 1] + m[..., 2, 2]
    flat_m, flat_o, flat_t = m.reshape(-1, 3, 3), out.reshape(-1, 4), tr.reshape(-1)
    for i in range(flat_m.shape[0]):
        a, t = flat_m[i], flat_t[i]
        if t > 0:
            s = math.sqrt(t + 1.0) * 2
            q = [(a[2, 1] - a[1, 2]) / s, (a[0, 2] - a[2, 0]) / s, (a[1, 0] - a[0, 1]) / s, 0.25 * s]
        elif a[0, 0] > a[1, 1] and a[0, 0] > a[2, 2]:
            s = math.sqrt(1.0 + a[0, 0] - a[1, 1] - a[2, 2]) * 2
            q = [0.25 * s, (a[0, 1] + a[1, 0]) / s, (a[0, 2] + a[2, 0]) / s, (a[2, 1] - a[1, 2]) / s]
        elif a[1, 1] > a[2, 2]:
            s = math.sqrt(1.0 + a[1, 1] - a[0, 0] - a[2, 2]) * 2
            q = [(a[0, 1] + a[1, 0]) / s, 0.25 * s, (a[1, 2] + a[2, 1]) / s, (a[0, 2] - a[2, 0]) / s]
        else:
            s = math.sqrt(1.0 + a[2, 2] - a[0, 0] - a[1, 1]) * 2
            q = [(a[0, 2] + a[2, 0]) / s, (a[1, 2] + a[2, 1]) / s, 0.25 * s, (a[1, 0] - a[0, 1]) / s]
        flat_o[i] = q
    return out


def euler_to_quat(e_deg: np.ndarray) -> np.ndarray:
    """Unity Quaternion.Euler (applied Z, then X, then Y)."""
    x, y, z = [np.radians(e_deg[..., i]) / 2 for i in range(3)]
    qx = np.stack([np.sin(x), 0 * x, 0 * x, np.cos(x)], -1)
    qy = np.stack([0 * y, np.sin(y), 0 * y, np.cos(y)], -1)
    qz = np.stack([0 * z, 0 * z, np.sin(z), np.cos(z)], -1)
    return qmul(qmul(qy, qx), qz)


def qmul(a, b):
    ax, ay, az, aw = [a[..., i] for i in range(4)]
    bx, by, bz, bw = [b[..., i] for i in range(4)]
    return np.stack([aw * bx + ax * bw + ay * bz - az * by,
                     aw * by - ax * bz + ay * bw + az * bx,
                     aw * bz + ax * by - ay * bx + az * bw,
                     aw * bw - ax * bx - ay * by - az * bz], -1)


def path_hash(path: str) -> int:
    return zlib.crc32(path.encode("utf-8")) & 0xFFFFFFFF


# ------------------------------------------------------------------------- skeleton
@dataclass
class Skeleton:
    names: list
    parents: list            # index or -1
    paths: list              # "Position/Hip/..." relative to the animator root
    rest_pos: np.ndarray     # (B,3) local
    rest_rot: np.ndarray     # (B,4) local xyzw
    rest_scl: np.ndarray = None  # (B,3) local scale
    by_hash: dict = field(default_factory=dict)

    def __post_init__(self):
        if self.rest_scl is None:
            self.rest_scl = np.ones((len(self.names), 3))
        self.by_hash = {path_hash(p): i for i, p in enumerate(self.paths)}
        self.by_name = {}
        for i, n in enumerate(self.names):
            self.by_name.setdefault(n, i)


def skeleton_from_env(env) -> Skeleton:
    """Transform hierarchy of the first root GameObject in a UnityPy environment."""
    objs = {o.path_id: o for o in env.objects}
    trs = {}
    for o in env.objects:
        if o.type.name == "Transform":
            trs[o.path_id] = o.read_typetree()
    if not trs:
        raise ValueError("No Transforms in prefab bundle")

    def go_name(tt):
        g = objs.get(tt["m_GameObject"]["m_PathID"])
        return g.read_typetree()["m_Name"] if g else "?"

    roots = [pid for pid, tt in trs.items() if tt["m_Father"]["m_PathID"] == 0]
    root = max(roots, key=lambda pid: len(trs[pid]["m_Children"]))
    names, parents, paths, rp, rr, rs = [], [], [], [], [], []

    def walk(pid, parent, path):
        tt = trs[pid]
        idx = len(names)
        names.append(go_name(tt)); parents.append(parent); paths.append(path)
        p, q = tt["m_LocalPosition"], tt["m_LocalRotation"]
        sc = tt.get("m_LocalScale") or {"x": 1, "y": 1, "z": 1}
        rp.append([p["x"], p["y"], p["z"]]); rr.append([q["x"], q["y"], q["z"], q["w"]]); rs.append([sc["x"], sc["y"], sc["z"]])
        for c in tt["m_Children"]:
            cid = c["m_PathID"]
            if cid in trs:
                cname = go_name(trs[cid])
                walk(cid, idx, cname if not path else f"{path}/{cname}")

    walk(root, -1, "")
    return Skeleton(names, parents, paths, np.array(rp, np.float64), np.array(rr, np.float64), np.array(rs, np.float64))


# ------------------------------------------------------------------------- clip decoding
@dataclass
class Clip:
    name: str
    length: float
    sample_rate: float
    loop: bool
    # curve evaluators per (path_hash, attribute) -> callable(times) -> (T, k)
    tracks: dict
    # non-Transform channels (material properties, script fields, ...): dicts with path, attribute,
    # typeID, customType and f (callable(times) -> values)
    other: list = field(default_factory=list)


def _get(d, *keys, default=None):
    for k in keys:
        if isinstance(d, dict) and k in d:
            d = d[k]
        else:
            return default
    return d


def _curve_counts(bindings):
    spans, start = [], 0
    for b in bindings:
        if b.get("typeID") == 4:
            k = 4 if b.get("attribute") == 2 else 3 if b.get("attribute") in (1, 3, 4) else 1
        else:
            k = 1
        spans.append((start, k))
        start += k
    return spans


def decode_clip(tt: dict, name: str | None = None) -> Clip:
    muscle = tt["m_MuscleClip"]
    clip = _get(muscle, "m_Clip", "data") or _get(muscle, "m_Clip") or {}
    streamed = clip.get("m_StreamedClip", {})
    dense = clip.get("m_DenseClip", {})
    const = clip.get("m_ConstantClip", {})
    s_count = int(streamed.get("curveCount", 0))
    d_count = int(dense.get("m_CurveCount", 0))

    # --- streamed: frames of (time, keys[(curve, coeff[4])]); value = ((a*dt + b)*dt + c)*dt + d
    keys: dict[int, list] = {}
    raw = streamed.get("data") or []
    if len(raw):
        buf = np.asarray(raw, np.uint32).tobytes()
        o = 0
        while o + 8 <= len(buf):
            t, n = struct.unpack_from("<fI", buf, o)
            o += 8
            for _ in range(n):
                ci, a, b, c, d = struct.unpack_from("<I4f", buf, o)
                o += 20
                if math.isfinite(t) and abs(t) < 1e7:
                    keys.setdefault(ci, []).append((t, a, b, c, d))

    def streamed_eval(ci):
        ks = sorted(keys.get(ci, []))
        if not ks:
            return lambda T: np.zeros_like(T)
        kt = np.array([k[0] for k in ks])
        co = np.array([k[1:] for k in ks])

        def f(T):
            i = np.clip(np.searchsorted(kt, T, side="right") - 1, 0, len(kt) - 1)
            dt = np.maximum(T - kt[i], 0)
            a, b, c, d = co[i, 0], co[i, 1], co[i, 2], co[i, 3]
            return ((a * dt + b) * dt + c) * dt + d
        return f

    # --- dense: sampled frames, linear interpolation
    samples = np.asarray(dense.get("m_SampleArray") or [], np.float64)
    frames = int(dense.get("m_FrameCount", 0))
    dense_rate = float(dense.get("m_SampleRate", 30) or 30)
    begin = float(dense.get("m_BeginTime", 0))
    if frames and d_count:
        samples = samples[:frames * d_count].reshape(frames, d_count)

    def dense_eval(j):
        def f(T):
            x = np.clip((T - begin) * dense_rate, 0, max(0, frames - 1))
            i0 = np.floor(x).astype(int)
            i1 = np.minimum(i0 + 1, frames - 1)
            w = x - i0
            return samples[i0, j] * (1 - w) + samples[i1, j] * w
        return f

    consts = np.asarray(const.get("data") or [], np.float64)

    def curve(ci):
        if ci < s_count:
            return streamed_eval(ci)
        if ci < s_count + d_count:
            return dense_eval(ci - s_count)
        j = ci - s_count - d_count
        v = consts[j] if j < len(consts) else 0.0
        return lambda T: np.full_like(T, v)

    bindings = _get(tt, "m_ClipBindingConstant", "genericBindings") or []
    tracks = {}
    other = []
    for b, (start, k) in zip(bindings, _curve_counts(bindings)):
        if b.get("typeID") != 4 or b.get("attribute") not in (1, 2, 3, 4):
            if not b.get("isPPtrCurve"):
                other.append({"path": int(b.get("path", 0)) & 0xFFFFFFFF, "attribute": int(b.get("attribute", 0)) & 0xFFFFFFFF,
                              "typeID": int(b.get("typeID", 0)), "customType": int(b.get("customType", 0)),
                              "f": curve(start)})
            continue
        fs = [curve(start + i) for i in range(k)]
        tracks[(int(b["path"]) & 0xFFFFFFFF, int(b["attribute"]))] = (lambda fs: lambda T: np.stack([f(T) for f in fs], -1))(fs)

    start_t = float(muscle.get("m_StartTime", 0) or 0)
    stop_t = float(muscle.get("m_StopTime", 0) or 0)
    nm = name or tt.get("m_Name", "clip")
    return Clip(nm, max(0.0, stop_t - start_t), float(tt.get("m_SampleRate", 30) or 30),
                nm.endswith("_loop"), tracks, other)


# ------------------------------------------------------------------------- FK
@dataclass
class Pose:
    O: np.ndarray        # (T,B,3,3) world orientation (scale removed)
    L: np.ndarray        # (T,B,3,3) world linear part (rotation * scale)
    X: np.ndarray        # (T,B,3)   world position
    lpos: np.ndarray     # (T,B,3)   local position
    lrot: np.ndarray     # (T,B,4)   local rotation
    lscl: np.ndarray     # (T,B,3)   local scale
    animated: np.ndarray     # (B,) bone has any curve
    pos_animated: np.ndarray  # (B,) bone has a position curve


def fk(skel: Skeleton, clip: Clip | None, times: np.ndarray, hold: dict | None = None) -> Pose:
    """World transforms in Unity space, relative to the animator root (scale included).
    hold: {bone index: (pos, rot, scl)} keeps those bones' local transform fixed, ignoring their curves."""
    hold = hold or {}
    T, B = len(times), len(skel.names)
    lrot = np.broadcast_to(skel.rest_rot, (T, B, 4)).copy()
    lpos = np.broadcast_to(skel.rest_pos, (T, B, 3)).copy()
    lscl = np.broadcast_to(skel.rest_scl, (T, B, 3)).copy()
    animated = np.zeros(B, bool)
    pos_animated = np.zeros(B, bool)
    if clip:
        for (h, attr), f in clip.tracks.items():
            bi = skel.by_hash.get(h)
            if bi is None or bi in hold:
                continue
            v = f(times)
            if attr == 2:
                lrot[:, bi] = v
            elif attr == 4:
                lrot[:, bi] = euler_to_quat(v)
            elif attr == 1:
                lpos[:, bi] = v
                pos_animated[bi] = True
            elif attr == 3:
                lscl[:, bi] = v
            animated[bi] = True
    for bi, (hp, hr, hs) in hold.items():
        lpos[:, bi], lrot[:, bi], lscl[:, bi] = hp, hr, hs
    local_lin = quat_to_mat(lrot) * lscl[:, :, None, :]       # R * diag(s)
    L = np.zeros((T, B, 3, 3))
    X = np.zeros((T, B, 3))
    for b in range(B):
        p = skel.parents[b]
        if p < 0:
            L[:, b] = np.eye(3)        # animator root stays at the origin
            X[:, b] = 0
        else:
            L[:, b] = L[:, p] @ local_lin[:, b]
            X[:, b] = X[:, p] + np.einsum("tij,tj->ti", L[:, p], lpos[:, b])
    O = L / (np.linalg.norm(L, axis=-2, keepdims=True) + 1e-12)   # normalise columns
    return Pose(O, L, X, lpos, lrot, lscl, animated, pos_animated)


# ------------------------------------------------------------------------- export-pose matching
def _axis(meta) -> np.ndarray:
    return np.diag(np.array(meta.get("unityToGltf", [-1, 1, 1]), np.float64))


@dataclass
class ExportPose:
    O: np.ndarray        # (B,3,3) world orientation at export, glTF axes
    L: np.ndarray        # (B,3,3) world linear part at export, Unity axes
    lpos: np.ndarray     # (B,3) local positions at export
    lrot: np.ndarray     # (B,4)
    lscl: np.ndarray     # (B,3)
    k: float             # skeleton units -> GLB metres
    desc: str
    error: float         # rms bone position error (metres, after scale fit)


def match_export_pose(skel: Skeleton, meta: dict, clips: list[Clip]) -> ExportPose:
    """Which pose was the PMX exported in? Compares bone positions (Hip-relative, scale-invariant)
    against the rest pose and every frame of every clip."""
    A = _axis(meta)
    bones = {b["source"]: np.array(b["world"]) for b in meta["skeleton"] if b.get("source")}
    common = [i for i, n in enumerate(skel.names) if n in bones]
    hip = skel.by_name.get("Hip")
    if len(common) < 3:
        raise ValueError("Too few bones in common between the PMX and the game skeleton.")
    target = np.array([bones[skel.names[i]] for i in common])
    target = target - bones.get("Hip", target.mean(0))

    best = None
    candidates = [(None, np.zeros(1))] + [(c, np.arange(0, max(c.length, 1e-3) + 1e-6, 1 / 30)) for c in clips]
    for c, ts in candidates:
        P = fk(skel, c, ts)
        Xg = np.einsum("ij,tbj->tbi", A, P.X)
        ref = Xg[:, hip] if hip is not None else Xg[:, common].mean(1)
        a = Xg[:, common] - ref[:, None, :]
        k = (a * target[None]).sum((1, 2)) / np.maximum((a * a).sum((1, 2)), 1e-12)
        d = a * k[:, None, None] - target[None]
        err = np.sqrt((d ** 2).sum(-1).mean(-1))
        i = int(np.argmin(err))
        if best is None or err[i] < best.error:
            best = ExportPose(A @ P.O[i] @ A, P.L[i], P.lpos[i], P.lrot[i], P.lscl[i], float(k[i]),
                              "rest pose" if c is None else f"{c.name.split('/')[-1]} @ {ts[i]:.2f}s", float(err[i]))
    return best


# ------------------------------------------------------------------------- retarget / output
def ear_clip_name(body_clip: str) -> str:
    """3d/motion/mini/<x>/body/<y>/<name>  ->  3d/motion/mini/<x>/facial/<y>/<name>_ear"""
    return body_clip.replace("/body/", "/facial/", 1) + "_ear"


def face_clip_name(body_clip: str) -> str:
    return body_clip.replace("/body/", "/facial/", 1) + "_face"


# material channels the mini face shaders animate (Unity binds material properties as "material.<prop>.<c>")
_FACE_ATTRS = {}
for _prop in ("_MainTex_ST", "_UVOffset"):
    for _c in "xyzw":
        for _fmt in ("material.{p}.{c}", "{p}.{c}"):
            _FACE_ATTRS[path_hash(_fmt.format(p=_prop, c=_c))] = (_prop, _c)

# renderer -> (part, property, x component, y component); M_Eye's shader has one offset per eye
_FACE_RENDERERS = {
    "M_Mouth": [("Mouth", "_MainTex_ST", "z", "w")],
    "M_Mayu_L": [("Mayu_L", "_MainTex_ST", "z", "w")],
    "M_Mayu_R": [("Mayu_R", "_MainTex_ST", "z", "w")],
    "M_Eye": [("Eye_R", "_UVOffset", "x", "y"), ("Eye_L", "_UVOffset", "z", "w")],
}


# The mini *_face clips drive locator transforms (Gallop.DrivenKeyAnimation): each part has a "<Part>_Ctrl"
# locator whose local x position is -(expression index) / 100. Verified on anm_min_eve_chr1002_00_res01_e_face:
# Mouth_Ctrl x=-0.16, Eye_L_Ctrl/Eye_R_Ctrl x=-0.09, Mayu_*_Ctrl 0, Cheek_Ctrl moves on z.
FACE_LOCATORS = {"Eye_L": "Eye_L_Ctrl", "Eye_R": "Eye_R_Ctrl", "Mouth": "Mouth_Ctrl",
                 "Mayu_L": "Mayu_L_Ctrl", "Mayu_R": "Mayu_R_Ctrl"}
LOCATOR_STEP = 0.01


def _drop_blips(fr: np.ndarray) -> np.ndarray:
    """Locator keys interpolate between expressions (e.g. 9 -> 3 -> 0 over two frames); a texture swap can't
    blend, so an index that lasts a single sample takes the value that follows it."""
    fr = fr.copy()
    for i in range(len(fr) - 2, 0, -1):
        if fr[i] != fr[i - 1] and fr[i] != fr[i + 1]:
            fr[i] = fr[i + 1]
    return fr


def _locator_track(clip: Clip, skel: Skeleton, locator: str):
    f = clip.tracks.get((path_hash(locator), 1))
    if f is None and locator in skel.by_name:          # locator found deeper in a prefab hierarchy
        f = clip.tracks.get((path_hash(skel.paths[skel.by_name[locator]]), 1))
    return f


def face_frames(clip: Clip, skel: Skeleton, face_meta: dict, times: np.ndarray):
    """-> ({part: frame index per sample}, diagnostics list). Frame = row * 4 + column of the atlas cell."""
    out = {}
    for part, loc in FACE_LOCATORS.items():
        if part not in face_meta:
            continue
        f = _locator_track(clip, skel, loc)
        if f is not None:
            x = np.asarray(f(times))[:, 0]
            out[part] = _drop_blips(np.clip(np.rint(-x / LOCATOR_STEP).astype(int), 0, face_meta[part]["frames"] - 1))
    if out:
        return out, []
    # fallback: material UV-offset channels (_MainTex_ST / _UVOffset)
    chans = {}
    diag = []
    for o in clip.other:
        bi = skel.by_hash.get(o["path"])
        rname = skel.names[bi] if bi is not None else None
        attr = _FACE_ATTRS.get(o["attribute"])
        v = o["f"](times)
        if rname in _FACE_RENDERERS and attr:
            chans[(rname, attr[0], attr[1])] = v
        else:
            diag.append({"renderer": rname or f"hash:{o['path']:08x}", "attribute": f"{o['attribute']:08x}",
                         "typeID": o["typeID"], "customType": o["customType"],
                         "min": float(np.min(v)), "max": float(np.max(v))})
    for rname, specs in _FACE_RENDERERS.items():
        for part, prop, cx, cy in specs:
            if part not in face_meta:
                continue
            x, y = chans.get((rname, prop, cx)), chans.get((rname, prop, cy))
            if x is None and y is None:
                continue
            x = np.zeros_like(times) if x is None else x
            y = np.zeros_like(times) if y is None else y
            rstep = face_meta[part]["rowStep"]
            col = np.mod(np.rint(x / 0.25).astype(int), 4)
            row = np.maximum(np.rint(-y / rstep).astype(int), 0)
            out[part] = np.clip(row * 4 + col, 0, face_meta[part]["frames"] - 1)
    if not out:   # nothing recognised: report the clip's transform channels too
        known = {path_hash(n): n for n in list(FACE_LOCATORS.values()) + ["Cheek_Ctrl"]}
        for (h, attr), f in clip.tracks.items():
            v = np.asarray(f(times))
            diag.append({"transform": known.get(h, f"hash:{h:08x}"), "channel": attr,
                         "min": np.round(v.min(0), 4).tolist(), "max": np.round(v.max(0), 4).tolist()})
    return out, diag


def face_tracks(frames: dict, face_meta: dict, head_rot: list | None, n: int) -> list:
    """Constant-key bone tracks that swap expressions with a 180 degree turn (no translation, so model
    scale never affects it). The default variant rests on the face and turns in when another is shown; the
    others rest inside and turn out when shown. World delta = head delta * (180 degree turn when toggled).

    Every variant of a part is keyed, not only the ones that change: clips play as separate tracks
    (_s / _loop / _e at different priorities) and a joint a track doesn't key falls through to the other
    track, which left an old expression showing on top of the new one."""
    H = np.array(head_rot if head_rot is not None else [0.0, 0.0, 0.0, 1.0] * n, np.float64).reshape(-1, 4)
    bones = []
    for part, fr in frames.items():
        meta = face_meta[part]
        default = int(meta.get("default", 0))
        a = np.array(meta["axis"], np.float64)
        Q = np.array([a[0], a[1], a[2], 0.0])          # 180 degrees about a
        turned = qmul(H, np.broadcast_to(Q, H.shape))
        for k, name in enumerate(meta["bones"]):
            toggled = (fr != default) if k == default else (fr == k)
            q = np.where(toggled[:, None], turned, H)
            for t in range(1, len(q)):                     # keep quaternion signs continuous
                if np.dot(q[t], q[t - 1]) < 0:
                    q[t] = -q[t]
            bones.append({"name": name, "rot": np.round(q, 5).reshape(-1).tolist(), "constant": True})
    return bones


# The mini *_ear clips don't rotate the ear bones either: like *_face they drive locators
# (Gallop.DrivenKeyAnimation), one per (side, ear type). A locator's local position is (-w, w, w) / 100,
# w = blend weight of that ear type. The poses are in the character's ast_chr<id>_<costume>_ear_target
# (_targetFaces[type]._faceGroupInfo[side]._trsArray: bone path + Euler offset in degrees; type 0 = neutral,
# side 0 = R, 1 = L). Locator names aren't in the bundles, so this maps their path hashes; verified against
# every *_ear_driven list (animationEarType) in the game data.
EAR_LOCATORS = {
    3276006170: (0, 1), 3708636041: (0, 2), 1478934946: (0, 3), 3973268946: (0, 4), 1384540640: (0, 5),
    2058908891: (0, 6), 1175804438: (0, 7), 2381413617: (0, 8), 622057165: (0, 9), 2450372380: (0, 10),
    1015751580: (0, 11), 199355849: (0, 12), 2908745659: (0, 13), 882861639: (0, 14), 2060500165: (0, 15),
    967528252: (0, 16),
    1585420987: (1, 1), 1076965928: (1, 2), 3306862595: (1, 3), 3971804368: (1, 4), 1391050978: (1, 5),
    3884191098: (1, 6), 1182462740: (1, 7), 1677685364: (1, 8), 3090132844: (1, 9), 2455903774: (1, 10),
    637452874: (1, 11), 193873099: (1, 12), 1129439550: (1, 13), 888196933: (1, 14), 2059343303: (1, 15),
    969205310: (1, 16),
}


def ear_targets_from_tt(tt: dict) -> list:
    """ear_target MonoBehaviour typetree -> [type][side] -> {bone name: Euler degrees (3,)}."""
    out = []
    for face in tt.get("_targetFaces") or []:
        sides = []
        for g in face.get("_faceGroupInfo") or []:
            sides.append({t["_path"].split("/")[-1]: np.array([t["_rotation"][c] for c in "xyz"], np.float64)
                          for t in g.get("_trsArray") or []})
        out.append(sides)
    return out


def ear_driven_tracks(ear: Clip, skel: Skeleton, targets: list) -> dict:
    """Locator-driven ear clip -> rotation tracks for the ear bones (local = rest * Euler(sum w_k * e_k))."""
    loc = {}
    for (h, attr), f in ear.tracks.items():
        if attr == 1 and h in EAR_LOCATORS:
            loc[EAR_LOCATORS[h]] = f
    if not loc:
        return {}
    per_bone: dict[int, list] = {}           # bone index -> [(weight fn, euler)]
    for (side, typ), f in loc.items():
        if typ >= len(targets) or side >= len(targets[typ]):
            continue
        for bone, e in targets[typ][side].items():
            bi = skel.by_name.get(bone)
            if bi is not None and np.abs(e).max() > 1e-6:
                per_bone.setdefault(bi, []).append((f, e))
    tracks = {}
    for bi, terms in per_bone.items():
        rest = skel.rest_rot[bi]

        def track(T, terms=terms, rest=rest):
            T = np.asarray(T, np.float64)
            e = np.zeros((len(T), 3))
            for f, eu in terms:
                v = np.asarray(f(T))
                w = np.clip((v[:, 1] + v[:, 2] - v[:, 0]) / 3 * 100, 0, 1)
                e += w[:, None] * eu
            return qmul(np.broadcast_to(rest, (len(T), 4)), euler_to_quat(e))
        tracks[(path_hash(skel.paths[bi]), 2)] = track
    return tracks


ROOT_BONE = "Position"          # carries the chibi's movement through the scene in the game
TRANSLATING_BONES = ("Position", "Hip")


def _family(name: str) -> str:
    for suf in ("_s", "_loop", "_e"):
        if name.endswith(suf):
            return name[: -len(suf)]
    return name


def scene_offsets(skel: Skeleton, clips: list, ex: ExportPose, ref_lpos: dict, height: float,
                  min_frac: float = 0.2) -> dict:
    """{clip name: hip baseline shift (parent-local, skeleton units)} for clips that place the character away
    from the animator root for their game scene (circle/mode clips put each chibi on its seat through the Hip).
    A clip family (<x>_s / _loop / _e, or a single clip) whose hip never comes within min_frac of the height
    (horizontally) of the baseline is moved so its first frame stands on the baseline, like the character's own
    clips. Families that start centred and step away (e.g. res01_s) are motion and are left alone. Height
    (sitting, lying) is kept."""
    hip = skel.by_name.get("Hip")
    if hip is None or skel.parents[hip] < 0:
        return {}
    par = skel.parents[hip]
    M = ex.L[par]
    Minv = np.linalg.inv(M)
    base = ref_lpos.get(hip, ex.lpos[hip])
    fams: dict[str, list] = {}
    for c in clips:
        fams.setdefault(_family(c.name), []).append(c)
    order = {"_s": 0, "": 1, "_loop": 2, "_e": 3}
    out = {}
    for fam, cs in fams.items():
        cs = sorted(cs, key=lambda c: order.get(c.name[len(fam):], 1))
        first, near = None, False
        for c in cs:
            ts = np.linspace(0, c.length, max(2, int(round(c.length * 30)) + 1)) if c.length > 0 else np.zeros(1)
            d = fk(skel, c, ts).lpos[:, hip] - base
            w = d @ M.T                                     # world at export, Unity axes
            w[:, 1] = 0
            if first is None:
                first = w[0]
            if (np.linalg.norm(w, axis=1) * ex.k).min() < min_frac * height:
                near = True
                break
        if not near and first is not None:
            shift = Minv @ first
            for c in cs:
                out[c.name] = shift
    return out


def retarget(skel: Skeleton, clip: Clip, meta: dict, ex: ExportPose, fps: float = 30.0,
             root_motion: str = "inplace", ref_lpos: dict | None = None, hip_shift=None) -> dict:
    """Per GLB bone: world delta rotation D(t) = O(t) O_export^-1 (glTF axes), and for the hip (and the
    root in "full" mode) a position delta in GLB metres in world axes of the export pose (the plugin
    rotates it with the parent). Bone lengths always come from the rig itself.

    root_motion: "inplace" (default) freezes the root bone so the rig stays where it is and keeps the
                 hip's bob/sway; "full" keeps the game's scene movement; "none" keeps no translation."""
    A = _axis(meta)
    n = max(2, int(round(clip.length * fps)) + 1)
    times = np.linspace(0, clip.length, n) if clip.length > 0 else np.zeros(1)
    hold = {}
    root_i = skel.by_name.get(ROOT_BONE)
    if root_motion != "full" and root_i is not None:
        hold[root_i] = (ex.lpos[root_i], ex.lrot[root_i], ex.lscl[root_i])
    P = fk(skel, clip, times, hold)
    ref_lpos = ref_lpos or {}
    max_disp = 0.0
    Og = np.einsum("ij,tbjk,kl->tbil", A, P.O, A)
    gltf_names = {b["source"]: b["name"] for b in meta["skeleton"] if b.get("source")}
    moving = P.animated.copy()
    for b in range(len(skel.names)):
        p = skel.parents[b]
        if p >= 0 and moving[p]:
            moving[b] = True
    out_bones = []
    for b, name in enumerate(skel.names):
        if name not in gltf_names or not moving[b]:
            continue
        D = Og[:, b] @ np.linalg.inv(ex.O[b])
        q = mat_to_quat(D)
        for t in range(1, len(q)):
            if np.dot(q[t], q[t - 1]) < 0:
                q[t] = -q[t]
        entry = {"name": gltf_names[name], "rot": np.round(q, 5).reshape(-1).tolist()}
        par = skel.parents[b]
        if (P.pos_animated[b] and par >= 0 and name in TRANSLATING_BONES and root_motion != "none"
                and b not in hold):
            ref = ref_lpos.get(b, ex.lpos[b])
            if hip_shift is not None and name == "Hip":
                ref = ref + hip_shift                                # re-centre a scene-placed clip
            dl = P.lpos[:, b] - ref                                  # parent-local, skeleton units
            dw = np.einsum("ij,tj->ti", A @ ex.L[par], dl) * ex.k   # world at export, glTF metres
            if np.abs(dw).max() > 1e-5:
                entry["dpos"] = np.round(dw, 5).reshape(-1).tolist()
                max_disp = max(max_disp, float(np.linalg.norm(dw, axis=1).max()))
        out_bones.append(entry)
    return {"name": clip.name.split("/")[-1], "path": clip.name, "fps": fps, "frames": len(times),
            "length": float(clip.length), "loop": clip.loop,
            "kind": "loop" if clip.name.endswith("_loop") else "start" if clip.name.endswith("_s")
            else "end" if clip.name.endswith("_e") else "once",
            "rootMotion": root_motion, "maxDisplacement": max_disp,
            "bones": out_bones}


def port_character_animations(gd, meta_path: str, include_general=False, fps=30.0, log=print,
                              root_motion: str = "inplace", extra_clips=None) -> list[str]:
    """Decode all mini clips for the character in a converted GLB's sidecar, write anim JSONs next to it.

    extra_clips: General clips (not tied to a character) to port onto this model too. They are remembered in
    the sidecar ("generalClips"), so re-porting the model later keeps them."""
    with open(meta_path, "r", encoding="utf-8") as f:
        meta = json.load(f)
    cid, costume = meta["charaId"], meta["costume"]
    from .rig import build_skeleton
    skel = build_skeleton(gd, cid, costume, log)          # body + head prefabs (ear bones live on the head)
    attached = []
    for n in list(meta.get("generalClips") or []) + list(extra_clips or []):
        full = gd.resolve_clip(n)
        if full is None:
            log(f"  general clip not found in game data, skipped: {n}")
        elif full not in attached:
            attached.append(full)
    names = gd.mini_clips(cid, include_general)
    if attached:
        meta["generalClips"] = attached
        names = sorted(set(names) | set(gd.with_siblings(attached)))
        log(f"  {len(attached)} General clip(s) attached to this model")
    else:
        meta.pop("generalClips", None)
    if not names:
        log(f"  no mini animations found for {cid}")
        try:
            from .physics import port_physics
            port_physics(gd, meta_path, log, skel=skel)
        except Exception as e:
            log(f"  physics skipped: {e}")
        return []
    def load_clip(n):
        for o in gd.load(n).objects:
            if o.type.name == "AnimationClip":
                return decode_clip(o.read_typetree(), n)
        return None

    from .rig import ear_targets
    targets = ear_targets(gd, cid, costume, log)
    if targets is None:
        log("  ear poses (ear_target) not found in game data; ears follow the head only")
    clips, with_ears = [], 0
    for n in names:
        try:
            c = load_clip(n)
            if c is None:
                continue
            # ear motion lives in a sibling clip: <...>/facial/<...>_ear. It drives locators that blend the
            # character's ear poses (EAR_LOCATORS); older/other clips may key the ear bones directly.
            ear_name = ear_clip_name(n)
            if ear_name in gd.entries:
                try:
                    e = load_clip(ear_name)
                    if e is not None:
                        driven = ear_driven_tracks(e, skel, targets) if targets else {}
                        c.tracks.update(driven or e.tracks)
                        c.length = max(c.length, e.length)
                        with_ears += 1 if driven or any(h in skel.by_hash for h, _ in e.tracks) else 0
                except Exception as ex:
                    log(f"  ear clip {ear_name.split('/')[-1]} skipped: {ex}")
            fc_name = face_clip_name(n)
            if fc_name in gd.entries:
                try:
                    c.face = load_clip(fc_name)
                except Exception as ex:
                    log(f"  face clip {fc_name.split('/')[-1]} skipped: {ex}")
            clips.append(c)
        except Exception as ex:
            log(f"  skip {n.split('/')[-1]}: {ex}")
    log(f"  {len(clips)} clip(s), {with_ears} with ear motion")
    ex = match_export_pose(skel, meta, clips)
    height = float(meta.get("heightMeters", 1.0)) or 1.0
    log(f"  export pose: {ex.desc} (fit error {ex.error / height:.1%} of height, scale {ex.k:.3f})")
    if ex.error / height > 0.05:
        log("  warning: export pose not recognised well; animations may look twisted. "
            "Re-export the PMX right after loading the mini, without changing the animation.")
    # hip baseline: the export pose, unless the clips put the hip somewhere implausibly far from it
    # (then the clips' own idle frame is the better baseline)
    ref_lpos = {}
    hip = skel.by_name.get("Hip")
    idle = next((c for c in clips if "idle" in c.name and c.name.endswith("_loop")), None) or \
        next((c for c in clips if c.name.endswith("_loop")), None)
    if hip is not None and idle is not None and skel.parents[hip] >= 0:
        idle0 = fk(skel, idle, np.zeros(1)).lpos[0, hip]
        off = float(np.linalg.norm(ex.L[skel.parents[hip]] @ (idle0 - ex.lpos[hip])) * ex.k)
        if off > 0.1 * height:
            ref_lpos[hip] = idle0
            log(f"  hip baseline: export pose is {off / height:.0%} of height from {idle.name.split('/')[-1]}; "
                "using that clip's first frame as the baseline")
    hip_shift = scene_offsets(skel, clips, ex, ref_lpos, height) if root_motion == "inplace" else {}
    if hip_shift:
        log(f"  root offset: {len(hip_shift)} clip(s) placed away from the rig's centre in their game scene "
            "(e.g. circle seats); re-centred like the character's own clips")
    out_dir = os.path.join(os.path.dirname(meta_path), "anims", os.path.splitext(meta["glb"])[0])
    os.makedirs(out_dir, exist_ok=True)
    for old in os.listdir(out_dir):
        if old.endswith(".json"):
            os.remove(os.path.join(out_dir, old))
    written = []
    face_meta = meta.get("face") or {}
    face_diag, face_n = {}, 0
    head_name = next((b["name"] for b in meta["skeleton"] if b.get("source") == "Head"), "Head")
    for c in clips:
        data = retarget(skel, c, meta, ex, fps, root_motion, ref_lpos, hip_shift.get(c.name))
        fc = getattr(c, "face", None)
        if face_meta:
            frames = {}
            if fc is not None:
                times = np.linspace(0, c.length, data["frames"]) if c.length > 0 else np.zeros(1)
                frames, diag = face_frames(fc, skel, face_meta, times)
                if diag:
                    face_diag[fc.name.split("/")[-1]] = diag
                if frames:
                    face_n += 1
            # parts the clip doesn't drive (many General clips have no *_face clip at all) show the default
            # expression, keyed so this track owns the face instead of an earlier track's expression
            for part, pm in face_meta.items():
                if part not in frames:
                    frames[part] = np.full(data["frames"], int(pm.get("default", 0)))
            head = next((b for b in data["bones"] if b["name"] == head_name), None)
            data["bones"] += face_tracks(frames, face_meta, head["rot"] if head else None, data["frames"])
        if not data["bones"]:
            continue
        if data["maxDisplacement"] > 0.25 * height:
            log(f"  note: {data['name']} moves the hip up to {data['maxDisplacement'] / height:.0%} of the model's height")
        p = os.path.join(out_dir, data["name"] + ".json")
        with open(p, "w", encoding="utf-8") as f:
            json.dump(data, f, separators=(",", ":"))
        written.append(p)
    if face_meta:
        log(f"  facial: {face_n} clip(s) with expression swaps")
    if face_diag:
        dp = os.path.join(out_dir, "_face_channels.json")
        with open(dp, "w", encoding="utf-8") as f:
            json.dump(face_diag, f, indent=1)
        log(f"  facial clips have channels this tool doesn't recognise yet; please send {dp}")
    meta["animations"] = [os.path.basename(p)[:-5] for p in written]
    meta["exportPose"] = {"source": ex.desc, "error": ex.error, "scale": ex.k}
    meta["rootMotion"] = root_motion
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
    kinds = {}
    for p in written:
        n = os.path.basename(p)[:-5]
        k = "loop" if n.endswith("_loop") else "start" if n.endswith("_s") else "end" if n.endswith("_e") else "once"
        kinds[k] = kinds.get(k, 0) + 1
    log(f"  {len(written)} animation(s) ported: " + ", ".join(f"{v} {k}" for k, v in sorted(kinds.items())))
    try:   # swing-bone physics, oriented by the same export pose as the animations
        from .physics import port_physics
        port_physics(gd, meta_path, log, skel=skel, ex=ex)
    except Exception as e:
        log(f"  physics skipped: {e}")
    return written
