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
    for b, (start, k) in zip(bindings, _curve_counts(bindings)):
        if b.get("typeID") != 4 or b.get("attribute") not in (1, 2, 3, 4):
            continue
        fs = [curve(start + i) for i in range(k)]
        tracks[(int(b["path"]) & 0xFFFFFFFF, int(b["attribute"]))] = (lambda fs: lambda T: np.stack([f(T) for f in fs], -1))(fs)

    start_t = float(muscle.get("m_StartTime", 0) or 0)
    stop_t = float(muscle.get("m_StopTime", 0) or 0)
    nm = name or tt.get("m_Name", "clip")
    return Clip(nm, max(0.0, stop_t - start_t), float(tt.get("m_SampleRate", 30) or 30),
                nm.endswith("_loop"), tracks)


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
ROOT_BONE = "Position"          # carries the chibi's movement through the scene in the game
TRANSLATING_BONES = ("Position", "Hip")


def retarget(skel: Skeleton, clip: Clip, meta: dict, ex: ExportPose, fps: float = 30.0,
             root_motion: str = "inplace", ref_lpos: dict | None = None) -> dict:
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
                              root_motion: str = "inplace") -> list[str]:
    """Decode all mini clips for the character in a converted GLB's sidecar, write anim JSONs next to it."""
    with open(meta_path, "r", encoding="utf-8") as f:
        meta = json.load(f)
    cid, costume = meta["charaId"], meta["costume"]
    prefab = gd.mini_body_prefab(cid, costume)
    if not prefab:
        raise RuntimeError("No mini body prefab found in the game data.")
    skel = skeleton_from_env(gd.load(prefab))
    names = gd.mini_clips(cid, include_general)
    if not names:
        log(f"  no mini animations found for {cid}")
        return []
    clips = []
    for n in names:
        try:
            env = gd.load(n)
            for o in env.objects:
                if o.type.name == "AnimationClip":
                    clips.append(decode_clip(o.read_typetree(), n))
                    break
        except Exception as ex:
            log(f"  skip {n.split('/')[-1]}: {ex}")
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
    out_dir = os.path.join(os.path.dirname(meta_path), "anims", os.path.splitext(meta["glb"])[0])
    os.makedirs(out_dir, exist_ok=True)
    for old in os.listdir(out_dir):
        if old.endswith(".json"):
            os.remove(os.path.join(out_dir, old))
    written = []
    for c in clips:
        data = retarget(skel, c, meta, ex, fps, root_motion, ref_lpos)
        if not data["bones"]:
            continue
        if data["maxDisplacement"] > 0.25 * height:
            log(f"  note: {data['name']} moves the hip up to {data['maxDisplacement'] / height:.0%} of the model's height")
        p = os.path.join(out_dir, data["name"] + ".json")
        with open(p, "w", encoding="utf-8") as f:
            json.dump(data, f, separators=(",", ":"))
        written.append(p)
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
    return written
