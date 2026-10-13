#!/usr/bin/env bash
# Builds Voiccenger in release mode and assembles a signed dist/Voiccenger.app.
# Usage: scripts/bundle.sh [--scratch-path DIR]
#
# Environment:
#   VERSION        marketing version, e.g. 1.2.0   (default: latest v* tag, else 0.0.0)
#   BUILD_NUMBER   CFBundleVersion, must increase every release for Sparkle (default: commit count)
#   SIGN_IDENTITY  codesign identity (default "-" = ad hoc). A Developer ID identity enables the
#                  hardened runtime and secure timestamps required for notarization.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCRATCH=()
if [[ "${1:-}" == "--scratch-path" && -n "${2:-}" ]]; then
    SCRATCH=(--scratch-path "$2")
fi

latest_tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
VERSION="${VERSION:-${latest_tag#v}}"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 0)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "==> Building release product"
swift build -c release --product Voiccenger "${SCRATCH[@]+"${SCRATCH[@]}"}"
BIN_DIR="$(swift build -c release --show-bin-path "${SCRATCH[@]+"${SCRATCH[@]}"}")"

APP="$ROOT/dist/Voiccenger.app"
CONTENTS="$APP/Contents"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
cp "$BIN_DIR/Voiccenger" "$CONTENTS/MacOS/Voiccenger"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$CONTENTS/Info.plist"
echo "    version $VERSION ($BUILD_NUMBER)"
printf 'APPL????' > "$CONTENTS/PkgInfo"
cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

# SwiftPM resource bundles (Bundle.module looks in the main bundle's resource directory).
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
    echo "    resource bundle: $(basename "$bundle")"
    cp -R "$bundle" "$CONTENTS/Resources/"
done

# Dynamically linked frameworks/dylibs referenced through @rpath (e.g. FluidAudio's binary targets).
EXE="$CONTENTS/MacOS/Voiccenger"
copied_any=0
while read -r dep; do
    name="${dep#@rpath/}"
    top="${name%%/*}"
    if [[ "$top" == *.framework ]]; then
        src="$BIN_DIR/$top"
        [[ -d "$src" ]] || src="$(find "$BIN_DIR" "$ROOT"/.build*/artifacts -type d -name "$top" -path "*macos*" 2>/dev/null | head -n 1)"
        [[ -n "$src" && -d "$src" ]] || { echo "error: can't find $top for $dep" >&2; exit 1; }
        echo "    framework: $top"
        ditto "$src" "$CONTENTS/Frameworks/$top"
    else
        src="$BIN_DIR/$name"
        [[ -f "$src" ]] || { echo "error: can't find $name for $dep" >&2; exit 1; }
        echo "    dylib: $name"
        cp "$src" "$CONTENTS/Frameworks/"
    fi
    copied_any=1
done < <(otool -L "$EXE" | awk 'NR > 1 && $1 ~ /^@rpath\// { print $1 }')

if [[ $copied_any -eq 1 ]]; then
    # Make @rpath resolve inside the bundle instead of the build directory.
    while read -r rpath; do
        install_name_tool -delete_rpath "$rpath" "$EXE"
    done < <(otool -l "$EXE" | awk '/LC_RPATH/ { getline; getline; print $2 }' | grep -v '^@executable_path/../Frameworks$' || true)
    if ! otool -l "$EXE" | grep -q '@executable_path/../Frameworks'; then
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE"
    fi
else
    rmdir "$CONTENTS/Frameworks"
fi

ENTITLEMENTS="$ROOT/Resources/Voiccenger.entitlements"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "==> Signing (ad hoc)"
    if [[ -d "$CONTENTS/Frameworks" ]]; then
        for item in "$CONTENTS/Frameworks"/*; do
            codesign --force --sign - --timestamp=none "$item"
        done
    fi
    # No hardened runtime: ad-hoc signatures have no team ID, so library validation would reject bundled frameworks.
    codesign --force --deep --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$APP"
else
    echo "==> Signing with $SIGN_IDENTITY (hardened runtime)"
    sign() { codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$@"; }
    # Inside-out: nested helpers before their container. Sparkle's layout per its "Sandboxing and
    # code signing" guide; the Downloader keeps its own entitlements.
    SPARKLE="$CONTENTS/Frameworks/Sparkle.framework"
    if [[ -d "$SPARKLE" ]]; then
        sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
        sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
        sign "$SPARKLE/Versions/B/Autoupdate"
        sign "$SPARKLE/Versions/B/Updater.app"
    fi
    if [[ -d "$CONTENTS/Frameworks" ]]; then
        for item in "$CONTENTS/Frameworks"/*; do
            sign "$item"
        done
    fi
    sign --entitlements "$ENTITLEMENTS" "$APP"
fi
codesign --verify --deep --strict "$APP"

echo "$APP"
