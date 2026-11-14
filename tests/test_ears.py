"""Ear bones from the game rig: injected into the GLB, skinned, and animated by the *_ear clips."""
import json, math, os, struct, sys, tempfile
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
import make_test_pmx
import test_anim
from test_pipeline import FakeObj, ref
from u2r import rig
from u2r.anim import path_hash, port_character_animations
from u2r.convert import convert

BODY = "3d/chara/mini/body/mbdy1001_00/pfb_mbdy1001_00"
HAIR = "3d/chara/mini/head/mchr1001_00/pfb_mchr1001_00_hair"
CLIP = "3d/motion/mini/event/body/chara/chr1001_00/anm_min_eve_chr1001_00_idle01_loop"
EAR = "3d/motion/mini/event/facial/chara/chr1001_00/anm_min_eve_chr1001_00_idle01_loop_ear"


def env_from(bones):
    """bones: [(name, parent index or None, PMX-space world pos)] -> UnityPy-like env of Transforms."""
    objs, world = [], {}
    for i, (n, par, p) in enumerate(bones):
        wp = (-p[0] * 0.08, p[1] * 0.08, -p[2] * 0.08)
        world[i] = wp
        lp = wp if par is None else tuple(wp[k] - world[par][k] for k in range(3))
        kids = [ref(100 + j) for j, b in enumerate(bones) if b[1] == i]
        objs.append(FakeObj(100 + i, "Transform", {"m_GameObject": ref(200 + i), "m_Father": ref(0 if par is None else 100 + par),
                    "m_Children": kids, "m_LocalPosition": dict(zip("xyz", lp)), "m_LocalRotation": {"x": 0, "y": 0, "z": 0, "w": 1},
                    "m_LocalScale": {"x": 1, "y": 1, "z": 1}}))
        objs.append(FakeObj(200 + i, "GameObject", {"m_Name": n}))
    return type("Env", (), {"objects": objs})()


BODY_BONES = [("pfb_mbdy1001_00", None, (0, 0, 0)), ("Position", 0, (0, 0, 0)), ("Hip", 1, (0, 3, 0)),
              ("Spine", 2, (0, 5, 0)), ("Head", 3, (0, 7, 0)), ("Arm_L", 3, (2.0, 6, 0))]
# head sphere in make_test_pmx: centre (0,9,0), r 3.2 (PMX units). Ears stick out of the top.
HAIR_BONES = [("pfb_mchr1001_00_hair", None, (0, 0, 0)), ("Position", 0, (0, 0, 0)), ("Hip", 1, (0, 3, 0)),
              ("Spine", 2, (0, 5, 0)), ("Head", 3, (0, 7, 0)),
              ("Ear_01_L", 4, (1.6, 11.4, 0)), ("Ear_02_L", 5, (2.2, 12.6, 0)),
              ("Ear_01_R", 4, (-1.6, 11.4, 0)), ("Ear_02_R", 7, (-2.2, 12.6, 0))]


def clip_env(tt):
    return type("Env", (), {"objects": [FakeObj(1, "AnimationClip", tt)]})()


def body_clip():
    frames = [(i / 30, [(c, 0, 0, 0, [0, 0, 0, 1][c]) for c in range(4)]) for i in range(31)]
    return {"m_Name": "idle", "m_SampleRate": 30, "m_MuscleClip": {"m_StartTime": 0, "m_StopTime": 1.0,
            "m_Clip": {"data": {"m_StreamedClip": {"data": test_anim.streamed_data(frames), "curveCount": 4},
                                "m_DenseClip": {}, "m_ConstantClip": {"data": []}}}},
            "m_ClipBindingConstant": {"genericBindings": [{"path": path_hash("Position/Hip/Spine"), "attribute": 2, "typeID": 4}]}}


