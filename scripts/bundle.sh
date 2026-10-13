#!/usr/bin/env bash
# Builds Voiccenger in release mode and assembles an ad-hoc signed dist/Voiccenger.app.
# Usage: scripts/bundle.sh [--scratch-path DIR]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCRATCH=()
if [[ "${1:-}" == "--scratch-path" && -n "${2:-}" ]]; then
    SCRATCH=(--scratch-path "$2")
fi

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
        cp -R "$src" "$CONTENTS/Frameworks/"
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

echo "==> Signing (ad hoc)"
if [[ -d "$CONTENTS/Frameworks" ]]; then
    for item in "$CONTENTS/Frameworks"/*; do
        codesign --force --sign - --timestamp=none "$item"
    done
fi
# No hardened runtime: ad-hoc signatures have no team ID, so library validation would reject bundled frameworks.
codesign --force --deep --sign - --timestamp=none \
    --entitlements "$ROOT/Resources/Voiccenger.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

echo "$APP"
