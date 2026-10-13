#!/usr/bin/env bash
# Builds the Mac App Store variant (sandboxed, no Sparkle) and packages it for App Store Connect.
# Usage: scripts/make-mas-pkg.sh dist/Voiccenger-<version>.pkg
#
# Environment:
#   VERSION, BUILD_NUMBER         as in bundle.sh (BUILD_NUMBER must increase for every upload)
#   MAS_APP_IDENTITY              "Apple Distribution: …" signing identity (or its SHA-1)
#   MAS_INSTALLER_IDENTITY        "3rd Party Mac Developer Installer: …" identity (or its SHA-1)
#   MAS_PROVISIONING_PROFILE_PATH "Voiccenger Mac App Store" .provisionprofile
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$1"
: "${MAS_APP_IDENTITY:?}" "${MAS_INSTALLER_IDENTITY:?}" "${MAS_PROVISIONING_PROFILE_PATH:?}"

APP_STORE=1 SIGN_IDENTITY="$MAS_APP_IDENTITY" \
    MAS_PROVISIONING_PROFILE_PATH="$MAS_PROVISIONING_PROFILE_PATH" \
    "$ROOT/scripts/bundle.sh" --scratch-path "$ROOT/.build-mas"

APP="$ROOT/dist/Voiccenger.app"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox" \
    || { echo "error: $APP is not sandboxed" >&2; exit 1; }
[[ ! -d "$APP/Contents/Frameworks/Sparkle.framework" ]] \
    || { echo "error: App Store build must not contain Sparkle" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
productbuild --component "$APP" /Applications --sign "$MAS_INSTALLER_IDENTITY" "$OUT"
pkgutil --check-signature "$OUT"
echo "$OUT"
