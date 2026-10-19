#!/bin/bash
# Builds and signs FaceIDAuthPlugin.bundle. Never needs sudo; installs nothing.
#
#   Scripts/build-plugin.sh [output-dir]           # signs with "FaceID Local Signing"
#   SIGN_IDENTITY=- Scripts/build-plugin.sh [dir]  # ad-hoc (the plugin then fails closed: it cannot verify the broker)
#   BROKER_CDHASH=<hex> ...                        # pin the broker build (set by build-app.sh)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist}"
IDENTITY="${SIGN_IDENTITY:-FaceID Local Signing}"
SRC="$ROOT/Plugins/FaceIDAuthPlugin"
BUNDLE="$OUT/FaceIDAuthPlugin.bundle"

mkdir -p "$OUT"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$SRC/Info.plist" "$BUNDLE/Contents/Info.plist"

# Universal: SecurityAgent runs natively on Apple silicon and Intel.
xcrun clang -bundle -fobjc-arc -O2 \
    -Wall -Wextra -Werror -Wno-unused-parameter \
    -mmacosx-version-min=14.0 -arch arm64 -arch x86_64 \
    -framework Foundation -framework Security \
    -o "$BUNDLE/Contents/MacOS/FaceIDAuthPlugin" \
    "$SRC/Sources/FaceIDAuthPlugin.m"

# Pin the agent's certificate in the plugin's Info.plist. At the lock screen the plugin's host
# process cannot read signing certificates (seen in a VM), so the plugin cannot derive this at
# run time. Info.plist is sealed by the signature below, so the value cannot be altered unnoticed.
if [[ "$IDENTITY" != "-" ]]; then
    certificate="$(security find-certificate -c "$IDENTITY" -Z 2>/dev/null | awk '/^SHA-1 hash:/ { print toupper($3); exit }')"
    [[ "$certificate" =~ ^[0-9A-F]{40}$ ]] || { echo "error: cannot read the SHA-1 of \"$IDENTITY\"" >&2; exit 1; }
    plutil -insert FaceIDAgentCertificateSHA1 -string "$certificate" "$BUNDLE/Contents/Info.plist"
fi

# Pin the exact broker build. Code hashes need no certificate parsing, which the lock screen's
# host process cannot do. Rebuilding the broker therefore requires rebuilding the plugin.
if [[ -n "${BROKER_CDHASH:-}" ]]; then
    cdhash="$(echo "$BROKER_CDHASH" | tr '[:lower:]' '[:upper:]')"
    [[ "$cdhash" =~ ^[0-9A-F]{40}$ ]] || { echo "error: BROKER_CDHASH is not a 40-digit hex code hash" >&2; exit 1; }
    plutil -insert FaceIDBrokerCDHash -string "$cdhash" "$BUNDLE/Contents/Info.plist"
fi

codesign --force --sign "$IDENTITY" --timestamp=none \
    --identifier com.example.faceid.authplugin \
    "$BUNDLE"
codesign --verify --strict --deep "$BUNDLE"

# The pinned value must be the certificate that actually signed the bundle (and the agent).
if [[ "$IDENTITY" != "-" ]]; then
    tmp="$(mktemp -d)"
    codesign -d --extract-certificates="$tmp/cert" "$BUNDLE" >/dev/null 2>&1
    signer="$(shasum -a 1 "$tmp/cert0" | awk '{ print toupper($1) }')"
    rm -rf "$tmp"
    [[ "$signer" == "$certificate" ]] || { echo "error: pinned certificate does not match the signer" >&2; exit 1; }
fi

echo "built: $BUNDLE (signed with: $IDENTITY)"
