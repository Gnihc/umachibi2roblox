"""Writes a small fake 'mini' PMX laid out exactly like UmaViewer's PMXWriter output
(UTF-16, 3 extra UVs, 2-byte vertex/bone indices, 1-byte texture/material indices,
BDEF1/2/4 weights, bone flags 0x001F) plus a Texture2D folder, for testing the converter."""
import os
import struct
import sys

import numpy as np
from PIL import Image, ImageDraw


def s(txt):
    b = txt.encode("utf-16-le")
    return struct.pack("<i", len(b)) + b


def uv_sphere(cx, cy, cz, r, seg=16, ring=10):
    v, n, uv, f = [], [], [], []
    for i in range(ring + 1):
        th = np.pi * i / ring
        for j in range(seg + 1):
            ph = 2 * np.pi * j / seg
            d = np.array([np.sin(th) * np.cos(ph), np.cos(th), np.sin(th) * np.sin(ph)])
            v.append([cx + r * d[0], cy + r * d[1], cz + r * d[2]]); n.append(d); uv.append([j / seg, i / ring])
    for i in range(ring):
        for j in range(seg):
            a = i * (seg + 1) + j; b = a + seg + 1
            f += [[a, a + 1, b], [a + 1, b + 1, b]]
    return np.array(v), np.array(n), np.array(uv), np.array(f)


