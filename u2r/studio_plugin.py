"""Is the Roblox Studio plugin installed, and is it the version that ships with this app?"""
import hashlib
import os
import shutil
import sys

PLUGIN_FILE = "Uma2Roblox.lua"            # name install.ps1 gives it in Studio's Plugins folder
SOURCE_REL = os.path.join("roblox", "Uma2Roblox.plugin.lua")


def plugins_dir() -> str:
    base = os.environ.get("LOCALAPPDATA") or os.path.join(os.path.expanduser("~"), "AppData", "Local")
    return os.path.join(base, "Roblox", "Plugins")


def bundled_plugin() -> str | None:
    """The plugin this app was built with: inside the exe, next to the exe, or in the source checkout."""
    here = os.path.dirname(os.path.abspath(__file__))
    cands = []
    if getattr(sys, "_MEIPASS", None):
        cands.append(os.path.join(sys._MEIPASS, SOURCE_REL))
    if getattr(sys, "frozen", False):
        cands.append(os.path.join(os.path.dirname(sys.executable), SOURCE_REL))
    cands.append(os.path.join(os.path.dirname(here), SOURCE_REL))
    return next((c for c in cands if os.path.isfile(c)), None)


def _digest(path: str) -> str:
    """Content hash that ignores line endings (git may check the file out with CRLF)."""
    with open(path, "rb") as f:
        data = f.read().replace(b"\r\n", b"\n")
    return hashlib.sha256(data).hexdigest()


def installed_plugins() -> list[str]:
    """Uma2Roblox plugin files in Studio's Plugins folder (any name starting with Uma2Roblox, .lua/.luau)."""
    d = plugins_dir()
    try:
        names = os.listdir(d)
    except OSError:
        return []
    return [os.path.join(d, n) for n in sorted(names)
            if n.lower().startswith("uma2roblox") and n.lower().endswith((".lua", ".luau"))]


def status() -> dict:
    """{"state": "ok" | "missing" | "outdated" | "unknown", "installed": [...], "bundled": path | None,
    "message": text for the user}"""
    bundled = bundled_plugin()
    installed = installed_plugins()
    if not installed:
        return {"state": "missing", "installed": [], "bundled": bundled,
                "message": f"The Studio plugin isn't installed (nothing named Uma2Roblox in {plugins_dir()}). "
                           "Install it, then close and reopen the place in Studio."}
    if bundled is None:
        return {"state": "unknown", "installed": installed, "bundled": None,
                "message": "Studio plugin found, but this app has no copy of its own to compare it with."}
    want = _digest(bundled)
    current = [p for p in installed if _digest(p) == want]
    if not current:
        return {"state": "outdated", "installed": installed, "bundled": bundled,
                "message": "The Studio plugin is OUTDATED (its content differs from the one this app ships). "
                           "Update it, then close and reopen the place in Studio."}
    extra = [p for p in installed if p not in current]
    msg = "Studio plugin is up to date."
    if extra:
        msg = ("Studio plugin is up to date, but other, outdated copies in the Plugins folder load too "
               "(remove them): " + ", ".join(os.path.basename(p) for p in extra))
        return {"state": "outdated", "installed": installed, "bundled": bundled, "message": msg}
    return {"state": "ok", "installed": installed, "bundled": bundled, "message": msg}


def install() -> str:
    """Copy the bundled plugin into Studio's Plugins folder as Uma2Roblox.lua (what install.ps1 does).
    Copies under other names are left alone; status() keeps reporting them. Returns the installed path."""
    src = bundled_plugin()
    if src is None:
        raise FileNotFoundError(f"this app has no {SOURCE_REL} to install")
    d = plugins_dir()
    os.makedirs(d, exist_ok=True)
    dst = os.path.join(d, PLUGIN_FILE)
    shutil.copyfile(src, dst)
    return dst
