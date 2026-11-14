"""Swing-bone physics from the game's cloth prefabs: read, converted to GLB space, stored in the sidecar and served."""
import json, os, sys, tempfile
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
import make_test_pmx
from test_ears import BODY, HAIR, BODY_BONES, HAIR_BONES, env_from
from test_pipeline import FakeObj
from u2r.convert import convert
from u2r.physics import cloth_prefabs, port_physics
from u2r.registry import Registry

BODY_CLOTH = "3d/chara/mini/body/mbdy1001_00/clothes/pfb_mbdy1001_00_cloth00"
HEAD_CLOTH = "3d/chara/mini/head/mchr1001_00/clothes/pfb_mchr1001_00_cloth00"


def v(x, y, z):
    return {"x": x, "y": y, "z": z}


def spring(name, k, drag, g, r, children=(), cols=(), limit=None):
    return {"_boneName": name, "_stiffnessForce": k, "_dragForce": drag, "_gravity": g, "_collisionRadius": r,
            "_isLimit": 1 if limit else 0, "_limitAngleMin": v(*(limit or (180, 180, 180))),
            "_limitAngleMax": v(*(limit or (180, 180, 180))), "MoveSpringApplyRate": 1.0,
            "_collisionNameList": list(cols), "_childElements": list(children)}


def collider(name, bone, kind, a, b=(0, 0, 0), r=0.1, inner=0):
    return {"_collisionName": name, "_targetObjectName": bone, "_type": kind, "_offset": v(*a), "_offset2": v(*b),
            "_radius": r, "_isInner": inner}


def container(springs, colliders):
    tt = {"m_Name": "", "springParam": springs, "collisionParam": colliders}
    return type("Env", (), {"objects": [FakeObj(1, "GameObject", {"m_Name": "cloth"}), FakeObj(2, "MonoBehaviour", tt)]})()


class GD:
    def __init__(self, game_dir):
        self.game_dir = game_dir                  # no master.mdb: no tail
        self.entries = {BODY: 1, HAIR: 1, BODY_CLOTH: 1, HEAD_CLOTH: 1}

    def mini_body_prefab(self, cid, costume):
        return BODY

    def load(self, n):
        if n == BODY:
            return env_from(BODY_BONES)
        if n == HAIR:
            return env_from(HAIR_BONES)
        if n == BODY_CLOTH:
            return container([spring("Spine", 90, 350, 250, 0.02, cols=["Col_Hip"])],
                             [collider("Col_Hip", "Hip", 0, (0, 0.05, 0), r=0.1),
                              collider("Col_Plane", "Hip", 3, (0, 0, 0))])                     # planes are skipped
        if n == HEAD_CLOTH:
            return container([spring("Head", 150, 900, 300, 0.03, limit=(30, 15, 0),
                                     children=[spring("Unused", 150, 800, 400, 0.05)], cols=["Col_Head", "Col_Arm"])],
                             [collider("Col_Head", "Head", 0, (0, 0.1, 0), r=0.2),
                              collider("Col_Arm", "Head", 2, (0.1, 0, 0), (0.3, 0, 0), r=0.05),
                              collider("Col_In", "Head", 0, (0, 0, 0.2), r=0.3, inner=1),
                              collider("Col_Hip", "Hip", 0, (9, 9, 9))])                        # duplicate name: first wins
        raise KeyError(n)


def main():
    d = tempfile.mkdtemp()
    pmx = make_test_pmx.main(os.path.join(d, "in"), 1)
    r = convert(pmx, os.path.join(d, "out"), log=lambda s: None)
    gd = GD(d)
    assert [p for p, _ in cloth_prefabs(gd, 1001, "00", None)] == ["body", "head"]
    logs = []
    phys = port_physics(gd, r.meta, log=logs.append)
    assert phys and any("2 spring chain(s)" in l for l in logs), logs
    k = phys["unitScale"]
    assert k > 0

    chains = {c["root"]: c for c in phys["chains"]}
    head = chains["Head"]
    assert head["part"] == "head" and head["inRig"] == [True, False], head
    assert head["colliders"] == ["Col_Head", "Col_Arm"]
    b0, b1 = head["bones"]
    assert (b0["stiffness"], b0["drag"], b0["gravity"]) == (150, 900, 300)
    assert abs(b0["radius"] - 0.03 * k) < 1e-5 and abs(b1["radius"] - 0.05 * k) < 1e-5     # game units -> GLB metres
    assert b0["limit"] == [30, 15, 0, 30, 15, 0] and b1["limit"] is None
    assert chains["Spine"]["part"] == "body"

    cols = {c["name"]: c for c in phys["colliders"]}
    assert set(cols) == {"Col_Hip", "Col_Head", "Col_Arm", "Col_In"}, list(cols)
    assert np.allclose(cols["Col_Hip"]["a"], [0, 0.05 * k, 0], atol=1e-5)                   # body copy, not the duplicate
    assert cols["Col_Head"]["type"] == "sphere" and abs(cols["Col_Head"]["radius"] - 0.2 * k) < 1e-5
    # Unity bone-local -> GLB world: the sidecar's unityToGltf flip, lengths scaled by k
    A = np.array(json.load(open(r.meta, encoding="utf-8"))["unityToGltf"], float)
    assert cols["Col_Arm"]["type"] == "capsule"
    assert np.allclose(cols["Col_Arm"]["a"], A * [0.1 * k, 0, 0], atol=1e-5), cols["Col_Arm"]
    assert np.allclose(cols["Col_Arm"]["b"], A * [0.3 * k, 0, 0], atol=1e-5)
    assert cols["Col_In"]["inner"] is True and np.allclose(cols["Col_In"]["a"], A * [0, 0, 0.2 * k], atol=1e-5)
    assert A[2] == -1 and cols["Col_In"]["a"][2] < 0                                       # the flip is applied

    meta = json.load(open(r.meta, encoding="utf-8"))
    assert meta["physics"]["chains"] == phys["chains"]

    reg = Registry()
    reg.out_dir = os.path.dirname(r.meta)
    resp = reg.physics(os.path.basename(r.meta)[:-5])
    assert resp["chains"] == phys["chains"] and resp["skeleton"] and resp["colliders"]
    print(f"physics ok: {len(phys['chains'])} chains, {len(phys['colliders'])} colliders, unit scale {k:.4f}")


if __name__ == "__main__":
    main()
