"""UmaViewer PMX export -> Roblox-ready, cartoon-shaded, skinned GLB.

Cartoon look without Roblox's own shading (Roblox has no custom shaders, so it is baked):
  * 2-tone cel shadow baked into the albedo (Uma's own *_shad_c texture is used as the shadow
    colour when UmaViewer exported it) - or flat albedo in "flat" mode
  * every vertex normal points straight up -> Roblox lighting is uniform over the model, so it
    adds no smooth light/dark gradient of its own
  * inverted-hull outline mesh (skinned to the same bones)
  * the Studio plugin turns CastShadow off
"""
from __future__ import annotations

import io
import json
import math
import os
import re
import struct
from dataclasses import dataclass, field, asdict

import numpy as np
from PIL import Image

from .pmx import Bone, Model, read_pmx

PMX_TO_METERS = 0.08  # UmaViewer divides Unity units by 0.08 when writing PMX


@dataclass
class Options:
    shade: str = "cel"              # "cel" | "flat"
    flatten_normals: bool = True    # disable Roblox shading
    outline: bool = True
    outline_width: float = 0.006    # fraction of model height
    outline_color: tuple = (41, 28, 33)
    outline_vertex_color: bool = True   # thin/skip the outline where the model's vertex colour says so (as in game)
    light_dir: tuple = (0.0, 0.85, 0.55)   # y up, z = toward the character's front
    cel_threshold: float = 0.0
    cel_softness: float = 0.03
    shadow_tint: tuple = (0.80, 0.74, 0.88)
    cel_on_face: bool = False
    max_texture: int = 1024
    prune_bones: bool = True
    outline_exclude: str = "eye,mouth,mayu,cheek,tear,alpha"
    cel_exclude: str = "eye,mouth,mayu,cheek,tear"
    # parts whose exported texture has a solid background instead of alpha: key the background out
    colorkey_parts: str = "cheek,mayu"
    port_animations: bool = True
    general_animations: bool = False
    anim_fps: float = 30.0
    root_motion: str = "inplace"     # inplace | full | none
    ear_bones: bool = True           # add the game's ear bones (UmaViewer's PMX drops them) so ears can animate
    face_variants: bool = True       # expression copies of eyes/mouth/mayu hidden in the head, swapped by animation

    @classmethod
    def from_dict(cls, d: dict) -> "Options":
        o = cls()
        for k, v in (d or {}).items():
            if hasattr(o, k):
                setattr(o, k, tuple(v) if isinstance(getattr(o, k), tuple) else v)
        return o


@dataclass
class Result:
    glb: str
    meta: str
    chara_id: int
    costume: str
    name: str
    is_mini: bool
    triangles: int
    bones: int
    meshes: int
    warnings: list = field(default_factory=list)


@dataclass
class _Prim:
    name: str
    kind: str
    pos: np.ndarray
    nrm: np.ndarray
    uv: np.ndarray
    joints: np.ndarray
    weights: np.ndarray
    faces: np.ndarray        # glTF winding
    material: int = -1
    alpha: str = "OPAQUE"
    tex_path: str | None = None
    outline_w: np.ndarray | None = None   # per-vertex outline width factor (vertex colour red), 1 = full


# ------------------------------------------------------------------------- naming
FILE_RE = re.compile(r"^(\d{4,})_(.+)$")
BODY_RE = re.compile(r"mbdy(\d+)_(\d+)")
FULLBODY_RE = re.compile(r"(?<!m)bdy(\d+)_(\d+)")


def sanitize(s: str) -> str:
    s = re.sub(r"[^\w\-]+", "_", s, flags=re.UNICODE).strip("_")
    return s or "_"


def is_character(pmx_path: str, model: Model) -> bool:
    """UmaViewer names character exports '<id>_<name>.pmx'; props/stages are '<prefab> (UmaContainerProp).pmx'."""
    stem = os.path.splitext(os.path.basename(pmx_path))[0]
    if "(UmaContainerProp)" in stem:
        return False
    names = " ".join([x.name for x in model.materials] + model.textures).lower()
    return bool(FILE_RE.match(stem)) or any(k in names for k in ("mbdy", "mchr", "bdy", "chr"))


def identify(pmx_path: str, model: Model) -> tuple[int, str, str, bool]:
    """-> (chara_id, costume, display_name, is_mini) from the file name and texture/material names."""
    stem = os.path.splitext(os.path.basename(pmx_path))[0]
    m = FILE_RE.match(stem)
    chara_id = int(m.group(1)) if m else 0
    name = m.group(2) if m else (model.name_en or model.name or stem)
    names = " ".join([x.name for x in model.materials] + model.textures)
    is_mini = ("mbdy" in names) or ("mchr" in names)
    costume = "00"
    b = BODY_RE.search(names) if is_mini else FULLBODY_RE.search(names)
    if b:
        if chara_id and int(b.group(1)) == chara_id:
            costume = b.group(2)
        else:  # generic costume, e.g. mbdy0003_00 -> g000300
            costume = "g" + b.group(1) + b.group(2)
    return chara_id, costume, name, is_mini


