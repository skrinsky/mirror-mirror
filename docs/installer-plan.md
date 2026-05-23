# macOS pkg/dmg Installer Plan

## Goal
A double-click installer that puts Mirror Mirror in the user's DAW with no Terminal
required, beyond one Gatekeeper bypass (unavoidable without a paid Developer account).

---

## User Experience

1. Download `MirrorMirror-v0.x.x.dmg` from the GitHub release
2. Double-click to mount — sees a `.pkg` file inside
3. Double-click the `.pkg` → macOS shows *"can't be verified"* warning
4. Go to **System Settings → Privacy & Security → Open Anyway** (one-time, ~10 seconds)
5. Standard macOS installer wizard runs — click through Next/Install/Done
6. In the background, post-install script:
   - Copies `MirrorMirror.vst3` and `MirrorMirror.component` to the right locations
   - Runs `xattr -cr` on both to clear quarantine
   - Installs `uv` if not present
   - Creates `.venv-ai-music` and installs Python dependencies (torch, fastapi, etc.) — takes a few minutes, internet required
   - Installs a `LaunchAgent` so the server auto-starts at login
7. Open DAW, scan for plugins — Mirror Mirror appears

---

## What Gets Built

```
MirrorMirror-v0.x.x.dmg
└── MirrorMirror.pkg
    ├── Payload/
    │   ├── MirrorMirror.vst3          → ~/Library/Audio/Plug-Ins/VST3/
    │   ├── MirrorMirror.component     → ~/Library/Audio/Plug-Ins/Components/
    │   └── MirrorMirror-server/       → ~/Library/Application Support/MirrorMirror/
    │       ├── plugin/server.py
    │       ├── training/
    │       ├── finetune/
    │       └── requirements.txt
    └── Scripts/
        ├── preinstall
        └── postinstall
```

The server directory is a trimmed copy of the repo — just the Python code, no
build artifacts, git history, or vendor submodule (the audio→MIDI pipeline is
optional; the server runs fine without it for generate/train flows).

---

## postinstall Script

```bash
#!/usr/bin/env bash
set -euo pipefail

SUPPORT="$HOME/Library/Application Support/MirrorMirror"
VENV="$SUPPORT/.venv"

# 1. Clear quarantine on plugins
xattr -cr "$HOME/Library/Audio/Plug-Ins/VST3/MirrorMirror.vst3"   2>/dev/null || true
xattr -cr "$HOME/Library/Audio/Plug-Ins/Components/MirrorMirror.component" 2>/dev/null || true

# 2. Install uv if not present
if ! command -v uv &>/dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi

# 3. Create venv + install deps (runs in background, output to log)
LOG="$SUPPORT/install.log"
nohup bash -c "
  uv venv --python 3.10 '$VENV'
  source '$VENV/bin/activate'
  uv pip install fastapi uvicorn torch torchaudio pretty_midi scipy numpy mido
  echo DONE
" >> "$LOG" 2>&1 &

# 4. Install LaunchAgent so server starts at login
PLIST="$HOME/Library/LaunchAgents/com.mirrormirror.server.plist"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>             <string>com.mirrormirror.server</string>
    <key>ProgramArguments</key>
    <array>
        <string>$VENV/bin/python</string>
        <string>$SUPPORT/plugin/server.py</string>
        <string>--root</string>  <string>$SUPPORT</string>
    </array>
    <key>RunAtLoad</key>         <true/>
    <key>KeepAlive</key>         <true/>
    <key>StandardOutPath</key>   <string>$SUPPORT/server.log</string>
    <key>StandardErrorPath</key> <string>$SUPPORT/server.log</string>
</dict>
</plist>
PLIST

launchctl load "$PLIST"
```

---

## preinstall Script

Just removes any previous install if present:
```bash
#!/usr/bin/env bash
launchctl unload "$HOME/Library/LaunchAgents/com.mirrormirror.server.plist" 2>/dev/null || true
rm -rf "$HOME/Library/Application Support/MirrorMirror"
```

---

## Build Script Changes Needed

`scripts/package_release.sh` currently:
- Builds the plugin in Release mode via cmake ✓
- Zips VST3 + AU and uploads to GitHub ✓

Needs to also:
- Copy a trimmed server bundle into a staging directory
- Run `pkgbuild` to create the `.pkg` from the staged payload + scripts
- Run `productbuild` to wrap it with the installer wizard UI (license, welcome screen)
- Run `hdiutil` to wrap the `.pkg` in a `.dmg`
- Upload the `.dmg` to the GitHub release instead of (or alongside) the zip files

---

## PluginProcessor.cpp Changes Needed

Currently looks for the repo relative to the plugin executable path. With the
installer, the server lives at a fixed location:
`~/Library/Application Support/MirrorMirror/`

Add that as a fallback search path in `findRepoRoot()` so the plugin finds
the server without the user having to point at anything.

---

## What Needs to Be Written

| File | Status | Notes |
|---|---|---|
| `scripts/package_release.sh` | exists, needs updates | add pkgbuild/productbuild/hdiutil steps, fix product name to MirrorMirror |
| `scripts/postinstall` | new | dep install + LaunchAgent |
| `scripts/preinstall` | new | cleanup previous install |
| `installer/welcome.html` | new | friendly text shown in wizard |
| `installer/license.txt` | new | shown in wizard |
| `PluginProcessor.cpp` | small change | add Application Support fallback to findRepoRoot() |
| `daw_setup.py` | done | no longer needed for plugin install — can be removed or kept for future |

---

## Caveats

- **Gatekeeper step is unavoidable** without a $99/yr Developer account + notarization
- **First-launch dep install takes a few minutes** (torch is large) — user won't see progress unless they check `~/Library/Application Support/MirrorMirror/install.log`
- **Python 3.10 is required** — uv handles this if it's not installed, but adds to first-launch time
- **No Windows/Linux installer yet** — this plan is macOS only; Windows would use an NSIS or WiX installer (separate effort)
