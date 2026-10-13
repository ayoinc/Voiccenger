#!/usr/bin/env bash
# Writes a Sparkle appcast for one release. The app's SUFeedURL points at the copy attached to the
# latest GitHub Release, so the newest release always serves the newest item.
# Usage: scripts/appcast.sh <dmg> <version> <build-number> <download-url> <release-page-url> <out.xml>
#
# Environment:
#   SPARKLE_KEY_FILE  file holding the EdDSA private key (from `generate_keys -x`). When unset,
#                     sign_update reads the key from the login Keychain (account "voiccenger").
set -euo pipefail

DMG="$1" VERSION="$2" BUILD="$3" URL="$4" NOTES="$5" OUT="$6"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SIGN_UPDATE="$(find "$ROOT"/.build*/artifacts -type f -path '*Sparkle/bin/sign_update' 2>/dev/null | head -n 1)"
[[ -x "$SIGN_UPDATE" ]] || { echo "error: sign_update not found; run swift package resolve" >&2; exit 1; }

if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
    SIG_ATTRS="$("$SIGN_UPDATE" --ed-key-file "$SPARKLE_KEY_FILE" "$DMG")"
else
    SIG_ATTRS="$("$SIGN_UPDATE" --account voiccenger "$DMG")"
fi
# sign_update prints: sparkle:edSignature="…" length="…"
[[ "$SIG_ATTRS" == *'sparkle:edSignature="'* ]] || { echo "error: unexpected sign_update output: $SIG_ATTRS" >&2; exit 1; }

MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/Resources/Info.plist")"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat >"$OUT" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Voiccenger</title>
    <link>${NOTES%/releases/*}</link>
    <description>Voiccenger updates</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>${NOTES}</sparkle:fullReleaseNotesLink>
      <enclosure url="${URL}" type="application/octet-stream" ${SIG_ATTRS} />
    </item>
  </channel>
</rss>
EOF
echo "$OUT"
