#!/usr/bin/env bash
# Builds Voiccenger in release mode for Apple silicon and Intel and assembles a signed, universal
# dist/Voiccenger.app plus a universal dist/voiccenger-cli.
# Usage: scripts/bundle.sh [--scratch-path DIR]
#
# Environment:
#   VERSION        marketing version, e.g. 1.2.0   (default: latest v* tag, else 0.0.0)
#   BUILD_NUMBER   CFBundleVersion, must increase every release for Sparkle (default: commit count)
#   SIGN_IDENTITY  codesign identity (default "-" = ad hoc). A Developer ID identity enables the
#                  hardened runtime and secure timestamps required for notarization.
#   APP_STORE=1    Mac App Store variant: no Sparkle (--disable-default-traits), sandbox entitlements,
#                  embedded provisioning profile (MAS_PROVISIONING_PROFILE_PATH), compiled asset-catalog
#                  icon (needs Xcode's actool). SIGN_IDENTITY must be the "Apple Distribution" identity.
#   ARCHS          architectures to build (default "arm64 x86_64"). SwiftPM can't build several at once
#                  without Xcode's build system, so each is built on its own and the binaries are lipo'd.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Each architecture builds in its own scratch directory (<base>-<arch>): Swift Build (Swift 6.4+) writes
# every triple to the same out/Products/Release, so one directory would mix the slices.
SCRATCH_BASE="$ROOT/.build"
if [[ "${1:-}" == "--scratch-path" && -n "${2:-}" ]]; then
    SCRATCH_BASE="$2"
fi

latest_tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
VERSION="${VERSION:-${latest_tag#v}}"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 0)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP_STORE="${APP_STORE:-0}"

TRAITS=()
if [[ "$APP_STORE" == "1" ]]; then
    [[ "$SIGN_IDENTITY" != "-" ]] || { echo "error: APP_STORE=1 needs SIGN_IDENTITY (Apple Distribution)" >&2; exit 1; }
    [[ -f "${MAS_PROVISIONING_PROFILE_PATH:-}" ]] || { echo "error: set MAS_PROVISIONING_PROFILE_PATH" >&2; exit 1; }
    xcrun --find actool >/dev/null 2>&1 || { echo "error: APP_STORE=1 needs Xcode (actool) for the icon" >&2; exit 1; }
    TRAITS=(--disable-default-traits)
fi

# Must match `platforms` in Package.swift and LSMinimumSystemVersion in Resources/Info.plist.
DEPLOYMENT_TARGET="14.4"
read -r -a ARCH_LIST <<< "${ARCHS:-arm64 x86_64}"

BIN_DIRS=()
for arch in "${ARCH_LIST[@]}"; do
    triple="$arch-apple-macosx$DEPLOYMENT_TARGET"
    SCRATCH=(--scratch-path "$SCRATCH_BASE-$arch")
    echo "==> Building release products for $arch"
    for product in Voiccenger voiccenger-cli; do
        swift build -c release --product "$product" --triple "$triple" \
            "${TRAITS[@]+"${TRAITS[@]}"}" "${SCRATCH[@]}"
    done
    BIN_DIRS+=("$(swift build -c release --triple "$triple" --show-bin-path \
        "${TRAITS[@]+"${TRAITS[@]}"}" "${SCRATCH[@]}")")
done
# Resource bundles and binary frameworks are the same for every architecture (the frameworks are universal).
BIN_DIR="${BIN_DIRS[0]}"

# lipo's output keeps each slice's code signature; everything is re-signed below anyway.
universal() {
    local name="$1" out="$2" inputs=()
    for dir in "${BIN_DIRS[@]}"; do inputs+=("$dir/$name"); done
    lipo -create "${inputs[@]}" -output "$out"
    for arch in "${ARCH_LIST[@]}"; do
        lipo "$out" -verify_arch "$arch" || { echo "error: $out lacks $arch" >&2; exit 1; }
    done
    echo "    $(lipo -info "$out")"
}

APP="$ROOT/dist/Voiccenger.app"
CONTENTS="$APP/Contents"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
universal Voiccenger "$CONTENTS/MacOS/Voiccenger"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$CONTENTS/Info.plist"
echo "    version $VERSION ($BUILD_NUMBER)"
printf 'APPL????' > "$CONTENTS/PkgInfo"
cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
if [[ "$APP_STORE" == "1" ]]; then
    # App Store builds update through the store and must not advertise a Sparkle feed.
    /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" -c "Delete :SUPublicEDKey" "$CONTENTS/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$CONTENTS/Info.plist"
    xcrun actool "$ROOT/Resources/Assets.xcassets" --compile "$CONTENTS/Resources" --platform macosx \
        --minimum-deployment-target "$DEPLOYMENT_TARGET" --app-icon AppIcon --output-partial-info-plist "$ROOT/.build-mas-icon.plist" \
        --output-format human-readable-text --notices --warnings >/dev/null
    rm -f "$ROOT/.build-mas-icon.plist"
    cp "$MAS_PROVISIONING_PROFILE_PATH" "$CONTENTS/embedded.provisionprofile"
fi

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
done < <(otool -L "$EXE" | awk '$1 ~ /^@rpath\// { print $1 }' | sort -u)

if [[ $copied_any -eq 1 ]]; then
    # Make @rpath resolve inside the bundle instead of the build directory. Each slice has its own build
    # rpaths, so each is fixed on its own and the slices are joined again.
    slices=()
    for arch in "${ARCH_LIST[@]}"; do
        slice="$EXE.$arch"
        if [[ ${#ARCH_LIST[@]} -gt 1 ]]; then lipo "$EXE" -thin "$arch" -output "$slice"; else cp "$EXE" "$slice"; fi
        while read -r rpath; do
            install_name_tool -delete_rpath "$rpath" "$slice"
        done < <(otool -l "$slice" | awk '/LC_RPATH/ { getline; getline; print $2 }' | sort -u | grep -v '^@executable_path/../Frameworks$' || true)
        if ! otool -l "$slice" | grep -q '@executable_path/../Frameworks'; then
            install_name_tool -add_rpath "@executable_path/../Frameworks" "$slice"
        fi
        slices+=("$slice")
    done
    lipo -create "${slices[@]}" -output "$EXE"
    rm -f "${slices[@]}"
else
    rmdir "$CONTENTS/Frameworks"
fi

CLI="$ROOT/dist/voiccenger-cli"
universal voiccenger-cli "$CLI"

ENTITLEMENTS="$ROOT/Resources/Voiccenger.entitlements"
[[ "$APP_STORE" == "1" ]] && ENTITLEMENTS="$ROOT/Resources/Voiccenger-MAS.entitlements"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "==> Signing (ad hoc)"
    if [[ -d "$CONTENTS/Frameworks" ]]; then
        for item in "$CONTENTS/Frameworks"/*; do
            codesign --force --sign - --timestamp=none "$item"
        done
    fi
    # No hardened runtime: ad-hoc signatures have no team ID, so library validation would reject bundled frameworks.
    codesign --force --deep --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$APP"
    codesign --force --sign - --timestamp=none "$CLI"
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
    sign "$CLI"
fi
codesign --verify --deep --strict "$APP"
codesign --verify --strict "$CLI"

echo "$APP"
echo "$CLI"
