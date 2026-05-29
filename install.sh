#!/usr/bin/env bash
# Mirror Mirror — quick installer
# Downloads the pre-built plugin from GitHub Releases and sets up the Python environment.
# Does NOT require Xcode, cmake, or JUCE.
#
# Usage:
#   bash install.sh
#   bash install.sh --dir ~/my-mirror-mirror
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}>>>${NC} $*"; }
ok()   { echo -e "${GREEN}OK${NC}  $*"; }
die()  { echo -e "${RED}ERROR${NC} $*" >&2; exit 1; }

INSTALL_DIR="$HOME/mirror-mirror"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir) INSTALL_DIR="$2"; shift 2 ;;
        *)     die "Unknown argument: $1" ;;
    esac
done

REPO_URL="https://github.com/skrinsky/mirror-mirror.git"
OS="$(uname -s)"

[[ "$OS" == "Darwin" || "$OS" == "Linux" ]] || \
    die "Windows is not supported by this installer. See README for manual instructions."

echo ""
echo "  Mirror Mirror — Quick Installer"
echo "  ================================"
echo "  Install dir : $INSTALL_DIR"
echo ""

# ── git ───────────────────────────────────────────────────────────────────────
command -v git &>/dev/null || die "git is required. On macOS: install from https://git-scm.com or run 'xcode-select --install'"
ok "git $(git --version | awk '{print $3}')"

# ── uv (manages Python + venv) ────────────────────────────────────────────────
if ! command -v uv &>/dev/null; then
    info "Installing uv (Python environment manager)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
fi
command -v uv &>/dev/null || die "uv installation failed — install it manually: https://docs.astral.sh/uv/"
ok "uv $(uv --version)"

# ── Python (3.10-3.12 only — tensorflow-macos does not support 3.13+) ─────────
PYTHON_BIN=""
for candidate in python3 python; do
    if command -v "$candidate" &>/dev/null; then
        major=$("$candidate" -c 'import sys; print(sys.version_info.major)' 2>/dev/null)
        minor=$("$candidate" -c 'import sys; print(sys.version_info.minor)' 2>/dev/null)
        if [[ "$major" == "3" && "$minor" -ge 10 && "$minor" -le 12 ]]; then
            PYTHON_BIN="$candidate"
            break
        fi
    fi
done
# If no suitable Python found, uv will download 3.10.
if [[ -n "$PYTHON_BIN" ]]; then
    ok "Python $($PYTHON_BIN --version)"
else
    info "No system Python 3.10-3.12 found — uv will download Python 3.10 automatically"
fi

# ── Clone repo ────────────────────────────────────────────────────────────────
if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Repo already exists at $INSTALL_DIR — pulling latest..."
    git -C "$INSTALL_DIR" pull --ff-only
    git -C "$INSTALL_DIR" submodule update --init --recursive
else
    info "Cloning Mirror Mirror into $INSTALL_DIR..."
    git clone --recurse-submodules "$REPO_URL" "$INSTALL_DIR"
fi
ok "Repo at $INSTALL_DIR"

# ── Download pre-built plugin ─────────────────────────────────────────────────
# Done before venv setup so the plugin is saved even if Python setup fails.
info "Fetching latest release info from GitHub..."
RELEASE_JSON="$(curl -fsSL https://api.github.com/repos/skrinsky/mirror-mirror/releases/latest 2>/dev/null || true)"

if [[ -z "$RELEASE_JSON" ]] || echo "$RELEASE_JSON" | grep -q '"message": "Not Found"'; then
    echo ""
    echo -e "${YELLOW}No release found on GitHub yet.${NC}"
    echo "  Build from source with: bash $INSTALL_DIR/install-dev.sh --dir $INSTALL_DIR"
    exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PLUGIN="MirrorMirror"

