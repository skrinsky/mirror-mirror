"""
DAW plugin setup — runs automatically when the server starts.

Downloads MirrorMirror.vst3 / MirrorMirror.component from the latest
GitHub release and installs them to the standard system locations.
On macOS, removes Gatekeeper quarantine (xattr -cr) after install.
"""

import shutil
import subprocess
import sys
import threading
from pathlib import Path


GITHUB_REPO   = "skrinsky/mirror-mirror"
PLUGIN_NAME   = "MirrorMirror"
VST3_ASSET    = "MirrorMirror-mac-vst3.zip"
AU_ASSET      = "MirrorMirror-mac-au.zip"

if sys.platform == "darwin":
    VST3_DIR      = Path.home() / "Library/Audio/Plug-Ins/VST3"
    AU_DIR        = Path.home() / "Library/Audio/Plug-Ins/Components"
elif sys.platform == "win32":
    import os
    VST3_DIR      = Path(os.environ.get("LOCALAPPDATA", "")) / "Programs/Common/VST3"
    AU_DIR        = None
else:
    VST3_DIR      = Path.home() / ".vst3"
    AU_DIR        = None


# ── helpers ───────────────────────────────────────────────────────────────────

def _latest_release_assets() -> dict:
    """Return {filename: download_url} for the latest GitHub release."""
    import urllib.request, json
    url = f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest"
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            data = json.load(r)
        return {a["name"]: a["browser_download_url"] for a in data.get("assets", [])}
    except Exception as e:
        print(f"[daw_setup] could not fetch release info: {e}")
        return {}


def _download_and_extract(url: str, dest_dir: Path, bundle_name: str) -> bool:
    """Download a zip asset and extract the .vst3 or .component bundle into dest_dir."""
    import urllib.request, zipfile, io, tempfile
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / bundle_name
    print(f"[daw_setup] downloading {bundle_name} ...")
    try:
        with urllib.request.urlopen(url, timeout=60) as r:
            data = r.read()
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            with tempfile.TemporaryDirectory() as tmp:
                zf.extractall(tmp)
                src = Path(tmp) / bundle_name
                if not src.exists():
                    print(f"[daw_setup] unexpected zip layout — expected {bundle_name} at root")
                    return False
                if dest.exists():
                    shutil.rmtree(dest)
                shutil.copytree(src, dest)
        print(f"[daw_setup] installed {dest}")
        return True
    except Exception as e:
        print(f"[daw_setup] download/install failed: {e}")
        return False


def _clear_quarantine(path: Path):
    """Remove macOS Gatekeeper quarantine attribute."""
    if sys.platform != "darwin":
        return
    try:
        subprocess.run(["xattr", "-cr", str(path)], check=True, capture_output=True)
        print(f"[daw_setup] quarantine cleared: {path.name}")
    except subprocess.CalledProcessError as e:
        print(f"[daw_setup] xattr failed: {e.stderr.decode()[:200]}")


# ── main setup ────────────────────────────────────────────────────────────────

def _install_plugin():
    vst3_dest = VST3_DIR / f"{PLUGIN_NAME}.vst3"
    au_dest   = (AU_DIR / f"{PLUGIN_NAME}.component") if AU_DIR else None

    vst3_ok = vst3_dest.exists()
    au_ok   = (au_dest.exists() if au_dest else True)

    if vst3_ok and au_ok:
        print(f"[daw_setup] {PLUGIN_NAME} already installed")
        return

    assets = _latest_release_assets()
    if not assets:
        print(f"[daw_setup] skipping install — could not reach GitHub releases")
        return

    if not vst3_ok and VST3_ASSET in assets:
        ok = _download_and_extract(assets[VST3_ASSET], VST3_DIR, f"{PLUGIN_NAME}.vst3")
        if ok:
            _clear_quarantine(vst3_dest)

    if au_dest and not au_ok and AU_ASSET in assets:
        ok = _download_and_extract(assets[AU_ASSET], AU_DIR, f"{PLUGIN_NAME}.component")
        if ok:
            _clear_quarantine(au_dest)


# ── public entry point ────────────────────────────────────────────────────────

def run_in_background():
    """Call at server startup — installs the plugin in a daemon thread."""
    threading.Thread(target=_install_plugin, daemon=True, name="daw-setup").start()