def ear_clip():
    # Ear_01_L flaps 0 -> 40 degrees about z; path relative to the head prefab root
    frames = []
    for i in range(31):
        r = math.radians(40 * i / 30) / 2
        q = [0, 0, math.sin(r), math.cos(r)]
        frames.append((i / 30, [(c, 0, 0, 0, q[c]) for c in range(4)]))
    return {"m_Name": "ear", "m_SampleRate": 30, "m_MuscleClip": {"m_StartTime": 0, "m_StopTime": 1.0,
            "m_Clip": {"data": {"m_StreamedClip": {"data": test_anim.streamed_data(frames), "curveCount": 4},
                                "m_DenseClip": {}, "m_ConstantClip": {"data": []}}}},
            "m_ClipBindingConstant": {"genericBindings": [{"path": path_hash("Position/Hip/Spine/Head/Ear_01_L"), "attribute": 2, "typeID": 4}]}}


class GD:
    entries = {BODY: 1, HAIR: 1, CLIP: 1, EAR: 1}
    def mini_body_prefab(self, cid, costume): return BODY
    def mini_clips(self, cid, general=False): return [CLIP]
    def load(self, n):
        return {BODY: lambda: env_from(BODY_BONES), HAIR: lambda: env_from(HAIR_BONES),
                CLIP: lambda: clip_env(body_clip()), EAR: lambda: clip_env(ear_clip())}[n]()


def main():
    d = tempfile.mkdtemp()
    pmx = make_test_pmx.main(os.path.join(d, "in"), 1)
    sk = rig.build_skeleton(GD(), 1001, "00")
    ear = rig.ear_rig(sk)
    assert ear["chains"] == [["Ear_01_L", "Ear_02_L"], ["Ear_01_R", "Ear_02_R"]], ear["chains"]
    logs = []
    r = convert(pmx, os.path.join(d, "out"), ear_rig=ear, log=logs.append)
    assert any("ears:" in l for l in logs), logs
    g = open(r.glb, "rb").read(); jl = struct.unpack_from("<I", g, 12)[0]; j = json.loads(g[20:20 + jl]); b = g[20 + jl + 8:]
    names = [n["name"] for n in j["nodes"]]
    for e in ("Ear_01_L", "Ear_02_L", "Ear_01_R", "Ear_02_R"):
        assert e in names, names
    # ear bones are children of Head in the GLB
    head = names.index("Head")
    assert names.index("Ear_01_L") in j["nodes"][head]["children"]
    # some hair vertices weighted to the ears, body untouched
    joint_names = [names[i] for i in j["skins"][0]["joints"]]
    def acc(i, dt, n):
        a = j["accessors"][i]; v = j["bufferViews"][a["bufferView"]]
        return np.frombuffer(b, dt, a["count"] * n, v["byteOffset"]).reshape(a["count"], n)
    counts = {}
    for m in j["meshes"]:
        at = m["primitives"][0]["attributes"]
        J = acc(at["JOINTS_0"], np.uint16, 4); W = acc(at["WEIGHTS_0"], np.float32, 4)
        for jn in ("Ear_01_L", "Ear_02_L", "Ear_01_R", "Ear_02_R"):
            ji = joint_names.index(jn)
            c = int(((J == ji) & (W > 0.5)).any(1).sum())
            counts[(m["name"], jn)] = counts.get((m["name"], jn), 0) + c
    hair_ear = sum(v for (mn, _), v in counts.items() if "hair" in mn)
    body_ear = sum(v for (mn, _), v in counts.items() if mn == "mtl_mbdy1001_00")
    assert hair_ear > 0 and body_ear == 0, counts
    print("ear rig ok: bones", [n for n in names if n.startswith("Ear")], "| hair verts on ears:", hair_ear)

    # animation: body clip + its _ear clip merged; Ear_01_L rotates 40 deg, Ear_02_L follows
    written = port_character_animations(GD(), r.meta, log=lambda m: print("  ", m))
    a = json.load(open(written[0]))
    by = {bb["name"]: bb for bb in a["bones"]}
    assert "Ear_01_L" in by and "Ear_02_L" in by, list(by)
    qr = np.array(by["Ear_01_R"]["rot"]).reshape(-1, 4)
    assert np.allclose(np.abs(qr[:, 3]), 1, atol=1e-5)          # right ear has no ear motion: stays put
    q = np.array(by["Ear_01_L"]["rot"]).reshape(-1, 4)
    ang = 2 * math.degrees(math.acos(min(1, abs(q[-1][3]))))
    assert abs(ang - 40) < 0.5, ang
    print(f"ear animation ok: Ear_01_L turns {ang:.1f} deg, bones animated: {sorted(by)}")

    # real format: the _ear clip moves locators that blend the character's ear_target poses.
    # Left-ear type 9 locator at (-w, w, w) / 100 with w ramping 0 -> 1; type 9 (L) = Ear_01_L 30 deg about z
    written = port_character_animations(LocatorGD(), r.meta, log=lambda m: print("  ", m))
    a = json.load(open(written[0]))
    by = {bb["name"]: bb for bb in a["bones"]}
    q = np.array(by["Ear_01_L"]["rot"]).reshape(-1, 4)
    a0 = 2 * math.degrees(math.acos(min(1, abs(q[0][3])))); a1 = 2 * math.degrees(math.acos(min(1, abs(q[-1][3]))))
    assert a0 < 0.5 and abs(a1 - 30) < 0.5, (a0, a1)
    assert np.allclose(np.abs(np.array(by["Ear_01_R"]["rot"]).reshape(-1, 4)[:, 3]), 1, atol=1e-5)  # R weight 0
    print(f"ear locators ok: Ear_01_L 0 -> {a1:.1f} deg from ear_target type 9")


