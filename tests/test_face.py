"""Facial expressions: hidden variant meshes + constant swap keys from the *_face clips."""
import json, os, struct, sys, tempfile
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
import make_test_pmx
import test_anim
from test_ears import GD as EarGD, HAIR_BONES, BODY, HAIR, CLIP, env_from, clip_env, body_clip
from u2r.anim import path_hash, port_character_animations
from u2r.convert import convert

FACE = CLIP.replace("/body/", "/facial/") + "_face"
EAR = CLIP.replace("/body/", "/facial/") + "_ear"
HEAD_BONES = HAIR_BONES + [("M_Mouth", 4, (0, 7.4, 3.1)), ("M_Eye", 4, (0, 9, 3.15))]


def _clip(bindings, frames, curve_count, const=()):
    return {"m_Name": "face", "m_SampleRate": 30, "m_MuscleClip": {"m_StartTime": 0, "m_StopTime": 1.0,
            "m_Clip": {"data": {"m_StreamedClip": {"data": test_anim.streamed_data(frames), "curveCount": curve_count},
                                "m_DenseClip": {}, "m_ConstantClip": {"data": list(const)}}}},
            "m_ClipBindingConstant": {"genericBindings": bindings}}


def face_clip(kind="locator"):
    if kind == "locator":
        # real format (verified on anm_min_eve_chr1002_00_res01_e_face): Mouth_Ctrl local x = -index/100.
        # Mouth goes to expression 5 at t=0.5 with a one-frame interpolated blip (x=-0.02) just before.
        f = [(0.0, [(0, 0, 0, 0, 0.0), (1, 0, 0, 0, 0.0), (2, 0, 0, 0, 0.0)])]
        f += [(14 / 30, [(0, 0, 0, 0, -0.02)]), (15 / 30, [(0, 0, 0, 0, -0.05)])]
        return _clip([{"path": path_hash("Mouth_Ctrl"), "attribute": 1, "typeID": 4, "customType": 0}], f, 3)
    if kind == "material":
        f = [(0.0, [(0, 0, 0, 0, 0.0), (1, 0, 0, 0, 0.0)]), (0.5, [(0, 0, 0, 0, 0.25), (1, 0, 0, 0, -0.125)])]
        return _clip([{"path": path_hash("M_Mouth"), "attribute": path_hash("material._MainTex_ST.z"), "typeID": 137, "customType": 22},
                      {"path": path_hash("M_Mouth"), "attribute": path_hash("material._MainTex_ST.w"), "typeID": 137, "customType": 22}], f, 2)
    return _clip([{"path": path_hash("M_Eye"), "attribute": 0xDEADBEEF, "typeID": 114, "customType": 0}], [], 0, [3.0])


class GD(EarGD):
    entries = {BODY: 1, HAIR: 1, CLIP: 1, FACE: 1}
    kind = "locator"
    def load(self, n):
        return {BODY: lambda: EarGD().load(BODY), HAIR: lambda: env_from(HEAD_BONES),
                CLIP: lambda: clip_env(body_clip()), FACE: lambda: clip_env(face_clip(self.kind))}[n]()


