"""Synthetic checks for clip decoding, FK, export-pose matching, retargeting and game-data decryption."""
import json, math, os, struct, sys, tempfile
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
from u2r.anim import Skeleton, decode_clip, fk, match_export_pose, retarget, path_hash, quat_to_mat, mat_to_quat


def streamed_data(keys_by_time):
    """keys_by_time: [(t, [(curve, a,b,c,d), ...]), ...] -> uint32 list like Unity's StreamedClip"""
    buf = b""
    for t, keys in [(-math.inf, [])] + keys_by_time + [(math.inf, [])]:
        buf += struct.pack("<fI", t, len(keys))
        for k in keys:
            buf += struct.pack("<I4f", *k)
    return list(np.frombuffer(buf, np.uint32))


def yaw_q(deg):
    r = math.radians(deg) / 2
    return [0, math.sin(r), 0, math.cos(r)]


def make_clip(length=1.0):
    # bindings: Spine rotation (streamed, 4 curves 0-3), Head rotation (dense, 4 curves), Hip position (constant, 3)
    # Spine: yaw goes 0 -> 90 deg linearly in angle (approximate with per-frame keys, constant segments via d only)
    frames = []
    for i in range(31):
        t = i / 30 * length
        q = yaw_q(90 * t / length)
        frames.append((t, [(c, 0, 0, 0, q[c]) for c in range(4)]))
    dense = []
    for i in range(31):
        q = [math.sin(math.radians(30 * i / 30) / 2), 0, 0, math.cos(math.radians(30 * i / 30) / 2)]  # pitch 0->30
        dense += q
    tt = {
        "m_Name": "anm_min_eve_chr1001_00_test01_loop", "m_SampleRate": 30,
        "m_MuscleClip": {"m_StartTime": 0, "m_StopTime": length, "m_LoopTime": True,
                         "m_Clip": {"data": {
                             "m_StreamedClip": {"data": streamed_data(frames), "curveCount": 4},
                             "m_DenseClip": {"m_FrameCount": 31, "m_CurveCount": 4, "m_SampleRate": 30 / length, "m_BeginTime": 0, "m_SampleArray": dense},
                             "m_ConstantClip": {"data": [0.0, 0.25, 0.0]}}}},
        "m_ClipBindingConstant": {"genericBindings": [
            {"path": path_hash("Position/Hip/Spine"), "attribute": 2, "typeID": 4},
            {"path": path_hash("Position/Hip/Spine/Head"), "attribute": 2, "typeID": 4},
            {"path": path_hash("Position/Hip"), "attribute": 1, "typeID": 4},
            {"path": 12345, "attribute": 2, "typeID": 4},          # unknown bone, ignored
        ]}}
    return decode_clip(tt, "3d/motion/mini/event/body/chara/chr1001_00/anm_min_eve_chr1001_00_test01_loop")


def skeleton():
    names = ["pfb_mbdy1001_00", "Position", "Hip", "Spine", "Head", "Arm_L"]
    parents = [-1, 0, 1, 2, 3, 3]
    paths = ["", "Position", "Position/Hip", "Position/Hip/Spine", "Position/Hip/Spine/Head", "Position/Hip/Spine/Arm_L"]
    rp = np.array([[0, 0, 0], [0, 0, 0], [0, 0.24, 0], [0, 0.16, 0], [0, 0.16, 0], [0.1, 0.12, 0]], float)
    rr = np.tile([0, 0, 0, 1.0], (6, 1))
    return Skeleton(names, parents, paths, rp, rr)


def meta_for(sk, X=None, axis=(-1, 1, 1), scale=1.0):
    if X is None:
        X = fk(sk, None, np.zeros(1)).X
    A = np.diag(axis)
    bones = []
    for i, n in enumerate(sk.names[1:], 1):
        bones.append({"name": n, "source": n, "parent": sk.parents[i] - 1, "world": list(A @ X[0, i] * scale)})
    return {"unityToGltf": list(axis), "skeleton": bones, "heightMeters": 0.6}


