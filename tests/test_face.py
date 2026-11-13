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


def face_clip():
    # M_Mouth: _MainTex_ST offset jumps to column 1, row 1 (frame 5) at t = 0.5; plus one unknown channel
    frames = [(0.0, [(0, 0, 0, 0, 0.0), (1, 0, 0, 0, 0.0)]), (0.5, [(0, 0, 0, 0, 0.25), (1, 0, 0, 0, -0.125)])]
    tt = {"m_Name": "face", "m_SampleRate": 30, "m_MuscleClip": {"m_StartTime": 0, "m_StopTime": 1.0,
          "m_Clip": {"data": {"m_StreamedClip": {"data": test_anim.streamed_data(frames), "curveCount": 2},
                              "m_DenseClip": {}, "m_ConstantClip": {"data": [3.0]}}}},
          "m_ClipBindingConstant": {"genericBindings": [
              {"path": path_hash("M_Mouth"), "attribute": path_hash("material._MainTex_ST.z"), "typeID": 137, "customType": 22},
              {"path": path_hash("M_Mouth"), "attribute": path_hash("material._MainTex_ST.w"), "typeID": 137, "customType": 22},
              {"path": path_hash("M_Eye"), "attribute": 0xDEADBEEF, "typeID": 114, "customType": 0}]}}
    return tt


class GD(EarGD):
    entries = {BODY: 1, HAIR: 1, CLIP: 1, FACE: 1}
    def load(self, n):
        return {BODY: lambda: EarGD().load(BODY), HAIR: lambda: env_from(HEAD_BONES),
                CLIP: lambda: clip_env(body_clip()), FACE: lambda: clip_env(face_clip())}[n]()


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
    hide = np.array(face["Mouth"]["hide"])
    assert np.allclose(P[4:8] - P[0:4], hide, atol=1e-5)                    # variant 1 baked inside the head
    assert np.allclose(UV[5 * 4:6 * 4] - UV[0:4], [0.25, 0.125], atol=1e-6)  # variant 5 = column 1, row 1
    assert hide[2] < 0                                                       # pushed back (face points +Z)
    # Eye split into left/right by side
    eyeL = next(m for m in j["meshes"] if m["name"] == "Face_Eye_L")
    PL = acc(eyeL["primitives"][0]["attributes"]["POSITION"], np.float32, 3)[:4]
    assert (PL[:, 0] > 0).all()
    print("face variants ok:", {k: v["frames"] for k, v in face.items()}, "| hide", np.round(hide, 3))

    written = port_character_animations(GD(), r.meta, log=logs.append)
    a = json.load(open(written[0]))
    by = {bb["name"]: bb for bb in a["bones"]}
    fb = sorted(n for n in by if n.startswith("Face_"))
    assert fb == ["Face_Mouth_00", "Face_Mouth_05"], fb
    d0 = np.array(by["Face_Mouth_00"]["dpos"]).reshape(-1, 3); d5 = np.array(by["Face_Mouth_05"]["dpos"]).reshape(-1, 3)
    n = a["frames"]; half = int(0.5 * (n - 1))
    assert np.allclose(d0[:half], 0) and np.allclose(d5[:half], 0)           # first half: rest expression
    assert np.allclose(d0[-1], hide) and np.allclose(d5[-1], -hide)          # then frame 5 shown, frame 0 hidden
    assert by["Face_Mouth_05"]["constant"] is True
    assert any("_face_channels.json" in l for l in logs), logs
    diag = json.load(open(os.path.join(os.path.dirname(written[0]), "_face_channels.json")))
    assert list(diag.values())[0][0]["typeID"] == 114
    print("face animation ok: swap at frame", int(np.argmax(np.any(d5 != 0, 1))), "of", n, "| unknown channels dumped")


if __name__ == "__main__":
    main()
