#!/usr/bin/env bash
# Mirror Mirror — install server as a macOS LaunchAgent
#
# Run this once after install.sh to make the server start automatically
# at login and stay running independently of any DAW.
#
# Usage:
#   bash ~/mirror-mirror/scripts/install_launchagent.sh
#   bash ~/mirror-mirror/scripts/install_launchagent.sh --dir ~/my-mirror-mirror
#   bash ~/mirror-mirror/scripts/install_launchagent.sh --uninstall

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}>>>${NC} $*"; }
ok()   { echo -e "${GREEN}OK${NC}  $*"; }
die()  { echo -e "${RED}ERROR${NC} $*" >&2; exit 1; }

INSTALL_DIR="$HOME/mirror-mirror"
UNINSTALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)       INSTALL_DIR="$2"; shift 2 ;;
        --uninstall) UNINSTALL=1; shift ;;
        *)           die "Unknown argument: $1" ;;
    esac
done

[[ "$(uname -s)" == "Darwin" ]] || die "LaunchAgent install is macOS-only."

LABEL="com.mirrormirror.server"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# ── uninstall ─────────────────────────────────────────────────────────────────
if [[ "$UNINSTALL" -eq 1 ]]; then
    if [[ -f "$PLIST" ]]; then
        launchctl unload "$PLIST" 2>/dev/null || true
        rm "$PLIST"
        ok "LaunchAgent removed."
    else
        echo "LaunchAgent not installed — nothing to remove."
    fi
    exit 0
fi

# ── validate paths ────────────────────────────────────────────────────────────
PYTHON="$INSTALL_DIR/.venv/bin/python"
SERVER="$INSTALL_DIR/plugin/server.py"

[[ -f "$PYTHON" ]] || die "Python venv not found at $PYTHON — run install.sh first."
[[ -f "$SERVER" ]] || die "server.py not found at $SERVER — check --dir path."

mkdir -p "$HOME/Library/LaunchAgents"

# ── write plist ───────────────────────────────────────────────────────────────
info "Writing LaunchAgent plist to $PLIST..."
cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON</string>
        <string>$SERVER</string>
        <string>--root</string>
        <string>$INSTALL_DIR</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/mirrormirror_server.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/mirrormirror_server.log</string>
</dict>
</plist>
EOF

# ── load it ───────────────────────────────────────────────────────────────────
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
ok "LaunchAgent loaded — server is starting now."

echo ""
echo "  The Mirror Mirror server will now start automatically at login."
echo "  Check status : launchctl list | grep mirrormirror"
echo "  View log     : tail -f /tmp/mirrormirror_server.log"
echo "  Uninstall    : bash $INSTALL_DIR/scripts/install_launchagent.sh --uninstall"
echo ""
