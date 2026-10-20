#!/bin/bash
# Builds and signs FaceID.app and FaceIDAgent into dist/. Never needs sudo; installs nothing.
#
#   Scripts/build-app.sh                 # sign with the "FaceID Local Signing" certificate
#   SIGN_IDENTITY="Other Name" Scripts/build-app.sh
#   Scripts/build-app.sh --adhoc         # ad-hoc signature (agent will refuse the app; for build checks only)
#   BUILD_CONFIGURATION=debug Scripts/build-app.sh   # for VMs: no Secure Enclave there, and release
#                                                    # builds refuse to run without one (by design)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
IDENTITY="${SIGN_IDENTITY:-FaceID Local Signing}"
CONFIGURATION="${BUILD_CONFIGURATION:-release}"
case "$CONFIGURATION" in
    release|debug) ;;
    *) echo "error: BUILD_CONFIGURATION must be release or debug" >&2; exit 1 ;;
esac

if [[ "${1:-}" == "--adhoc" ]]; then
    IDENTITY="-"
    echo "warning: ad-hoc signing; the agent and the app will not trust each other" >&2
elif ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    echo "error: signing certificate \"$IDENTITY\" not found. See docs/local-signing.md" >&2
    exit 1
fi

cd "$ROOT"
swift build -c "$CONFIGURATION" --product FaceIDAgent
swift build -c "$CONFIGURATION" --product FaceIDApp
swift build -c "$CONFIGURATION" --product FaceIDBroker
BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$DIST"
mkdir -p "$DIST/FaceID.app/Contents/MacOS"
cp "$ROOT/Apps/FaceIDApp/Info.plist" "$DIST/FaceID.app/Contents/Info.plist"
cp "$BIN/FaceIDApp" "$DIST/FaceID.app/Contents/MacOS/FaceIDApp"
cp "$BIN/FaceIDAgent" "$DIST/FaceIDAgent"
cp "$ROOT/Apps/FaceIDAgent/agent.sb" "$DIST/agent.sb"
cp "$BIN/FaceIDBroker" "$DIST/FaceIDBroker"
cp "$ROOT/Apps/FaceIDBroker/broker.sb" "$DIST/broker.sb"

# Hardened runtime, explicit identifiers (they are part of the XPC signing requirements).
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
    --identifier com.example.faceid.agent \
    --entitlements "$ROOT/Apps/FaceIDAgent/FaceIDAgent.entitlements" \
    "$DIST/FaceIDAgent"
# The broker is ad-hoc signed on purpose: the lock screen's plugin host cannot evaluate trust in a
# non-Apple certificate (CSSMERR_TP_NOT_TRUSTED, seen in a VM), so everyone verifies the broker by
# its exact code hash instead (plugin: Info.plist pin; agent: pins.plist written by install.sh).
codesign --force --sign - --options runtime --timestamp=none \
    --identifier com.example.faceid.broker \
    --entitlements "$ROOT/Apps/FaceIDBroker/FaceIDBroker.entitlements" \
    "$DIST/FaceIDBroker"
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
    --identifier com.example.faceid.app \
    --entitlements "$ROOT/Apps/FaceIDApp/FaceIDApp.entitlements" \
    "$DIST/FaceID.app"

codesign --verify --strict "$DIST/FaceIDAgent"
codesign --verify --strict "$DIST/FaceIDBroker"

# The VM-only forced-match test mode (ForcedMatchTestMode.swift) must never ship in a release build.
FORCED_MATCH_MARKER="FACEID-FORCED-MATCH-VM-TEST"
if grep -aq "$FORCED_MATCH_MARKER" "$DIST/FaceIDAgent"; then
    if [[ "$CONFIGURATION" == "release" ]]; then
        rm -rf "$DIST"
        echo "error: release agent contains the forced-match test mode — refusing" >&2
        exit 1
    fi
    echo "note: debug agent contains the VM-only forced-match test mode (off unless enabled in a VM)"
fi
codesign --verify --strict --deep "$DIST/FaceID.app"

# The face embedding model, if it has been converted (see Models/README.md).
if [[ -d "$ROOT/Models/FaceEmbedding.mlpackage" ]]; then
    xcrun coremlcompiler compile "$ROOT/Models/FaceEmbedding.mlpackage" "$DIST" >/dev/null
    echo "ok: compiled $DIST/FaceEmbedding.mlmodelc"
else
    echo "note: no Models/FaceEmbedding.mlpackage yet — face unlock stays unavailable (see Models/README.md)"
fi

# The plugin is built last: it pins the cdhash of the broker signed above.
BROKER_CDHASH="$(codesign -dvvv "$DIST/FaceIDBroker" 2>&1 | sed -n 's/^CDHash=//p')"
SIGN_IDENTITY="$IDENTITY" BROKER_CDHASH="$BROKER_CDHASH" "$ROOT/Scripts/build-plugin.sh" "$DIST"

for name in Agent Broker; do
    lower="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
    if /usr/bin/sandbox-exec -f "$DIST/$lower.sb" "$DIST/FaceID$name" --check-isolation; then
        echo "ok: $lower network isolation verified"
    else
        echo "error: $lower is not network-isolated under $lower.sb" >&2
        exit 1
    fi
done

echo "built: $DIST/FaceID.app, $DIST/FaceIDAgent, $DIST/FaceIDBroker and $DIST/FaceIDAuthPlugin.bundle (signed with: $IDENTITY, $CONFIGURATION)"