# ------------------------------------------------------------------------- textures
def _load_rgba(path: str) -> Image.Image | None:
    try:
        return Image.open(path).convert("RGBA")
    except Exception:
        return None


def _png_bytes(img: Image.Image) -> bytes:
    b = io.BytesIO()
    img.save(b, "PNG", optimize=True)
    return b.getvalue()


def _solid_png(rgb) -> bytes:
    return _png_bytes(Image.new("RGBA", (4, 4), (int(rgb[0]), int(rgb[1]), int(rgb[2]), 255)))


def _lit_mask(p: _Prim, w: int, h: int, L: np.ndarray, th: float, soft: float) -> np.ndarray:
    """Rasterise the primitive in UV space; per texel how lit it is (0..1). Uncovered texels -> 1."""
    mask = np.full((h, w), -1.0, np.float32)
    uv = p.uv - np.floor(p.uv)
    px = uv[:, 0] * w - 0.5
    py = uv[:, 1] * h - 0.5
    n = p.nrm
    for a, b, c in p.faces:
        ua, ub, uc = uv[a], uv[b], uv[c]
        if abs(ua[0] - ub[0]) > .5 or abs(ua[0] - uc[0]) > .5 or abs(ua[1] - ub[1]) > .5 or abs(ua[1] - uc[1]) > .5:
            continue  # straddles a wrap boundary
        ax, ay, bx, by, cx, cy = px[a], py[a], px[b], py[b], px[c], py[c]
        area = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay)
        if abs(area) < 1e-8:
            continue
        x0 = max(0, int(math.floor(min(ax, bx, cx))) - 1)
        x1 = min(w - 1, int(math.ceil(max(ax, bx, cx))) + 1)
        y0 = max(0, int(math.floor(min(ay, by, cy))) - 1)
        y1 = min(h - 1, int(math.ceil(max(ay, by, cy))) + 1)
        if x1 < x0 or y1 < y0:
            continue
        xs, ys = np.meshgrid(np.arange(x0, x1 + 1, dtype=np.float32), np.arange(y0, y1 + 1, dtype=np.float32))
        w0 = ((bx - xs) * (cy - ys) - (cx - xs) * (by - ys)) / area
        w1 = ((cx - xs) * (ay - ys) - (ax - xs) * (cy - ys)) / area
        w2 = 1.0 - w0 - w1
        eps = -0.75 / math.sqrt(abs(area))
        inside = (w0 >= eps) & (w1 >= eps) & (w2 >= eps)
        if not inside.any():
            continue
        nn = w0[..., None] * n[a] + w1[..., None] * n[b] + w2[..., None] * n[c]
        nn /= np.linalg.norm(nn, axis=-1, keepdims=True) + 1e-8
        d = nn @ L
        lit = np.clip((d - (th - soft)) / max(1e-4, 2 * soft), 0, 1)
        lit = lit * lit * (3 - 2 * lit)
        sub = mask[y0:y1 + 1, x0:x1 + 1]
        sub[inside] = np.maximum(sub[inside], lit[inside])   # mirrored UVs: lit wins
    # dilate into the gutter so bilinear filtering does not bleed at seams
    for _ in range(3):
        m = mask
        nb = np.full_like(m, -1.0)
        nb[:, 1:] = np.maximum(nb[:, 1:], m[:, :-1])
        nb[:, :-1] = np.maximum(nb[:, :-1], m[:, 1:])
        nb[1:, :] = np.maximum(nb[1:, :], m[:-1, :])
        nb[:-1, :] = np.maximum(nb[:-1, :], m[1:, :])
        mask = np.where(m < 0, nb, m)
    mask[mask < 0] = 1.0
    return mask