def main(out_dir, facing=-1, outline_r=None):
    """outline_r: optional fn(vertex position) -> vertex colour red (outline width), written as extra UV #3."""
    os.makedirs(os.path.join(out_dir, "Texture2D"), exist_ok=True)
    T = os.path.join(out_dir, "Texture2D")
    Image.new("RGBA", (128, 128), (250, 200, 180, 200)).save(os.path.join(T, "tex_mbdy1001_00_diff.png"))
    Image.new("RGBA", (128, 128), (180, 120, 140, 255)).save(os.path.join(T, "tex_mbdy1001_00_shad_c.png"))
    Image.new("RGBA", (128, 128), (120, 70, 40, 255)).save(os.path.join(T, "tex_mchr1001_00_hair_diff.png"))
    eye = Image.new("RGBA", (256, 256), (0, 0, 0, 0)); ImageDraw.Draw(eye).ellipse((8, 8, 56, 24), fill=(60, 40, 160, 255))
    # cheek / mayu exported WITHOUT alpha: solid background like UmaViewer produces
    ck = Image.new("RGB", (64, 64), (255, 255, 255)); dk = ImageDraw.Draw(ck)
    for r in range(24, 0, -2):
        a = (24 - r) / 24
        dk.ellipse((32 - r, 32 - r // 2, 32 + r, 32 + r // 2), fill=(255, int(255 - 120 * a), int(255 - 110 * a)))
    ck.save(os.path.join(T, "tex_mchr0001_00_cheek0.png"))
    my = Image.new("RGB", (64, 64), (180, 180, 180)); ImageDraw.Draw(my).line((6, 40, 30, 28, 58, 34), fill=(70, 40, 30), width=5)
    my.save(os.path.join(T, "tex_mchr1001_00_mayu.png"))
    eye.save(os.path.join(T, "tex_mchr0001_00_eye0_all.png"))
    mo = Image.new("RGBA", (128, 256), (0, 0, 0, 0)); ImageDraw.Draw(mo).line((6, 20, 26, 22), fill=(120, 30, 40, 255), width=3)
    mo.save(os.path.join(T, "tex_mchr0001_00_mouth.png")); eye.crop((0, 0, 64, 256)).save(os.path.join(T, "tex_mchr0001_00_eye0.png"))

    # geometry in PMX units (UmaViewer: unity * 12.5, x/z negated). 'facing' = PMX z of the face.
    bv, bn, buv, bf = uv_sphere(0, 4, 0, 2.5)               # body
    hv, hn, huv, hf = uv_sphere(0, 9, 0, 3.2)               # head (hair material)
    # two eyes (one mesh, like the mini M_Eye), each a quad mapped to the first atlas cell
    ev = np.array([[-2, 9.5, 3.15 * facing], [-0.5, 9.5, 3.15 * facing], [-2, 8.5, 3.15 * facing], [-0.5, 8.5, 3.15 * facing],
                   [0.5, 9.5, 3.15 * facing], [2, 9.5, 3.15 * facing], [0.5, 8.5, 3.15 * facing], [2, 8.5, 3.15 * facing]])
    en = np.tile([0, 0, facing], (8, 1))
    euv = np.array([[0, 0], [.25, 0], [0, .125], [.25, .125]] * 2)
    ef = np.array([[0, 1, 2], [1, 3, 2], [4, 5, 6], [5, 7, 6]])
    q4 = np.array([[0, 1, 2], [1, 3, 2]])
    cv = ev[:4] + np.array([0, -1.6, 0.02 * facing]); mv = ev[4:] + np.array([0, 1.2, 0.02 * facing])
    ov = np.array([[-0.5, 7.6, 3.1 * facing], [0.5, 7.6, 3.1 * facing], [-0.5, 7.2, 3.1 * facing], [0.5, 7.2, 3.1 * facing]])  # mouth
    quv = np.array([[0, 0], [1, 0], [0, 1], [1, 1]])
    muv = np.array([[0, 0], [.25, 0], [0, .125], [.25, .125]])
    e4 = en[:4]
    V = np.concatenate([bv, hv, ev, cv, mv, ov]); N = np.concatenate([bn, hn, en, e4, e4, e4])
    UV = np.concatenate([buv, huv, euv, quv, quv, muv])
    nb, nh = len(bv), len(hv)
    o = nb + nh
    F = np.concatenate([bf, hf + nb, ef + o, q4 + o + 8, q4 + o + 12, q4 + o + 16])
    # bones: 0 Position, 1 Hip, 2 Spine, 3 Head, 4 unused leaf, 5 Tail(unused)
    bones = [("センター", "Position", (0, 0, 0), -1), ("グルーブ", "Hip", (0, 3, 0), 0), ("上半身", "Spine", (0, 5, 0), 1),
             ("頭", "Head", (0, 7, 0), 2), ("Unused", "Unused", (0, 12, 0), 3), ("Tail", "Tail", (0, 3, -2), 1)]

    out = bytearray(b"PMX " + struct.pack("<f", 2.0) + bytes([8, 0, 3, 2, 1, 1, 2, 2, 2]))
    out += s("スペシャルウィーク") + s("Special Week") + s("test") + s("test")
    out += struct.pack("<i", len(V))
    for i in range(len(V)):
        out += struct.pack("<8f", *V[i], *N[i], *UV[i]) + b"\0" * 32
        out += struct.pack("<4f", outline_r(V[i]), 1, 1, 1) if outline_r else b"\0" * 16
        if i < nb:      # BDEF2 Hip/Spine
            out += bytes([1]) + struct.pack("<HHf", 1, 2, 0.6)
        elif i < nb + nh:  # BDEF4 Head
            out += bytes([2]) + struct.pack("<HHHH4f", 3, 2, 0, 0, 0.9, 0.1, 0, 0)
        else:           # BDEF1 with -1 bone (UmaViewer MeshRenderer case)
            out += bytes([0]) + struct.pack("<H", 0xFFFF)
        out += struct.pack("<f", 1.0)
    out += struct.pack("<i", F.size) + F.astype("<u2").tobytes()
    texs = ["Texture2D/tex_mbdy1001_00_diff.png", "Texture2D/tex_mchr1001_00_hair_diff.png", "Texture2D/tex_mchr0001_00_eye0.png",
            "Texture2D/tex_mchr0001_00_cheek0.png", "Texture2D/tex_mchr1001_00_mayu.png", "Texture2D/tex_mchr0001_00_mouth.png"]
    out += struct.pack("<i", len(texs)) + b"".join(s(t) for t in texs)
    mats = [("mtl_mbdy1001_00", 0, bf.size), ("mtl_mchr1001_00_hair", 1, hf.size), ("M_Eye", 2, ef.size),
            ("M_Cheek", 3, q4.size), ("M_Mayu_L", 4, q4.size), ("M_Mouth", 5, q4.size)]
    out += struct.pack("<i", len(mats))
    for name, tex, cnt in mats:
        out += s(name) + s(name) + struct.pack("<4f3ff3f", 1, 1, 1, 1, 0, 0, 0, 5, .5, .5, .5) + bytes([0x0E])
        out += struct.pack("<4ff", 0, 0, 0, 1, 0.4) + struct.pack("<bb", tex, -1) + bytes([0, 1, 0]) + s("") + struct.pack("<i", cnt)
    out += struct.pack("<i", len(bones))
    for i, (jp, en_, p, par) in enumerate(bones):
        child = next((k for k, b in enumerate(bones) if b[3] == i), 0xFFFF)
        out += s(jp) + s(en_) + struct.pack("<3f", *p) + struct.pack("<H", par & 0xFFFF) + struct.pack("<i", 0)
        out += struct.pack("<H", 0x001F) + struct.pack("<H", child)
    out += struct.pack("<i", 0) * 4  # morphs, display frames, rigid bodies, joints
    path = os.path.join(out_dir, "1001_Special Week.pmx")
    open(path, "wb").write(out)
    return path


if __name__ == "__main__":
    print(main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else -1))
