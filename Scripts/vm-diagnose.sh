#!/bin/bash
# Read-only status report for testing in a VM. Changes nothing; needs no sudo.
#
#   Scripts/vm-diagnose.sh            # status + recent agent/broker/plugin log lines
#   Scripts/vm-diagnose.sh --follow   # then keep streaming the log (lock the screen now)
#
# From the host: ssh -t <user>@<vm-ip> '~/FaceID/Scripts/vm-diagnose.sh --follow'
set -uo pipefail

readonly PREDICATE='subsystem == "com.example.faceid"'

section() { printf '\n=== %s ===\n' "$1"; }

section "agent (gui/$(id -u))"
launchctl print "gui/$(id -u)/com.example.faceid.agent" 2>/dev/null | grep -E "^\s*(state|pid) =" || echo "not loaded"

section "broker (system)"
launchctl print system/com.example.faceid.broker 2>/dev/null | grep -E "^\s*(state|pid) =" || echo "not loaded"

section "screen-unlock rule"
security authorizationdb read system.login.screensaver 2>/dev/null | plutil -extract rule json -o - - 2>/dev/null || echo "unreadable"

section "last 15 minutes: registration and connections"
log show --last 15m --style compact --predicate "$PREDICATE" 2>/dev/null \
    | grep -E "registered|refused|lost the broker|accepted|no agent|verifying the broker|loaded|finished|xpc error" \
    | tail -25

if [[ "${1:-}" == "--follow" ]]; then
    section "streaming (lock the VM screen with ctrl-cmd-Q, unlock with the password; ctrl-C to stop)"
    log stream --style compact --predicate "$PREDICATE"
fi