def _border_bg(px: np.ndarray) -> np.ndarray:
    """Most common colour on the texture border (quantised), refined to the mean of matching pixels."""
    b = np.concatenate([px[0], px[-1], px[:, 0], px[:, -1]])[:, :3]
    q = (b // 8).astype(np.int32)
    keys, counts = np.unique(q[:, 0] * 1024 + q[:, 1] * 32 + q[:, 2], return_counts=True)
    k = keys[np.argmax(counts)]
    sel = (q[:, 0] * 1024 + q[:, 1] * 32 + q[:, 2]) == k
    return b[sel].mean(0)


def colorkey_alpha(px: np.ndarray, lo: float = 10.0, hi: float = 70.0) -> np.ndarray:
    """Turn a texture with a solid background into one with real alpha.

    alpha grows with the colour distance from the background colour; colours are then
    un-blended from the background so soft edges (blush gradients, brush strokes) keep their hue.
    """
    px = px.astype(np.float32).copy()
    bg = _border_bg(px)
    rgb = px[..., :3]
    dist = np.abs(rgb - bg).max(-1)
    a = np.clip((dist - lo) / (hi - lo), 0.0, 1.0)
    a = a * a * (3 - 2 * a)
    safe = np.maximum(a, 1e-3)[..., None]
    unblended = bg + (rgb - bg) / safe
    px[..., :3] = np.where(a[..., None] > 1e-3, np.clip(unblended, 0, 255), rgb)
    px[..., 3] = np.minimum(px[..., 3], a * 255.0)
    return px


def _is_face_part(kind: str) -> bool:
    return any(k in kind for k in ("eye", "mouth", "mayu", "cheek"))


def _build_texture(p: _Prim, o: Options, L: np.ndarray, warnings: list) -> tuple[bytes, str]:
    alpha = "BLEND" if any(k in p.kind for k in ("alpha", "cheek", "tear")) else "OPAQUE"
    img = _load_rgba(p.tex_path) if p.tex_path else None
    if img is None:
        if p.tex_path:
            warnings.append(f"Texture missing for {p.name}: {p.tex_path}")
        return _solid_png((230, 230, 230)), alpha

    scale = min(1.0, o.max_texture / max(img.size))
    if scale < 1.0:
        img = img.resize((max(4, round(img.width * scale)), max(4, round(img.height * scale))), Image.LANCZOS)
    w, h = img.size
    px = np.asarray(img).astype(np.float32)

    keyparts = [s.strip() for s in o.colorkey_parts.lower().split(",") if s.strip()]
    if any(k in p.kind for k in keyparts) and (px[..., 3] >= 250).mean() > 0.98:
        # UmaViewer's texture export dropped the alpha: rebuild it from the background colour
        px = colorkey_alpha(px)
        alpha = "BLEND"
        warnings.append(f"{p.name}: no alpha in texture, background colour keyed out")

    if alpha == "OPAQUE" and _is_face_part(p.kind) and (px[..., 3] < 250).any():
        alpha = "BLEND"

    celex = [s.strip() for s in o.cel_exclude.lower().split(",") if s.strip()]
    do_cel = (o.shade == "cel" and not any(k in p.kind for k in celex)
              and (o.cel_on_face or "face" not in p.kind))
    if do_cel:
        shadow = None
        base, ext = os.path.splitext(p.tex_path)
        for cand in (base.replace("_diff", "_shad_c") + ext, base + "_shad_c" + ext):
            if cand != p.tex_path and os.path.exists(cand):
                s = _load_rgba(cand)
                if s is not None:
                    shadow = np.asarray(s.resize((w, h), Image.LANCZOS)).astype(np.float32)
                    break
        if shadow is None:
            shadow = px.copy()
            shadow[..., :3] *= np.array(o.shadow_tint, np.float32)
        lit = _lit_mask(p, w, h, L, o.cel_threshold, o.cel_softness)[..., None]
        rgb = shadow[..., :3] + (px[..., :3] - shadow[..., :3]) * lit
        px[..., :3] = rgb

    if alpha == "OPAQUE":
        px[..., 3] = 255
    out = Image.fromarray(np.clip(px + 0.5, 0, 255).astype(np.uint8), "RGBA")
    return _png_bytes(out), alpha


# ------------------------------------------------------------------------- geometry
def _smooth_normals(pos: np.ndarray, nrm: np.ndarray, q: float) -> np.ndarray:
    keys = np.round(pos / q).astype(np.int64)
    _, inv = np.unique(keys, axis=0, return_inverse=True)
    inv = inv.reshape(-1)
    acc = np.zeros((inv.max() + 1, 3), np.float64)
    np.add.at(acc, inv, nrm)
    out = acc[inv]
    ln = np.linalg.norm(out, axis=1, keepdims=True)
    return np.where(ln > 1e-8, out / np.maximum(ln, 1e-8), nrm).astype(np.float32)


def _weld_mean(pos: np.ndarray, val: np.ndarray, q: float) -> np.ndarray:
    """Average a per-vertex value over vertices sharing a position (split UV/normal seams)."""
    keys = np.round(pos / q).astype(np.int64)
    _, inv = np.unique(keys, axis=0, return_inverse=True)
    inv = inv.reshape(-1)
    acc = np.zeros(inv.max() + 1, np.float64)
    cnt = np.zeros(inv.max() + 1, np.float64)
    np.add.at(acc, inv, val)
    np.add.at(cnt, inv, 1)
    return (acc / cnt)[inv].astype(np.float32)


def _detect_forward(prims: list[_Prim]) -> float:
    eyes = [p.pos for p in prims if "eye" in p.kind] or [p.pos for p in prims if "face" in p.kind]
    if not eyes:
        return 1.0
    ez = float(np.concatenate(eyes)[:, 2].mean())
    allp = np.concatenate([p.pos for p in prims])
    top, bot = allp[:, 1].max(), allp[:, 1].min()
    head = allp[allp[:, 1] > top - (top - bot) * 0.45]
    hz = float(head[:, 2].mean()) if len(head) else 0.0
    return 1.0 if ez >= hz else -1.0


# ------------------------------------------------------------------------- GLB
class _Bin:
    def __init__(self):
        self.data = bytearray()
        self.views: list = []
        self.accessors: list = []

    def view(self, b: bytes, target=None) -> int:
        while len(self.data) % 4:
            self.data.append(0)
        v = {"buffer": 0, "byteOffset": len(self.data), "byteLength": len(b)}
        if target:
            v["target"] = target
        self.data.extend(b)
        self.views.append(v)
        return len(self.views) - 1

    def accessor(self, arr: np.ndarray, ctype: int, typ: str, target=None, minmax=False) -> int:
        a = {"bufferView": self.view(arr.tobytes(), target), "componentType": ctype, "count": int(arr.shape[0]), "type": typ}
        if minmax:
            a["min"] = [float(x) for x in arr.min(0)]
            a["max"] = [float(x) for x in arr.max(0)]
        self.accessors.append(a)
        return len(self.accessors) - 1


def _material(name: str, image: int, alpha: str) -> dict:
    m = {"name": name,
         "pbrMetallicRoughness": {"baseColorTexture": {"index": image}, "metallicFactor": 0.0, "roughnessFactor": 1.0},
         "alphaMode": alpha, "doubleSided": False, "extensions": {"KHR_materials_unlit": {}}}
    if alpha == "MASK":
        m["alphaCutoff"] = 0.5
    return m


def _write_glb(path, name, joint_names, joint_pos, joint_parent, prims, images, materials):
    b = _Bin()
    nodes = [{"name": name}]
    jbase = 1
    for i, jn in enumerate(joint_names):
        par = joint_parent[i]
        t = joint_pos[i] - (joint_pos[par] if par >= 0 else 0)
        nodes.append({"name": jn, "translation": [float(x) for x in t]})
    root_children = []
    for i, par in enumerate(joint_parent):
        if par >= 0:
            nodes[jbase + par].setdefault("children", []).append(jbase + i)
        else:
            root_children.append(jbase + i)
    if root_children:
        nodes[0]["children"] = root_children
    ibm = np.tile(np.eye(4, dtype=np.float32), (len(joint_names), 1, 1))
    ibm[:, :3, 3] = -joint_pos
    ibm_acc = b.accessor(np.ascontiguousarray(ibm.transpose(0, 2, 1)).reshape(-1, 16), 5126, "MAT4")
    skin = {"name": name + "_Skin", "joints": list(range(jbase, jbase + len(joint_names))),
            "inverseBindMatrices": ibm_acc, "skeleton": 0}

    meshes, scene_nodes = [], [0]
    for p in prims:
        attrs = {
            "POSITION": b.accessor(p.pos.astype(np.float32), 5126, "VEC3", 34962, minmax=True),
            "NORMAL": b.accessor(p.nrm.astype(np.float32), 5126, "VEC3", 34962),
            "TEXCOORD_0": b.accessor(p.uv.astype(np.float32), 5126, "VEC2", 34962),
            "JOINTS_0": b.accessor(p.joints.astype(np.uint16), 5123, "VEC4", 34962),
            "WEIGHTS_0": b.accessor(p.weights.astype(np.float32), 5126, "VEC4", 34962),
        }
        idx = b.accessor(p.faces.astype(np.uint32).reshape(-1), 5125, "SCALAR", 34963)
        meshes.append({"name": p.name, "primitives": [{"attributes": attrs, "indices": idx, "material": p.material, "mode": 4}]})
        nodes.append({"name": p.name, "mesh": len(meshes) - 1, "skin": 0})
        scene_nodes.append(len(nodes) - 1)

    imgs = [{"bufferView": b.view(png), "mimeType": "image/png", "name": f"{name}_tex{i}"} for i, png in enumerate(images)]
    while len(b.data) % 4:
        b.data.append(0)
    gltf = {
        "asset": {"version": "2.0", "generator": "Uma2Roblox (UmaViewer PMX bridge)"},
        "extensionsUsed": ["KHR_materials_unlit"],
        "scene": 0,
        "scenes": [{"name": name, "nodes": scene_nodes}],
        "nodes": nodes, "meshes": meshes, "skins": [skin], "materials": materials,
        "images": imgs, "textures": [{"source": i, "sampler": 0} for i in range(len(imgs))],
        "samplers": [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}],
        "accessors": b.accessors, "bufferViews": b.views, "buffers": [{"byteLength": len(b.data)}],
    }
    js = json.dumps(gltf, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    js += b" " * ((4 - len(js) % 4) % 4)
    total = 12 + 8 + len(js) + 8 + len(b.data)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(js), 0x4E4F534A) + js)
        f.write(struct.pack("<II", len(b.data), 0x004E4942) + bytes(b.data))


