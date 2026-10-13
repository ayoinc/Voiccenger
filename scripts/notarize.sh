#!/usr/bin/env bash
# Notarizes a signed DMG (or zip/pkg) with Apple and staples the ticket.
# Usage: scripts/notarize.sh dist/Voiccenger-1.2.0.dmg
#
# Credentials, first match wins:
#   NOTARY_KEYCHAIN_PROFILE                         profile from `xcrun notarytool store-credentials`
#   NOTARY_API_KEY_PATH + NOTARY_API_KEY_ID + NOTARY_API_ISSUER_ID   App Store Connect API key (.p8)
set -euo pipefail

FILE="$1"
[[ -f "$FILE" ]] || { echo "error: $FILE not found" >&2; exit 1; }

if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    AUTH=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "${NOTARY_API_KEY_PATH:-}" && -n "${NOTARY_API_KEY_ID:-}" && -n "${NOTARY_API_ISSUER_ID:-}" ]]; then
    AUTH=(--key "$NOTARY_API_KEY_PATH" --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_API_ISSUER_ID")
else
    echo "error: set NOTARY_KEYCHAIN_PROFILE or NOTARY_API_KEY_PATH/NOTARY_API_KEY_ID/NOTARY_API_ISSUER_ID" >&2
    exit 1
fi

echo "==> Submitting $(basename "$FILE") for notarization"
RESULT="$(xcrun notarytool submit "$FILE" "${AUTH[@]}" --wait --output-format json)"
echo "$RESULT"
ID="$(/usr/bin/plutil -extract id raw -o - - <<<"$RESULT")"
STATUS="$(/usr/bin/plutil -extract status raw -o - - <<<"$RESULT")"
if [[ "$STATUS" != "Accepted" ]]; then
    echo "error: notarization $STATUS" >&2
    xcrun notarytool log "$ID" "${AUTH[@]}" >&2 || true
    exit 1
fi

echo "==> Stapling"
xcrun stapler staple "$FILE"
xcrun stapler validate "$FILE"
