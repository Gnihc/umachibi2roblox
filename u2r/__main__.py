"""Uma2Roblox entry point.

  Uma2Roblox.exe                         open the app
  Uma2Roblox.exe convert X.pmx [-o DIR]  convert one UmaViewer PMX export
  Uma2Roblox.exe list [--game-dir DIR]   print characters and port status
"""
import argparse
import os
import sys


def cli(argv):
    from . import catalog
    from .convert import Options, convert
    from .settings import load_settings
    from .registry import Registry

    s = load_settings()
    uv = s.get("umaviewer_dir", catalog.DEFAULT_UMAVIEWER_DIR)
    ap = argparse.ArgumentParser(prog="Uma2Roblox")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("convert", help="convert UmaViewer PMX export(s) to Roblox GLB")
    c.add_argument("pmx", nargs="+")
    c.add_argument("-o", "--out", default=s.get("out_dir") or os.path.join(os.path.dirname(uv), "Uma2Roblox_Export"))
    c.add_argument("--flat", action="store_true", help="no baked cel shadow")
    c.add_argument("--no-outline", action="store_true")
    an = sub.add_parser("anims", help="port mini animations for converted model(s) (their .json sidecars)")
    an.add_argument("meta", nargs="+", help="Uma_*.json files next to the .glb")
    an.add_argument("--general", action="store_true", help="also General mini animations")
    an.add_argument("--fps", type=float, default=30.0)
    l = sub.add_parser("list", help="list characters with mini models and their port status")
    l.add_argument("--game-dir", default=s.get("game_dir") or catalog.find_game_dir(uv))
    l.add_argument("--unported", action="store_true")
    a = ap.parse_args(argv)

    if a.cmd == "anims":
        from .anim import port_character_animations
        from .gamedata import GameData
        gd = GameData(s.get("game_dir") or catalog.find_game_dir(uv), uv)
        for m in a.meta:
            print(m)
            port_character_animations(gd, m, a.general, a.fps)
        return
    if a.cmd == "convert":
        o = Options.from_dict(s.get("options", {}))
        if a.flat:
            o.shade = "flat"
        if a.no_outline:
            o.outline = False
        reg = Registry()
        reg.load(a.out)
        for p in a.pmx:
            r = convert(p, a.out, o)
            reg.mark_exported(r.chara_id, r.name, r.costume, os.path.basename(r.glb))
            print(f"{r.glb}  ({r.meshes} meshes, {r.triangles} tris, {r.bones} bones{'' if r.is_mini else ', NOT mini'})")
    else:
        reg = Registry()
        reg.load(s.get("out_dir", ""))
        minis = catalog.load_mini_costumes(a.game_dir, uv)
        for cid, name in catalog.load_characters(a.game_dir):
            cos = None if minis is None else minis.get(cid, [])
            if cos == []:
                continue
            st = reg.status_of(cid) or "not ported"
            if a.unported and st != "not ported":
                continue
            print(f"{cid}\t{name}\t{'?' if cos is None else ','.join(cos)}\t{st}")


def main():
    if len(sys.argv) > 1:
        cli(sys.argv[1:])
    else:
        from .gui import main as gui_main
        gui_main()


if __name__ == "__main__":
    main()