# ------------------------------------------------------------------------- main entry
def _inject_ears(model: Model, pos: np.ndarray, joints: np.ndarray, weights: np.ndarray, faces: np.ndarray,
                 ear: dict, head: int, warnings: list) -> int:
    """Add the game's ear bones (dropped by UmaViewer's PMX export) and skin the ear vertices to them."""
    from . import rig
    to_g = np.array([-1, 1, 1], np.float64)              # Unity -> glTF (before the facing flip)
    flip = np.array([1, 1, -1], np.float64)
    names = [(b.name_en or b.name) for b in model.bones]
    if any(n.lower().startswith("ear") for n in names):
        return 0                                         # this PMX already has ear bones
    gpos = {n: model.bones[i].position * flip * PMX_TO_METERS for i, n in enumerate(names)}
    pairs = [(np.array(u) * to_g, gpos[n]) for n, u in ear["common"].items() if n in gpos]
    if len(pairs) < 2:
        warnings.append("Ear bones: too few common bones to place them; ears stay fixed to the head.")
        return 0
    a = np.array([p[0] for p in pairs]); b = np.array([p[1] for p in pairs])
    ca, cb = a.mean(0), b.mean(0)
    k = float(((a - ca) * (b - cb)).sum() / max(((a - ca) ** 2).sum(), 1e-12))
    place = {e["name"]: k * (np.array(e["unity"]) * to_g - ca) + cb for e in ear["bones"]}

    index = {n: i for i, n in enumerate(names)}
    for e in ear["bones"]:
        parent = index.get(e["parent"], head)
        g = place[e["name"]]
        model.bones.append(Bone(e["name"], e["name"], (g * flip / PMX_TO_METERS).astype(np.float32), parent))
        index[e["name"]] = len(model.bones) - 1

    # candidate vertices: hair materials (ears are part of the hair mesh) that currently follow the head
    hair = np.zeros(len(pos), bool)
    start = 0
    for m in model.materials:
        f = faces[start // 3:(start + m.face_count) // 3]
        start += m.face_count
        if "hair" in (m.name + " " + m.name_en).lower() or (0 <= m.texture < len(model.textures)
                                                            and "hair" in model.textures[m.texture].lower()):
            hair[f.reshape(-1)] = True
    dominant = joints[np.arange(len(joints)), np.argmax(weights, 1)]
    cand = np.where((dominant == head) & (hair if hair.any() else True))[0]
    chains = ear["chains"]
    assigned = 0
    for chain, (vids, seg, w) in zip(chains, rig.ear_weights(pos, cand, [[place[n] for n in ch] for ch in chains],
                                                             gpos[names[head]])):
        bones_idx = np.array([index[n] for n in chain])
        joints[vids] = 0
        weights[vids] = 0
        joints[vids, 0] = bones_idx[seg]
        weights[vids, 0] = w
        joints[vids, 1] = head
        weights[vids, 1] = 1 - w
        assigned += len(vids)
    if assigned == 0:
        warnings.append("Ear bones added, but no ear vertices were found near them.")
    return assigned


# Mini facial expressions are cells of a texture atlas (4 columns). UmaViewer's sliders move the UV offset by
# 0.25 per column and 0.125 (eyes, mouth) or 0.25 (mayu) per row; frame k = row * 4 + column.
FACE_PARTS = {          # part -> (frames, row step)
    "Eye_L": (15, 0.125), "Eye_R": (15, 0.125), "Mouth": (19, 0.125), "Mayu_L": (9, 0.25), "Mayu_R": (9, 0.25),
}


# sprite shown at rest (no animation): the mouth's second sprite (small smile), first sprite elsewhere
FACE_DEFAULT = {"Mouth": 1}


def face_bone_name(part: str, k: int) -> str:
    return f"Face_{part}_{k:02d}"


def _face_part_of(kind: str):
    if "mouth" in kind:
        return "Mouth"
    if "mayu" in kind:
        return "Mayu"
    if "eye" in kind:
        return "Eye"
    return None


def _build_face_variants(prims, bone_pos, model, head, warnings):
    """Replace each face part by one mesh holding every expression variant. Variant k is a copy with its UVs
    shifted to atlas cell k and skinned to its own bone Face_<part>_<k> (child of Head).

    Swapping is a pure rotation (scale-proof: Roblox scales animation translations with the model, never
    rotations). Each bone sits halfway between the part on the face (F) and a point inside the head (C) at the
    same height; a 180 degree turn about the vertical axis through that pivot maps F onto C and back. The default
    variant rests on the face, the others rest turned inside the head; animation turns them (Constant keys).

    The axis is exactly vertical so the flattened (straight up) normals stay up after a turn - a tilted axis
    tilted them and the shown expression lost the model's flat lighting.

    Only the island in the first atlas cell is an expression sprite. Other islands (the mouth has an overlay
    quad pointing at an empty corner of its atlas) are dropped: shifted by the cell offset they wrap onto
    another sprite and two expressions draw on top of each other."""
    face_src = [p for p in prims if _face_part_of(p.kind)]
    if not face_src:
        return prims, bone_pos, {}
    face_mesh = [p for p in prims if "face" in p.kind and not _face_part_of(p.kind)]
    ref = np.concatenate([p.pos for p in face_mesh]) if face_mesh else np.concatenate([p.pos for p in face_src])
    lo, hi = ref.min(0), ref.max(0)
    centre = (lo + hi) / 2
    head_w = float(hi[0] - lo[0])
    # the mini face mesh is the whole head skin; a front plate only (some exports) is far shallower than wide
    whole_head = (hi[2] - lo[2]) > 0.5 * head_w

    def hide_depth(cen):
        """z of the head's middle at this part's height (the part is hidden there, well inside the skin)."""
        if not whole_head:
            return cen[2] - 0.5 * head_w
        band = np.abs(ref[:, 1] - cen[1]) < 0.06 * (hi[1] - lo[1])
        zs = ref[band, 2] if band.sum() >= 8 else ref[:, 2]
        return float(min((zs.min() + zs.max()) / 2, cen[2] - 0.05 * head_w))

    def first_cell(p, f, part):
        """Faces of the islands whose UVs lie in atlas cell 0 (the expression sprite itself)."""
        rstep = FACE_PARTS.get(part, (0, 0.125))[1] if part != "Eye" else 0.125
        tuv = p.uv[f].mean(1)
        return f[(tuv[:, 0] < 0.25) & (tuv[:, 1] < rstep)]
    groups: dict[str, list] = {}
    for p in face_src:
        part = _face_part_of(p.kind)
        cell0 = first_cell(p, p.faces, part if part != "Mayu" else "Mayu_L")
        if 0 < len(cell0) < len(p.faces):   # overlay islands outside the first cell: dropped (see above)
            p = _Prim(**{**p.__dict__, "faces": cell0})
        if part == "Eye":   # one mesh, both eyes: split by side (character faces +Z, its left is +X)
            vside = p.pos[:, 0] >= centre[0]
            for side, name in ((True, "Eye_L"), (False, "Eye_R")):
                keep = vside[p.faces].all(1) if side else (~vside[p.faces]).all(1)
                if keep.any():
                    groups.setdefault(name, []).append((p, p.faces[keep]))
        elif part == "Mayu":
            nm = p.kind.replace(" ", "_")
            if "_l" in nm or nm.endswith("l"):
                side = "Mayu_L"
            elif "_r" in nm or nm.endswith("r"):
                side = "Mayu_R"
            else:
                side = "Mayu_L" if p.pos[:, 0].mean() >= centre[0] else "Mayu_R"
            groups.setdefault(side, []).append((p, p.faces))
        else:
            groups.setdefault("Mouth", []).append((p, p.faces))

    out = [p for p in prims if p not in face_src]
    new_bones, face_meta = [], {}
    for part, items in groups.items():
        frames, rstep = FACE_PARTS[part]
        default = min(FACE_DEFAULT.get(part, 0), frames - 1)
        mat = items[0][0].material
        pos_l, nrm_l, uv_l, j_l, w_l, f_l = [], [], [], [], [], []
        base_v = 0
        part_pos = np.concatenate([p.pos[np.unique(f)] for p, f in items])
        cen = part_pos.mean(0)
        inside = cen.copy()                    # straight back, same height and side: inside the head
        inside[2] = hide_depth(cen)
        pivot = (cen + inside) / 2
        axis = np.array([0.0, 1.0, 0.0])       # vertical: F-C is horizontal, and up normals stay up
        R180 = 2 * np.outer(axis, axis) - np.eye(3)   # rotation by 180 degrees about `axis`
        bone_ids = []
        for k in range(frames):
            bi = len(bone_pos) + len(new_bones)
            new_bones.append((face_bone_name(part, k), pivot))
            bone_ids.append(bi)
            du, dv = 0.25 * (k % 4), rstep * (k // 4)
            for p, f in items:
                used, inv = np.unique(f.reshape(-1), return_inverse=True)
                if k == default:
                    pos, nrm = p.pos[used], p.nrm[used]
                else:   # hidden at rest: turned 180 degrees about the pivot, into the head
                    pos = (p.pos[used] - pivot) @ R180.T + pivot
                    nrm = p.nrm[used] @ R180.T
                pos_l.append(pos.astype(np.float32)); nrm_l.append(nrm.astype(np.float32))
                uv_l.append(p.uv[used] + np.array([du, dv], np.float32))   # glTF v points down: +row step
                jj = np.zeros((len(used), 4), np.int64); jj[:, 0] = bi
                ww = np.zeros((len(used), 4), np.float32); ww[:, 0] = 1
                j_l.append(jj); w_l.append(ww)
                f_l.append(inv.reshape(-1, 3) + base_v)
                base_v += len(used)
        np_ = _Prim(name=f"Face_{part}", kind=f"face_{part.lower()}", pos=np.concatenate(pos_l), nrm=np.concatenate(nrm_l),
                    uv=np.concatenate(uv_l), joints=np.concatenate(j_l), weights=np.concatenate(w_l),
                    faces=np.concatenate(f_l).astype(np.int32), material=mat, alpha=items[0][0].alpha)
        out.append(np_)
        face_meta[part] = {"bones": [face_bone_name(part, k) for k in range(frames)], "frames": frames,
                           "rowStep": rstep, "default": default, "pivot": [float(x) for x in pivot], "axis": [float(x) for x in axis],
                           "inside": [float(x) for x in inside]}
    for name, p in new_bones:
        model.bones.append(Bone(name, name, np.zeros(3, np.float32), head))
    if new_bones:
        bone_pos = np.vstack([bone_pos, np.array([p for _, p in new_bones], np.float32)])
    return out, bone_pos, face_meta


def convert(pmx_path: str, out_dir: str, opt: Options | None = None, log=print, ear_rig: dict | None = None) -> Result:
    o = opt or Options()
    model = read_pmx(pmx_path)
    warnings = list(model.warnings)
    chara_id, costume, name, is_mini = identify(pmx_path, model)
    if not is_mini:
        warnings.append("This looks like a full-size model, not a mini (chibi). Converting anyway.")
    pmx_dir = os.path.dirname(os.path.abspath(pmx_path))

    # PMX (left-handed, x12.5, rotated 180) -> glTF metres, right-handed: negate z, flip winding
    flip = np.array([1, 1, -1], np.float32)
    pos = model.positions * flip * PMX_TO_METERS
    nrm = model.normals * flip
    nrm /= np.linalg.norm(nrm, axis=1, keepdims=True) + 1e-8
    faces = model.faces[:, [0, 2, 1]]
    bone_pos = (np.array([b.position for b in model.bones], np.float32).reshape(-1, 3)) * flip * PMX_TO_METERS
    nb = len(model.bones)
    if nb == 0:
        raise ValueError("PMX has no bones")

    # vertices whose bone is -1 (UmaViewer's MeshRenderer parts): attach to Head
    head = next((i for i, b in enumerate(model.bones) if b.name_en == "Head" or b.name == "頭"), 0)
    joints = model.joints.copy()
    weights = model.weights.copy()
    bad = (joints < 0) | (joints >= nb)
    weights[bad] = 0
    joints[bad] = 0
    s = weights.sum(1)
    none = s <= 1e-6
    joints[none, 0] = head
    weights[none] = (1, 0, 0, 0)
    weights /= weights.sum(1, keepdims=True)
    if ear_rig:
        n_ear = _inject_ears(model, pos, joints, weights, model.faces, ear_rig, head, warnings)
        if n_ear:
            log(f"  ears: {len(ear_rig['bones'])} bone(s) added from the game rig, {n_ear} vertices skinned")
        bone_pos = (np.array([b.position for b in model.bones], np.float32).reshape(-1, 3)) * flip * PMX_TO_METERS
        nb = len(model.bones)

    # ---- split into one primitive per material (Roblox: one texture per MeshPart)
    prims: list[_Prim] = []
    start = 0
    for mi, m in enumerate(model.materials):
        nf = m.face_count // 3
        f = faces[start // 3:start // 3 + nf]
        start += m.face_count
        if nf == 0:
            continue
        used, inv = np.unique(f.reshape(-1), return_inverse=True)
        tex_rel = model.textures[m.texture] if 0 <= m.texture < len(model.textures) else None
        tex_path = os.path.normpath(os.path.join(pmx_dir, tex_rel.replace("\\", "/"))) if tex_rel else None
        kind = (m.name + " " + m.name_en + " " + (os.path.basename(tex_rel) if tex_rel else "")).lower()
        uv = model.uvs[used].copy()
        # eye atlas: UmaViewer writes the 1st column as eye0.png and the whole atlas as eye0_all.png
        if tex_path and tex_path.lower().endswith("eye0.png"):
            full = tex_path[:-4] + "_all.png"
            if os.path.exists(full) and (uv[:, 0].max() - uv[:, 0].min()) <= 0.3:
                tex_path = full
        prims.append(_Prim(
            name=sanitize(m.name_en or m.name or f"mat{mi}"), kind=kind,
            pos=pos[used], nrm=nrm[used], uv=uv,
            joints=joints[used], weights=weights[used],
            faces=inv.reshape(-1, 3).astype(np.int32), tex_path=tex_path,
            outline_w=model.colors[used, 0].copy() if model.colors is not None else None))

    if not prims:
        raise ValueError(
            f"{os.path.basename(pmx_path)} has no exportable geometry ({len(model.positions)} vertices, "
            f"{len(model.faces)} triangles, {len(model.materials)} materials). "
            "UmaViewer may have failed to read its meshes; it's probably not a character model.")

    # ---- face the model toward +Z (glTF front)
    fwd = _detect_forward(prims)
    unity_to_gltf = [-1, 1, 1]   # Unity -> PMX -> glTF is a mirror on X
    if fwd < 0:
        unity_to_gltf = [1, 1, -1]
        rot = np.array([-1, 1, -1], np.float32)
        for p in prims:
            p.pos = p.pos * rot
            p.nrm = p.nrm * rot
        bone_pos = bone_pos * rot

    allp = np.concatenate([p.pos for p in prims])
    height = float(max(1e-3, allp[:, 1].max() - allp[:, 1].min()))
    L = np.array(o.light_dir, np.float32)
    L /= np.linalg.norm(L) + 1e-8

    # ---- textures / materials
    images: list[bytes] = []
    materials: list[dict] = []
    for p in prims:
        png, alpha = _build_texture(p, o, L, warnings)
        images.append(png)
        p.alpha = alpha
        materials.append(_material(p.name, len(images) - 1, alpha))
        p.material = len(materials) - 1

    # ---- outline hull
    if o.outline:
        outex = [s.strip() for s in o.outline_exclude.lower().split(",") if s.strip()]
        elig = [p for p in prims if p.alpha == "OPAQUE" and not any(k in p.kind for k in outex)]
        if elig:
            cat_pos = np.concatenate([p.pos for p in elig])
            cat_nrm = np.concatenate([p.nrm for p in elig])
            sm = _smooth_normals(cat_pos, cat_nrm, max(1e-5, height * 1e-4))
            width = height * o.outline_width
            ow = np.concatenate([p.outline_w if (o.outline_vertex_color and p.outline_w is not None)
                                 else np.ones(len(p.pos), np.float32) for p in elig])
            ow = _weld_mean(cat_pos, np.clip(ow, 0.0, 1.0), max(1e-5, height * 1e-4))   # no cracks at UV seams
            offs, fs = 0, []
            for p in elig:
                f = p.faces + offs
                fs.append(f[(ow[f] > 0.01).any(1)][:, [0, 2, 1]])   # no hull where the whole triangle is unoutlined
                offs += len(p.pos)
            images.append(_solid_png(o.outline_color))
            materials.append(_material("Outline", len(images) - 1, "OPAQUE"))
            prims.append(_Prim(
                name="Outline", kind="outline", pos=cat_pos + sm * (width * ow[:, None]), nrm=-sm,
                uv=np.full((len(cat_pos), 2), 0.5, np.float32),
                joints=np.concatenate([p.joints for p in elig]), weights=np.concatenate([p.weights for p in elig]),
                faces=np.concatenate(fs), material=len(materials) - 1))

    face_meta = {}
    if o.face_variants and is_mini:
        prims, bone_pos, face_meta = _build_face_variants(prims, bone_pos, model, head, warnings)
        nb = len(model.bones)
        if face_meta:
            log("  face: " + ", ".join(f"{k} x{v['frames']}" for k, v in face_meta.items()) + " expression variants")

    if o.flatten_normals:
        for p in prims:
            p.nrm = np.tile(np.array([0, 1, 0], np.float32), (len(p.pos), 1))

    # ---- bones: prune unused leaves, keep ancestors of anything used
    parents = [b.parent if 0 <= b.parent < nb else -1 for b in model.bones]
    used = np.zeros(nb, bool)
    for p in prims:
        used[np.unique(p.joints[p.weights > 0])] = True
    used[head] = True
    if ear_rig:   # keep every injected ear bone so ear clips can drive the whole chain
        for i, b in enumerate(model.bones):
            if (b.name_en or b.name).lower().startswith("ear"):
                used[i] = True
    keep = np.zeros(nb, bool)
    for i in range(nb):
        if used[i] or not o.prune_bones:
            j, guard = i, 0
            while j >= 0 and not keep[j] and guard < nb:
                keep[j] = True
                j = parents[j]
                guard += 1
    # order parents before children
    order, seen = [], set()

    def visit(i, depth=0):
        if i in seen or depth > nb:
            return
        if parents[i] >= 0 and keep[parents[i]]:
            visit(parents[i], depth + 1)
        if i not in seen:
            seen.add(i)
            order.append(i)

    for i in range(nb):
        if keep[i]:
            visit(i)
    remap = np.full(nb, 0, np.int64)
    for ni, oi in enumerate(order):
        remap[oi] = ni
    jnames, taken = [], set()
    for oi in order:
        b = model.bones[oi]
        base = sanitize(b.name_en if b.name_en and b.name_en.isascii() else b.name) or f"Bone{oi}"
        nm, k = base, 2
        while nm in taken:
            nm, k = f"{base}_{k}", k + 1
        taken.add(nm)
        jnames.append(nm)
    jpos = bone_pos[order]
    jpar = [int(remap[parents[oi]]) if parents[oi] >= 0 and keep[parents[oi]] else -1 for oi in order]
    for p in prims:
        p.joints = remap[p.joints].astype(np.uint16)
        p.joints[p.weights <= 0] = 0

    # ---- write
    os.makedirs(out_dir, exist_ok=True)
    base = f"Uma_{chara_id}_{costume}_{sanitize(name)}"
    glb = os.path.join(out_dir, base + ".glb")
    _write_glb(glb, base, jnames, jpos, jpar, prims, images, materials)
    tris = int(sum(len(p.faces) for p in prims))
    for p in prims:
        if len(p.faces) > 20000:
            warnings.append(f"{p.name}: {len(p.faces)} triangles (Roblox limit is 20k per MeshPart).")
    meta_path = os.path.join(out_dir, base + ".json")
    meta = {"tool": "Uma2Roblox", "charaId": chara_id, "costume": costume, "name": name, "isMini": is_mini,
            "source": os.path.basename(pmx_path), "glb": os.path.basename(glb), "heightMeters": height,
            "bones": len(order), "meshes": len(prims), "triangles": tris, "options": asdict(o), "warnings": warnings,
            "unityToGltf": unity_to_gltf,
            "face": face_meta,
            "skeleton": [{"name": jnames[i],
                          "source": model.bones[oi].name_en if model.bones[oi].name_en else model.bones[oi].name,
                          "parent": jpar[i], "world": [float(x) for x in jpos[i]]} for i, oi in enumerate(order)]}
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)
    for w in warnings:
        log("  warning: " + w)
    return Result(glb, meta_path, chara_id, costume, name, is_mini, tris, len(order), len(prims), warnings)
