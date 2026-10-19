#!/bin/bash
# Builds the plugin and runs it under a fake authorization engine (PluginHarness).
# Safe on the main Mac: no sudo, no SecurityAgent, no authorizationdb, no camera.
#
#   Scripts/test-plugin.sh            # signed with "FaceID Local Signing" if present, else ad-hoc
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build/plugin-test"
mkdir -p "$WORK"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    if security find-certificate -c "FaceID Local Signing" >/dev/null 2>&1; then
        export SIGN_IDENTITY="FaceID Local Signing"
    else
        export SIGN_IDENTITY="-"
        echo "note: no signing certificate; testing the ad-hoc (cannot-verify-agent) path"
    fi
fi

"$ROOT/Scripts/build-plugin.sh" "$WORK"

xcrun clang -fobjc-arc -O0 -g -Wall -Wextra -Werror -Wno-unused-parameter \
    -mmacosx-version-min=14.0 \
    -framework Foundation -framework Security \
    -o "$WORK/PluginHarness" \
    "$ROOT/Plugins/FaceIDAuthPlugin/Tests/PluginHarness.m"

LOG="$WORK/plugin.log"
/usr/bin/log stream --style compact --level info --predicate 'subsystem == "com.example.faceid"' > "$LOG" 2>&1 &
LOG_PID=$!
trap 'kill $LOG_PID 2>/dev/null || true' EXIT
/bin/sleep 2

"$WORK/PluginHarness" "$WORK/FaceIDAuthPlugin.bundle"
/bin/sleep 1
kill $LOG_PID 2>/dev/null || true

# A certificate-signed plugin must pin the certificate and turn agent verification on.
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    if /usr/libexec/PlistBuddy -c 'Print :FaceIDAgentCertificateSHA1' "$WORK/FaceIDAuthPlugin.bundle/Contents/Info.plist" >/dev/null 2>&1; then
        echo "  ok   certificate pinned in Info.plist"
    else
        echo "  FAIL certificate is not pinned in Info.plist" >&2
        exit 1
    fi
    if grep -q "broker verification on" "$LOG"; then
        echo "  ok   signed plugin verifies the broker (dlopen-loaded)"
    else
        echo "  FAIL signed plugin could not read its own signature:" >&2
        grep "signing:" "$LOG" >&2 || true
        exit 1
    fi
fi
