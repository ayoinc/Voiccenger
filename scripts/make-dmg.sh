#!/usr/bin/env bash
# Packages an app bundle into a drag-to-install DMG with the Voiccenger background.
# Usage: scripts/make-dmg.sh dist/Voiccenger.app dist/Voiccenger-1.2.0.dmg
#
# Environment:
#   SIGN_IDENTITY  sign the DMG with this identity (default "-": DMG left unsigned; the app inside
#                  carries its own signature).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUT="$2"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NAME="$(basename "$APP" .app)"
VOLNAME="$NAME"

[[ -d "$APP" ]] || { echo "error: $APP not found" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

WORK="$(mktemp -d)"
MOUNT=""
cleanup() {
    [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> Staging"
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/Resources/dmg-background.tiff" "$STAGE/.background/background.tiff"

echo "==> Creating writable image"
RW="$WORK/rw.dmg"
SIZE_MB=$(($(du -sm "$STAGE" | cut -f1) + 40))
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ -format UDRW -size "${SIZE_MB}m" "$RW"
MOUNT="$(hdiutil attach "$RW" -readwrite -noverify -noautoopen -nobrowse | awk -F'\t' '/\/Volumes\// { print $NF }')"
[[ -n "$MOUNT" ]] || { echo "error: could not mount $RW" >&2; exit 1; }

echo "==> Laying out installer window"
# Finder writes the window layout into the volume's .DS_Store. -nobrowse hides the volume from
# Finder's sidebar but Finder can still address it by its POSIX path.
osascript <<EOF
tell application "Finder"
    set dmg to (POSIX file "$MOUNT" as alias)
    open dmg
    set win to container window of dmg
    set current view of win to icon view
    set toolbar visible of win to false
    set statusbar visible of win to false
    set bounds of win to {200, 120, 860, 520}
    set opts to icon view options of win
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff" of dmg
    set position of item "$NAME.app" of dmg to {165, 190}
    set position of item "Applications" of dmg to {495, 190}
    update dmg without registering applications
    delay 1
    close win
end tell
EOF
sync
[[ -f "$MOUNT/.DS_Store" ]] || { echo "error: Finder did not write the window layout" >&2; exit 1; }
# Carry the layout into the staging folder and build the final image from it. `hdiutil convert`
# of the writable image fails on some hosts (EAGAIN while rewriting the UDIF header); `create`
# from a folder doesn't, and the volume name matches so the background reference resolves.
cp "$MOUNT/.DS_Store" "$STAGE/.DS_Store"
hdiutil detach "$MOUNT" -quiet
MOUNT=""

echo "==> Compressing"
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ -format ULFO "$OUT"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
    echo "==> Signing DMG"
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$OUT"
fi
echo "$OUT"
