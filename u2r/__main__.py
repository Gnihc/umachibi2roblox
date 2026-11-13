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
    uv = s.get("umaviewer_dir", "")
    if not catalog.is_umaviewer_dir(uv):
        uv = catalog.find_umaviewer_dir(uv)
    ap = argparse.ArgumentParser(prog="Uma2Roblox")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("convert", help="convert UmaViewer PMX export(s) to Roblox GLB")
    c.add_argument("pmx", nargs="+")
    c.add_argument("-o", "--out", default=s.get("out_dir") or catalog.default_output_dir())
    c.add_argument("--flat", action="store_true", help="no baked cel shadow")
    c.add_argument("--no-outline", action="store_true")
    an = sub.add_parser("anims", help="port mini animations for converted model(s) (their .json sidecars)")
    an.add_argument("meta", nargs="+", help="Uma_*.json files next to the .glb")
    an.add_argument("--general", action="store_true", help="also General mini animations")
    an.add_argument("--fps", type=float, default=30.0)
    an.add_argument("--root-motion", choices=["inplace", "full", "none"], default="inplace")
    ins = sub.add_parser("inspect", help="describe what mini clips animate (writes inspect_<x>.json)")
    ins.add_argument("target", nargs="+", help="character id (e.g. 1001) or raw files from the game's dat folder")
    ins.add_argument("--costume", default="00")
    l = sub.add_parser("list", help="list characters with mini models and their port status")
    l.add_argument("--game-dir", default=s.get("game_dir") or catalog.find_game_dir(uv))
    l.add_argument("--unported", action="store_true")
    a = ap.parse_args(argv)

    if a.cmd == "inspect":
        from .gamedata import GameData
        from .inspect import inspect_character, inspect_files, write_report
        gd = GameData(s.get("game_dir") or catalog.find_game_dir(uv), uv)
        if len(a.target) == 1 and a.target[0].isdigit():
            rep = inspect_character(gd, int(a.target[0]), a.costume)
            out = write_report(rep, os.path.abspath(f"inspect_{a.target[0]}.json"))
            print(f"{len(rep.get('bodyClips', []))} body clip(s), {len(rep.get('facialEntries', []))} facial entr(ies)")
        else:
            rep = inspect_files(gd, a.target)
            out = write_report(rep, os.path.abspath("inspect_files.json"))
        print("report written to", out)
        return
    if a.cmd == "anims":
        from .anim import port_character_animations
        from .gamedata import GameData
        gd = GameData(s.get("game_dir") or catalog.find_game_dir(uv), uv)
        for m in a.meta:
            print(m)
            port_character_animations(gd, m, a.general, a.fps, root_motion=a.root_motion)
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
            ear = None
            if o.ear_bones:
                try:
                    from .gamedata import GameData
                    from .rig import ear_rig_for
                    ear = ear_rig_for(GameData(s.get("game_dir") or catalog.find_game_dir(uv), uv), p)
                except Exception as ex:
                    print(f"  ears: game rig not available ({ex})")
            r = convert(p, a.out, o, ear_rig=ear)
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


def selftest() -> int:
    """Used by the release build: check the frozen exe can load every dependency."""
    import numpy, PIL, UnityPy, apsw
    from . import __version__
    print(f"Uma2Roblox {__version__}: numpy {numpy.__version__}, Pillow {PIL.__version__}, "
          f"UnityPy {UnityPy.__version__}, sqlite3mc {apsw.sqlite_lib_version()}")
    return 0


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "selftest":
        sys.exit(selftest())
    if len(sys.argv) > 1:
        cli(sys.argv[1:])
    else:
        from .gui import main as gui_main
        gui_main()


if __name__ == "__main__":
    main()
