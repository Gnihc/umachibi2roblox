"""Minimal PMX 2.0/2.1 reader (header, vertices, faces, textures, materials, bones).

Written for the files UmaViewer's "Export Model" produces, but follows the spec, so other
PMX files load too. Morphs / rigid bodies / joints are not needed and are not parsed.
"""
from __future__ import annotations

import struct
from dataclasses import dataclass, field

import numpy as np


@dataclass
class Material:
    name: str
    name_en: str
    diffuse: tuple
    texture: int          # index into Model.textures, -1 = none
    toon_texture: int
    face_count: int       # number of indices (3 per triangle)
    flags: int


@dataclass
class Bone:
    name: str
    name_en: str
    position: np.ndarray
    parent: int


@dataclass
class Model:
    name: str
    name_en: str
    comment: str
    positions: np.ndarray      # (N,3) float32, PMX space
    normals: np.ndarray        # (N,3)
    uvs: np.ndarray            # (N,2), top-left origin
    joints: np.ndarray         # (N,4) int32, -1 = none
    weights: np.ndarray        # (N,4) float32
    faces: np.ndarray          # (F,3) int32
    textures: list[str]
    materials: list[Material]
    bones: list[Bone]
    warnings: list[str] = field(default_factory=list)
    # vertex colour RGBA when the exporter wrote one (UmaViewer: additional UV #3). Uma's toon shader reads
    # red as the outline width (0 = no outline: frills, inner face, mouth), so the outline hull follows it.
    colors: np.ndarray | None = None


class _Reader:
    def __init__(self, data: bytes):
        self.d = data
        self.o = 0

    def take(self, n: int) -> bytes:
        if self.o + n > len(self.d):
            raise ValueError("Unexpected end of PMX file")
        b = self.d[self.o:self.o + n]
        self.o += n
        return b

    def unpack(self, fmt: str):
        s = struct.calcsize(fmt)
        return struct.unpack("<" + fmt, self.take(s))

    def i32(self) -> int:
        return self.unpack("i")[0]

    def f32(self) -> float:
        return self.unpack("f")[0]

    def u8(self) -> int:
        return self.unpack("B")[0]


def _index_reader(size: int, signed: bool):
    if size == 1:
        fmt = "b" if signed else "B"
    elif size == 2:
        fmt = "h" if signed else "H"
    elif size == 4:
        fmt = "i"
    else:
        raise ValueError(f"Invalid PMX index size {size}")
    return fmt