def main():
    c = make_clip()
    sk = skeleton()
    # decoding
    v = c.tracks[(path_hash("Position/Hip/Spine"), 2)](np.array([0.0, 0.5, 1.0]))
    assert np.allclose(v[0], yaw_q(0), atol=1e-6) and np.allclose(v[1], yaw_q(45), atol=1e-6) and np.allclose(v[2], yaw_q(90), atol=1e-6), v
    hp = c.tracks[(path_hash("Position/Hip"), 1)](np.array([0.3]))
    assert np.allclose(hp, [[0, 0.25, 0]]), hp
    print("decode ok: streamed/dense/constant")

    # FK: at t=1, Spine yaw 90 + Head pitch 30; Head world position = Hip(0,.25,0)+Spine(.16)+Head(.16) straight up
    P = fk(sk, c, np.array([1.0]))
    assert np.allclose(P.X[0, 4], [0, 0.25 + 0.32, 0]), P.X[0, 4]
    assert P.animated.tolist() == [False, False, True, True, True, False]
    assert P.pos_animated.tolist() == [False, False, True, False, False, False]
    print("fk ok")

    # matching: export in rest pose
    meta = meta_for(sk)
    ex = match_export_pose(sk, meta, [c])
    desc, err = ex.desc, ex.error
    assert desc == "rest pose" and err < 1e-6 and abs(ex.k - 1) < 1e-9, (desc, err, ex.k)
    # matching: export taken from a frame where Hip is raised -> position offsets relative to Hip are equal,
    # so build a clip pose that bends: use the dense head pitch + spine yaw at t=0.6 with an extra lean
    sk2 = skeleton(); sk2.rest_rot[3] = [math.sin(math.radians(20)), 0, 0, math.cos(math.radians(20))]  # spine leaned 40deg at rest
    meta2 = meta_for(sk2, fk(sk2, None, np.zeros(1)).X)
    ex2 = match_export_pose(skeleton(), meta2, [c])
    err2 = ex2.error
    assert err2 > 0.03   # nothing matches a pose that isn't in any clip -> large error (app warns)
    # export taken mid-animation (bend the head so the frame is identifiable)
    meta3 = meta_for(sk, fk(sk, c, np.array([0.6])).X)
    ex3 = match_export_pose(sk, meta3, [c])
    desc3, err3 = ex3.desc, ex3.error
    assert abs(float(desc3.split("@ ")[1][:-1]) - 0.6) <= 1 / 30 + 1e-6 and err3 < 1e-6, (desc3, err3)
    print("match ok:", desc, "|", desc3, "| unknown pose error", round(err2, 3))

    # retarget (rest-pose export): Spine world delta at t=1 = yaw 90 (mirrored axis flips yaw sign)
    out = retarget(sk, c, meta, ex, fps=30)
    names = [b["name"] for b in out["bones"]]
    assert names == ["Hip", "Spine", "Head", "Arm_L"], names
    spine = next(b for b in out["bones"] if b["name"] == "Spine")
    q_last = np.array(spine["rot"]).reshape(-1, 4)[-1]
    A = np.diag([-1, 1, 1])
    expected = mat_to_quat(A @ quat_to_mat(np.array(yaw_q(90))) @ A)
    assert np.allclose(np.abs(np.dot(q_last, expected[0] if expected.ndim > 1 else expected)), 1, atol=1e-4), (q_last, expected)
    head = next(b for b in out["bones"] if b["name"] == "Head")
    hq = np.array(head["rot"]).reshape(-1, 4)[-1]
    Rw = quat_to_mat(np.array(yaw_q(90))) @ quat_to_mat(np.array([math.sin(math.radians(15)), 0, 0, math.cos(math.radians(15))]))
    assert np.allclose(abs(np.dot(hq, mat_to_quat(A @ Rw @ A))), 1, atol=1e-4)
    assert out["frames"] == 31 and out["loop"] and out["kind"] == "loop"
    # only Hip has a position curve: constant 0.25 vs rest 0.24 -> +0.01 m up, no absolute positions sent
    hipb = next(b for b in out["bones"] if b["name"] == "Hip")
    assert np.allclose(np.array(hipb["dpos"]).reshape(-1, 3), [0, 0.01, 0], atol=1e-6), hipb["dpos"][:3]
    assert all("pos" not in b for b in out["bones"]) and all("dpos" not in b for b in out["bones"] if b["name"] != "Hip")
    print("retarget ok:", out["name"], out["frames"], "frames,", len(out["bones"]), "bones, hip dpos", hipb["dpos"][:3])

    # the bug from the screenshot: game skeleton with a scaled root, GLB in different units
    sks = skeleton(); sks.rest_scl[1] = [0.5, 0.5, 0.5]           # Position scaled 0.5
    Xs = fk(sks, None, np.zeros(1)).X
    assert np.allclose(Xs[0, 4], [0, (0.24 + 0.32) * 0.5, 0])
    metas = meta_for(sks, Xs, scale=3.0)                          # GLB is 3x the (scaled) skeleton
    exs = match_export_pose(sks, metas, [c])
    assert exs.desc == "rest pose" and exs.error < 1e-6 and abs(exs.k - 3.0) < 1e-6, (exs.desc, exs.error, exs.k)
    outs = retarget(sks, c, metas, exs)
    hs = next(b for b in outs["bones"] if b["name"] == "Hip")
    assert np.allclose(np.array(hs["dpos"]).reshape(-1, 3)[0], [0, 0.01 * 0.5 * 3.0, 0], atol=1e-6), hs["dpos"][:3]
    sp = np.array(next(b for b in outs["bones"] if b["name"] == "Spine")["rot"]).reshape(-1, 4)[-1]
    assert np.allclose(abs(np.dot(sp, q_last)), 1, atol=1e-4)    # rotations unaffected by scale
    print("scaled skeleton ok: k =", round(exs.k, 3), "hip dpos", hs["dpos"][:3])

    # encrypted meta + bundle round trip
    import apsw
    from u2r.gamedata import GameData
    d = tempfile.mkdtemp()
    os.makedirs(os.path.join(d, "game", "dat", "ab"))
    uv = os.path.join(d, "uv"); os.makedirs(uv)
    dbkey = bytes(range(1, 33)); base = bytes(range(100, 113)); abkey = bytes([7, 9, 11, 200])
    cfg = {"MainPath": os.path.join(d, "game"), "Region": 1, "DBKeyText": dbkey.hex(), "DBBaseKeyText": base.hex(), "ABKeyText": abkey.hex()}
    json.dump(cfg, open(os.path.join(uv, "Config.json"), "w"))
    final = bytes(b ^ base[i % 13] for i, b in enumerate(dbkey))
    con = apsw.Connection(os.path.join(d, "game", "meta"))
    con.execute("PRAGMA cipher='chacha20'"); con.execute(f"PRAGMA hexkey='{final.hex()}'")
    con.execute("create table a(m,n,h,c,d,e)")
    key = 0x0123456789ABCDEF
    con.execute("insert into a values('chara', '3d/motion/mini/event/body/chara/chr1001_00/anm_min_eve_chr1001_00_idle01_loop','abHASH',0,'',?)", (key,))
    con.execute("insert into a values('chara', '3d/chara/mini/body/mbdy1001_00/pfb_mbdy1001_00','abBODY',0,'',0)")
    for sfx in ("_s", "_e"):
        con.execute("insert into a values('chara', ?,'abX',0,'',0)", ("3d/motion/mini/event/body/chara/chr1001_00/anm_min_eve_chr1001_00_idle01" + sfx,))
    con.close()
    plain = bytes(range(256)) * 4
    kb = key.to_bytes(8, "little"); keys = bytes(b ^ kb[j] for b in abkey for j in range(8))
    enc = bytearray(plain)
    for i in range(256, len(enc)):
        enc[i] ^= keys[i % len(keys)]
    open(os.path.join(d, "game", "dat", "ab", "abHASH"), "wb").write(enc)
    try:
        import sqlite3; sqlite3.connect(os.path.join(d, "game", "meta")).execute("select * from a").fetchall()
        raise SystemExit("meta should be unreadable without key")
    except sqlite3.DatabaseError:
        pass
    gd = GameData(os.path.join(d, "game"), uv)
    assert gd.bundle_bytes("3d/motion/mini/event/body/chara/chr1001_00/anm_min_eve_chr1001_00_idle01_loop") == plain
    base = "3d/motion/mini/event/body/chara/chr1001_00/anm_min_eve_chr1001_00_idle01"
    assert gd.mini_clips(1001) == [base + "_e", base + "_loop", base + "_s"], gd.mini_clips(1001)
    assert gd.mini_costumes() == {1001: ["00"]}
    print("encrypted meta + bundle decryption ok")


if __name__ == "__main__":
    main()