def main():
    d = tempfile.mkdtemp()
    pmx = make_test_pmx.main(os.path.join(d, "in"), 1)
    logs = []
    r = convert(pmx, os.path.join(d, "out"), log=logs.append)
    meta = json.load(open(r.meta))
    face = meta["face"]
    assert set(face) == {"Eye_L", "Eye_R", "Mouth", "Mayu_L"}, set(face)
    assert face["Mouth"]["frames"] == 19 and face["Mayu_L"]["frames"] == 9 and face["Eye_L"]["frames"] == 15
    g = open(r.glb, "rb").read(); jl = struct.unpack_from("<I", g, 12)[0]; j = json.loads(g[20:20 + jl]); b = g[20 + jl + 8:]
    names = [n["name"] for n in j["nodes"]]
    head = names.index("Head")
    assert names.index("Face_Mouth_05") in j["nodes"][head]["children"]
    mesh = next(m for m in j["meshes"] if m["name"] == "Face_Mouth")
    def acc(i, dt, n):
        a = j["accessors"][i]; v = j["bufferViews"][a["bufferView"]]
        return np.frombuffer(b, dt, a["count"] * n, v["byteOffset"]).reshape(a["count"], n)
    at = mesh["primitives"][0]["attributes"]
    P = acc(at["POSITION"], np.float32, 3); UV = acc(at["TEXCOORD_0"], np.float32, 2)
    assert len(P) == 4 * 19
    pivot = np.array(face["Mouth"]["pivot"]); axis = np.array(face["Mouth"]["axis"]); inside = np.array(face["Mouth"]["inside"])
    R180 = 2 * np.outer(axis, axis) - np.eye(3)
    assert np.allclose(P[4:8].mean(0), inside, atol=1e-4)                     # variant 1 rests inside the head
    assert np.allclose((P[4:8] - pivot) @ R180.T + pivot, P[0:4], atol=1e-5)  # a 180 turn brings it onto the face
    assert np.allclose(UV[5 * 4:6 * 4] - UV[0:4], [0.25, 0.125], atol=1e-6)  # variant 5 = column 1, row 1
    assert inside[2] < P[0:4, 2].mean()                                       # inside = behind the face (+Z front)
    bone_node = j["nodes"][names.index("Face_Mouth_05")]
    head_world = next(b["world"] for b in meta["skeleton"] if b["name"] == "Head")
    assert np.allclose(np.array(head_world) + bone_node["translation"], pivot, atol=1e-5)  # bone sits at the pivot
    # Eye split into left/right by side
    eyeL = next(m for m in j["meshes"] if m["name"] == "Face_Eye_L")
    PL = acc(eyeL["primitives"][0]["attributes"]["POSITION"], np.float32, 3)[:4]
    assert (PL[:, 0] > 0).all()
    print("face variants ok:", {k: v["frames"] for k, v in face.items()}, "| swap axis", np.round(axis, 3))

    def run(kind):
        gd = GD(); gd.kind = kind
        lg = []
        w = port_character_animations(gd, r.meta, log=lg.append)
        return json.load(open(w[0])), lg, w

    for kind in ("locator", "material"):
        a, lg, _ = run(kind)
        by = {bb["name"]: bb for bb in a["bones"]}
        fb = sorted(n for n in by if n.startswith("Face_"))
        assert fb == ["Face_Mouth_00", "Face_Mouth_05"], (kind, fb)      # the 1-frame blip (2) is dropped
        q0 = np.array(by["Face_Mouth_00"]["rot"]).reshape(-1, 4); q5 = np.array(by["Face_Mouth_05"]["rot"]).reshape(-1, 4)
        ident = lambda q: np.allclose(np.abs(q[:, 3]), 1, atol=1e-5)
        turn = lambda q: np.allclose(np.abs(q[:, :3] @ axis), 1, atol=1e-5) and np.allclose(q[:, 3], 0, atol=1e-5)
        assert ident(q0[:14]) and ident(q5[:14])                          # rest expression first
        assert turn(q0[-1:]) and turn(q5[-1:])                            # then 5 turned out, 0 turned in
        assert "dpos" not in by["Face_Mouth_05"] and by["Face_Mouth_05"]["constant"] is True   # no translation
        print(f"face animation ok ({kind}): swap at frame", int(np.argmax(np.abs(q5[:, 3]) < 0.5)), "of", a["frames"])

    a, lg, w = run("unknown")
    assert not any(b["name"].startswith("Face_") for b in a["bones"])
    assert any("_face_channels.json" in l for l in lg), lg
    diag = json.load(open(os.path.join(os.path.dirname(w[0]), "_face_channels.json")))
    assert list(diag.values())[0][0]["typeID"] == 114
    print("unknown face channels dumped ok")

if __name__ == "__main__":
    main()