TARGET = "sourceresources/3d/chara/head/chr1001_00/facial/ast_chr1001_00_ear_target"


def locator_ear_clip():
    L9, R9 = 3090132844, 622057165          # anim.EAR_LOCATORS: (1, 9) and (0, 9)
    frames = []
    for i in range(31):
        w = i / 30 / 100
        frames.append((i / 30, [(c, 0, 0, 0, v) for c, v in enumerate([-w, w, w, 0, 0, 0])]))
    return {"m_Name": "ear", "m_SampleRate": 30, "m_MuscleClip": {"m_StartTime": 0, "m_StopTime": 1.0,
            "m_Clip": {"data": {"m_StreamedClip": {"data": test_anim.streamed_data(frames), "curveCount": 6},
                                "m_DenseClip": {}, "m_ConstantClip": {"data": []}}}},
            "m_ClipBindingConstant": {"genericBindings": [{"path": L9, "attribute": 1, "typeID": 4},
                                                          {"path": R9, "attribute": 1, "typeID": 4}]}}


def ear_target_tt():
    def trs(path, rz): return {"_path": path, "_position": {"x": 0, "y": 0, "z": 0}, "_rotation": {"x": 0, "y": 0, "z": rz}}
    faces = [{"_faceGroupInfo": [{"_trsArray": [trs("Ear_01_R", 0)]}, {"_trsArray": [trs("Ear_01_L", 0)]}]} for _ in range(17)]
    faces[9] = {"_faceGroupInfo": [{"_trsArray": [trs("Ear_01_R", -30)]}, {"_trsArray": [trs("Ear_01_L", 30)]}]}
    return {"m_Name": "ast_chr1001_00_ear_target", "_targetFaces": faces}


class LocatorGD(GD):
    entries = {**GD.entries, TARGET: 1}
    def load(self, n):
        if n == EAR:
            return clip_env(locator_ear_clip())
        if n == TARGET:
            return type("Env", (), {"objects": [FakeObj(9, "MonoBehaviour", ear_target_tt())]})()
        return super().load(n)


if __name__ == "__main__":
    main()