def read_pmx(path: str) -> Model:
    with open(path, "rb") as fh:
        r = _Reader(fh.read())

    if r.take(4) != b"PMX ":
        raise ValueError(f"{path} is not a PMX file")
    version = r.f32()
    if version < 2.0:
        raise ValueError(f"PMX version {version} not supported")
    gcount = r.u8()
    g = list(r.take(gcount))
    encoding = "utf-16-le" if g[0] == 0 else "utf-8"
    extra_uv = g[1]
    vsz, tsz, bsz = g[2], g[3], g[5]

    def text() -> str:
        n = r.i32()
        return r.take(n).decode(encoding, errors="replace") if n > 0 else ""

    name, name_en, comment = text(), text(), text()
    text()  # English comment

    # ---------------------------------------------------------------- vertices
    n = r.i32()
    pos = np.zeros((n, 3), np.float32)
    nrm = np.zeros((n, 3), np.float32)
    uv = np.zeros((n, 2), np.float32)
    jnt = np.full((n, 4), -1, np.int32)
    wgt = np.zeros((n, 4), np.float32)
    col = np.ones((n, 4), np.float32) if extra_uv >= 3 else None
    cfmt = struct.Struct("<4f")
    bfmt = _index_reader(bsz, True)
    bsize = struct.calcsize(bfmt)
    d = r.d
    o = r.o
    base = struct.Struct("<8f")
    for i in range(n):
        vals = base.unpack_from(d, o)
        o += 32
        pos[i] = vals[0:3]
        nrm[i] = vals[3:6]
        uv[i] = vals[6:8]
        if col is not None:
            col[i] = cfmt.unpack_from(d, o + 32)
        o += 16 * extra_uv
        t = d[o]
        o += 1
        if t == 0:  # BDEF1
            jnt[i, 0] = struct.unpack_from("<" + bfmt, d, o)[0]
            o += bsize
            wgt[i, 0] = 1.0
        elif t in (1, 3):  # BDEF2 / SDEF
            a, b = struct.unpack_from("<" + bfmt * 2, d, o)
            o += bsize * 2
            w = struct.unpack_from("<f", d, o)[0]
            o += 4
            jnt[i, 0], jnt[i, 1] = a, b
            wgt[i, 0], wgt[i, 1] = w, 1.0 - w
            if t == 3:
                o += 36  # C, R0, R1
        elif t in (2, 4):  # BDEF4 / QDEF
            jnt[i] = struct.unpack_from("<" + bfmt * 4, d, o)
            o += bsize * 4
            wgt[i] = struct.unpack_from("<4f", d, o)
            o += 16
        else:
            raise ValueError(f"Unknown skinning type {t} at vertex {i}")
        o += 4  # edge scale
    r.o = o

    # ---------------------------------------------------------------- faces
    nidx = r.i32()
    ifmt = {1: "B", 2: "H", 4: "i"}[vsz]
    faces = np.frombuffer(r.take(nidx * vsz), dtype=np.dtype("<" + ifmt)).astype(np.int32).reshape(-1, 3)

    # ---------------------------------------------------------------- textures
    textures = [text() for _ in range(r.i32())]

    # ---------------------------------------------------------------- materials
    tfmt = _index_reader(tsz, True)
    mats: list[Material] = []
    for _ in range(r.i32()):
        mname, mname_en = text(), text()
        diffuse = r.unpack("4f")
        r.unpack("3f")  # specular
        r.f32()         # specular power
        r.unpack("3f")  # ambient
        flags = r.u8()
        r.unpack("4f")  # edge colour
        r.f32()         # edge size
        tex = r.unpack(tfmt)[0]
        r.unpack(tfmt)  # sphere texture
        r.u8()          # sphere mode
        shared_toon = r.u8()
        toon = r.u8() if shared_toon else r.unpack(tfmt)[0]
        text()          # memo
        fc = r.i32()
        mats.append(Material(mname, mname_en, diffuse, tex, -1 if shared_toon else toon, fc, flags))

    # ---------------------------------------------------------------- bones
    bones: list[Bone] = []
    for _ in range(r.i32()):
        bname, bname_en = text(), text()
        bpos = np.array(r.unpack("3f"), np.float32)
        parent = r.unpack(bfmt)[0]
        r.i32()  # transform level
        flags = r.unpack("H")[0]
        if flags & 0x0001:
            r.unpack(bfmt)
        else:
            r.unpack("3f")
        if flags & (0x0100 | 0x0200):
            r.unpack(bfmt)
            r.f32()
        if flags & 0x0400:
            r.unpack("3f")
        if flags & 0x0800:
            r.unpack("6f")
        if flags & 0x2000:
            r.i32()
        if flags & 0x0020:
            r.unpack(bfmt)   # target
            r.i32()          # loops
            r.f32()          # limit angle
            for _ in range(r.i32()):
                r.unpack(bfmt)
                if r.u8():
                    r.unpack("6f")
        bones.append(Bone(bname, bname_en, bpos, parent))

    if col is not None and not col.any():   # an exporter that leaves the extra UVs empty wrote no colour
        col = None
    m = Model(name, name_en, comment, pos, nrm, uv, jnt, wgt, faces, textures, mats, bones, colors=col)
    if sum(x.face_count for x in mats) != nidx:
        m.warnings.append("Material face counts do not add up to the index count.")
    if vsz == 2 and n >= 65535:
        m.warnings.append("Model has >= 65535 vertices but 16-bit indices; it is probably a full-size model, not a mini.")
    return m
