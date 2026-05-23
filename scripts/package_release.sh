#!/usr/bin/env bash
# Usage: scripts/package_release.sh v0.2.0 ["Release notes"]
# Builds the plugin in Release mode, creates a signed-ad-hoc pkg wrapped in a
# dmg, and publishes a GitHub release.
set -euo pipefail

VERSION="${1:-}"
NOTES="${2:-}"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version> [\"release notes\"]"
    echo "  e.g. $0 v0.2.0 \"Bug fixes\""
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_DIR="$REPO_ROOT/plugin/AIMusicPlugin"
BUILD_DIR="$PLUGIN_DIR/build"
ARTEFACTS="$BUILD_DIR/AIMusicPlugin_artefacts/Release"
PRODUCT="MirrorMirror"
INSTALLER_DIR="$REPO_ROOT/installer"
OUT_DIR="$REPO_ROOT/dist"
STAGE="$OUT_DIR/stage"

mkdir -p "$OUT_DIR" "$STAGE"

# ── 1. Build plugin (Release) ─────────────────────────────────────────────────
echo ">>> Building $PRODUCT $VERSION (Release)"
cmake -S "$PLUGIN_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD_DIR" --config Release -j"${PLUGIN_JOBS:-8}"

VST3="$ARTEFACTS/VST3/$PRODUCT.vst3"
AU="$ARTEFACTS/AU/$PRODUCT.component"

[[ -d "$VST3" ]] || { echo "ERROR: VST3 not found at $VST3"; exit 1; }

# ── 2. Stage payload ──────────────────────────────────────────────────────────
# Plugins go to their standard install locations (pkgbuild maps these via --root)
echo ">>> Staging payload"
rm -rf "$STAGE"

VST3_STAGE="$STAGE/Library/Audio/Plug-Ins/VST3"
AU_STAGE="$STAGE/Library/Audio/Plug-Ins/Components"
SERVER_STAGE="$STAGE/Library/Application Support/MirrorMirror"

mkdir -p "$VST3_STAGE" "$SERVER_STAGE"
cp -r "$VST3" "$VST3_STAGE/$PRODUCT.vst3"

if [[ -d "$AU" ]]; then
    mkdir -p "$AU_STAGE"
    cp -r "$AU" "$AU_STAGE/$PRODUCT.component"
fi

# Server bundle: copy only what the server needs (no build artifacts or git)
mkdir -p "$SERVER_STAGE/plugin" "$SERVER_STAGE/training" "$SERVER_STAGE/finetune"
cp "$REPO_ROOT/plugin/server.py"      "$SERVER_STAGE/plugin/"
cp "$REPO_ROOT/plugin/daw_insert.py"  "$SERVER_STAGE/plugin/" 2>/dev/null || true
cp -r "$REPO_ROOT/training/"          "$SERVER_STAGE/training/"
cp -r "$REPO_ROOT/finetune/"          "$SERVER_STAGE/finetune/"
cp "$REPO_ROOT/requirements.txt"      "$SERVER_STAGE/" 2>/dev/null || true

# ── 3. Build .pkg ─────────────────────────────────────────────────────────────
echo ">>> Building .pkg"
PKG_COMPONENT="$OUT_DIR/${PRODUCT}-component.pkg"
PKG_FINAL="$OUT_DIR/${PRODUCT}-${VERSION}.pkg"

pkgbuild \
    --root "$STAGE" \
    --identifier "com.mirrormirror.plugin" \
    --version "$VERSION" \
    --scripts "$INSTALLER_DIR" \
    --install-location "/" \
    "$PKG_COMPONENT"

# Distribution XML for productbuild (adds welcome/license screens)
DIST_XML="$OUT_DIR/distribution.xml"
cat > "$DIST_XML" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Mirror Mirror ${VERSION}</title>
    <welcome    file="welcome.html"  mime-type="text/html"/>
    <license    file="license.txt"   mime-type="text/plain"/>
    <options customize="never" require-scripts="true"/>
    <choices-outline>
        <line choice="default"/>
    </choices-outline>
    <choice id="default" title="Mirror Mirror">
        <pkg-ref id="com.mirrormirror.plugin"/>
    </choice>
    <pkg-ref id="com.mirrormirror.plugin">${PRODUCT}-component.pkg</pkg-ref>
</installer-gui-script>
XML

productbuild \
    --distribution "$DIST_XML" \
    --resources "$INSTALLER_DIR" \
    --package-path "$OUT_DIR" \
    "$PKG_FINAL"

rm -f "$PKG_COMPONENT" "$DIST_XML"

# ── 4. Wrap in .dmg ──────────────────────────────────────────────────────────
echo ">>> Creating .dmg"
DMG="$OUT_DIR/${PRODUCT}-${VERSION}.dmg"
DMG_STAGE="$OUT_DIR/dmg_stage"
rm -rf "$DMG_STAGE" "$DMG"
mkdir -p "$DMG_STAGE"
cp "$PKG_FINAL" "$DMG_STAGE/"

hdiutil create \
    -volname "Mirror Mirror ${VERSION}" \
    -srcfolder "$DMG_STAGE" \
    -ov -format UDZO \
    "$DMG"

rm -rf "$DMG_STAGE"

echo ">>> Built: $DMG ($(du -sh "$DMG" | cut -f1))"

# ── 5. Publish GitHub release ─────────────────────────────────────────────────
echo ">>> Creating GitHub release $VERSION"
gh release create "$VERSION" \
    "$DMG" \
    --repo skrinsky/mirror-mirror \
    --title "Mirror Mirror $VERSION" \
    ${NOTES:+--notes "$NOTES"} \
    ${NOTES:-"--generate-notes"}

echo ">>> Done. Release $VERSION published."
