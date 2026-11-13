"""PMX -> GLB -> animation port -> sync server, with a fake game-data object (UnityPy-shaped)."""
import json, math, os, sys, tempfile, urllib.request
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
import make_test_pmx
from u2r.anim import port_character_animations, path_hash
from u2r.convert import convert
from u2r.registry import Registry, PORT


class FakeObj:
    def __init__(self, pid, tname, tt):
        self.path_id, self._tt = pid, tt
        self.type = type("T", (), {"name": tname})()

    def read_typetree(self):
        return self._tt


def ref(pid):
    return {"m_FileID": 0, "m_PathID": pid}


def prefab_env():
    # Unity-space rest pose matching make_test_pmx bones: PMX (x,y,z) -> Unity (-x,y,-z)*0.08
    bones = [("pfb_mbdy1001_00", None, (0, 0, 0)), ("Position", 0, (0, 0, 0)), ("Hip", 1, (0, 3, 0)),
             ("Spine", 2, (0, 5, 0)), ("Head", 3, (0, 7, 0)), ("Tail", 2, (0, 3, -2)), ("Arm_L", 3, (2.0, 6, 0))]
    objs, world = [], {}
    for i, (n, par, p) in enumerate(bones):
        wp = (-p[0] * 0.08, p[1] * 0.08, -p[2] * 0.08)
        world[i] = wp
        lp = wp if par is None else tuple(wp[k] - world[par][k] for k in range(3))
        kids = [ref(100 + j) for j, b in enumerate(bones) if b[1] == i]
        objs.append(FakeObj(100 + i, "Transform", {"m_GameObject": ref(200 + i), "m_Father": ref(0 if par is None else 100 + par),
                    "m_Children": kids, "m_LocalPosition": dict(zip("xyz", lp)), "m_LocalRotation": {"x": 0, "y": 0, "z": 0, "w": 1}}))
        objs.append(FakeObj(200 + i, "GameObject", {"m_Name": n}))
    return type("Env", (), {"objects": objs})()


class FakeGD:
    entries = {}
    def mini_body_prefab(self, cid, costume): return "3d/chara/mini/body/mbdy1001_00/pfb_mbdy1001_00"
    def mini_clips(self, cid, general=False): return ["3d/motion/mini/event/body/chara/chr1001_00/anm_min_eve_chr1001_00_test01_loop"]
    def load(self, name):
        return prefab_env() if "pfb_mbdy" in name else _clip_env()


def _clip_env():
    import test_anim
    # rebuild the raw typetree used by make_clip (decode happens inside port_character_animations)
    frames = []
    for i in range(31):
        t = i / 30
        r = math.radians(90 * t) / 2
        q = [0, math.sin(r), 0, math.cos(r)]
        frames.append((t, [(c, 0, 0, 0, q[c]) for c in range(4)]))
    tt = {"m_Name": "anm_min_eve_chr1001_00_test01_loop", "m_SampleRate": 30,
          "m_MuscleClip": {"m_StartTime": 0, "m_StopTime": 1.0, "m_LoopTime": True,
                           "m_Clip": {"data": {"m_StreamedClip": {"data": test_anim.streamed_data(frames), "curveCount": 4},
                                               "m_DenseClip": {}, "m_ConstantClip": {"data": []}}}},
          "m_ClipBindingConstant": {"genericBindings": [{"path": path_hash("Position/Hip/Spine"), "attribute": 2, "typeID": 4}]}}
    return type("Env", (), {"objects": [FakeObj(1, "AnimationClip", tt)]})()


def main():
    d = tempfile.mkdtemp()
    pmx = make_test_pmx.main(os.path.join(d, "in"), -1)
    out = os.path.join(d, "out")
    r = convert(pmx, out)
    written = port_character_animations(FakeGD(), r.meta, log=lambda m: print("  ", m))
    assert len(written) == 1, written
    a = json.load(open(written[0]))
    names = [b["name"] for b in a["bones"]]
    assert names == ["Spine", "Head"], names     # Arm_L isn't in the GLB (no weights) -> skipped
    meta = json.load(open(r.meta))
    assert meta["exportPose"]["source"] == "rest pose" and meta["exportPose"]["error"] < 1e-4, meta["exportPose"]
    assert meta["rootMotion"] == "inplace" and a["rootMotion"] == "inplace"

    reg = Registry(); reg.load(out)
    err = reg.start_server(); assert err is None, err
    try:
        base = f"http://127.0.0.1:{PORT}/uma2roblox"
        model = os.path.splitext(os.path.basename(r.glb))[0]
        idx = json.load(urllib.request.urlopen(f"{base}/anims?model={urllib.request.quote(model)}"))
        assert idx["animations"] == ["anm_min_eve_chr1001_00_test01_loop"] and len(idx["skeleton"]) == 4
        an = json.load(urllib.request.urlopen(f"{base}/anim?model={urllib.request.quote(model)}&name=anm_min_eve_chr1001_00_test01_loop"))
        assert an["frames"] == 31 and len(an["bones"][0]["rot"]) == 31 * 4 and all("pos" not in b for b in an["bones"])
        print("server ok:", model, idx["animations"], "| skeleton", [b["name"] for b in idx["skeleton"]])
    finally:
        reg.stop_server()

    # hip baseline fallback: clip keeps the hip far below the export pose -> idle frame 0 becomes the baseline
    import u2r.anim as A
    orig = _clip_env

    def low_hip_env():
        env = orig()
        tt = env.objects[0].read_typetree()
        tt["m_Name"] = "anm_min_eve_chr1001_00_idle01_loop"
        tt["m_ClipBindingConstant"]["genericBindings"].append({"path": path_hash("Position/Hip"), "attribute": 1, "typeID": 4})
        tt["m_MuscleClip"]["m_Clip"]["data"]["m_ConstantClip"]["data"] = [0.0, 0.1, 0.0]   # Hip at 0.10 vs rest 0.24
        return env

    class LowGD(FakeGD):
        def mini_clips(self, cid, general=False):
            return ["3d/motion/mini/event/body/chara/chr1001_00/anm_min_eve_chr1001_00_idle01_loop"]
        def load(self, name):
            return prefab_env() if "pfb_mbdy" in name else low_hip_env()
    logs = []
    w2 = A.port_character_animations(LowGD(), r.meta, log=logs.append)
    d2 = json.load(open(w2[0]))
    assert any("hip baseline" in l for l in logs), logs
    assert all("dpos" not in b for b in d2["bones"]), [b["name"] for b in d2["bones"] if "dpos" in b]  # constant -> no offset
    print("hip baseline ok:", [l.strip() for l in logs if "baseline" in l][0][:70], "...")


if __name__ == "__main__":
    main()