if [[ "$OS" == "Darwin" ]]; then
    # Save VST3 + AU into the install dir so the sudo commands below can copy
    # from a known persistent path to /Library (works regardless of whether
    # ~/Library is hidden or inaccessible).
    VST3_URL="$(echo "$RELEASE_JSON" | grep -o '"browser_download_url": "[^"]*mac[^"]*vst3[^"]*"' | grep -oi 'https://[^"]*' | head -1)"
    if [[ -n "$VST3_URL" ]]; then
        info "Downloading VST3..."
        curl -fsSL "$VST3_URL" -o "$TMP_DIR/vst3.zip"
        unzip -qo "$TMP_DIR/vst3.zip" -d "$TMP_DIR/vst3"
        VST3_SRC="$(find "$TMP_DIR/vst3" -name "$PLUGIN.vst3" -maxdepth 3 | head -1)"
        [[ -n "$VST3_SRC" ]] || die "Could not find $PLUGIN.vst3 in the downloaded VST3 archive"
        rm -rf "$INSTALL_DIR/$PLUGIN.vst3"
        cp -r "$VST3_SRC" "$INSTALL_DIR/"
        xattr -cr "$INSTALL_DIR/$PLUGIN.vst3" 2>/dev/null || true
        ok "VST3 saved to $INSTALL_DIR/$PLUGIN.vst3"
    fi

    AU_URL="$(echo "$RELEASE_JSON" | grep -o '"browser_download_url": "[^"]*au[^"]*"' | grep -oi 'https://[^"]*' | head -1)"
    if [[ -n "$AU_URL" ]]; then
        info "Downloading AU..."
        curl -fsSL "$AU_URL" -o "$TMP_DIR/au.zip"
        unzip -qo "$TMP_DIR/au.zip" -d "$TMP_DIR/au"
        AU_SRC="$(find "$TMP_DIR/au" -name "$PLUGIN.component" -maxdepth 3 | head -1)"
        [[ -n "$AU_SRC" ]] || die "Could not find $PLUGIN.component in the downloaded AU archive"
        rm -rf "$INSTALL_DIR/$PLUGIN.component"
        cp -r "$AU_SRC" "$INSTALL_DIR/"
        xattr -cr "$INSTALL_DIR/$PLUGIN.component" 2>/dev/null || true
        ok "AU saved to $INSTALL_DIR/$PLUGIN.component"
    fi

elif [[ "$OS" == "Linux" ]]; then
    VST3_URL="$(echo "$RELEASE_JSON" | grep -o '"browser_download_url": "[^"]*vst3[^"]*linux[^"]*"' | grep -oi 'https://[^"]*' | head -1)"
    if [[ -n "$VST3_URL" ]]; then
        info "Downloading VST3..."
        curl -fsSL "$VST3_URL" -o "$TMP_DIR/vst3.zip"
        unzip -qo "$TMP_DIR/vst3.zip" -d "$TMP_DIR/vst3"
        VST3_DEST="$HOME/.vst3"
        mkdir -p "$VST3_DEST"
        rm -rf "$VST3_DEST/$PLUGIN.vst3"
        cp -r "$TMP_DIR/vst3/$PLUGIN.vst3" "$VST3_DEST/"
        ok "VST3 installed to $VST3_DEST"
    fi
fi

# ── Write install path so the plugin can find the server ─────────────────────
if [[ "$OS" == "Darwin" ]]; then
    APP_SUPPORT="$HOME/Library/Application Support/MirrorMirror"
    mkdir -p "$APP_SUPPORT"
    echo "$INSTALL_DIR" > "$APP_SUPPORT/install_path.txt"
    ok "Install path recorded for plugin"
fi

# ── Python environment ────────────────────────────────────────────────────────
info "Setting up Python environment (this may take a few minutes)..."
PYTHON_BIN="$PYTHON_BIN" bash "$INSTALL_DIR/scripts/setup_venv.sh"
ok "Python environment ready"

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Mirror Mirror installed successfully!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
if [[ "$OS" == "Darwin" ]]; then
    echo "  Plugins saved to $INSTALL_DIR — run these to install to your DAW:"
    [[ -n "${VST3_URL:-}" ]] && echo "    sudo mkdir -p /Library/Audio/Plug-Ins/VST3 && sudo cp -r $INSTALL_DIR/$PLUGIN.vst3 /Library/Audio/Plug-Ins/VST3/ && sudo xattr -cr /Library/Audio/Plug-Ins/VST3/$PLUGIN.vst3"
    [[ -n "${AU_URL:-}" ]]   && echo "    sudo mkdir -p /Library/Audio/Plug-Ins/Components && sudo cp -r $INSTALL_DIR/$PLUGIN.component /Library/Audio/Plug-Ins/Components/ && sudo xattr -cr /Library/Audio/Plug-Ins/Components/$PLUGIN.component"
fi
echo ""
echo "  Repo location: $INSTALL_DIR"
echo ""
echo "  Next steps:"
echo "    1. Open your DAW and scan for new plugins"
echo "    2. Add Mirror Mirror to a MIDI track"
echo "    3. Drop audio files into $INSTALL_DIR/data/raw/"
echo "    4. Hit Process in the plugin to begin"
echo ""
