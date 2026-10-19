#!/bin/bash
# FaceID installer.
#
#   sudo Scripts/install.sh                     # agent + menu bar app (no authorizationdb change)
#   sudo Scripts/install.sh --with-plugin       # also the lock-screen plugin — VM only (CLAUDE.md §5)
#   sudo Scripts/install.sh --with-plugin --allow-host   # after it passed in a VM
#
# Build first with Scripts/build-app.sh. Undo with:
#   sudo "/Library/Application Support/FaceID/uninstall.sh"
#
# Safety rules (CLAUDE.md §7):
#   * every change happens after all checks pass; nothing is touched if a check fails
#   * authorizationdb rules are backed up before any change; the first clean backup is kept forever
#   * a failure after authorizationdb was changed restores it immediately
#   * the password always keeps working: FaceID is installed disabled
#
# Compatible with the macOS system bash (3.2).
set -euo pipefail
umask 022

readonly ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly DIST="$ROOT/dist"
readonly SUPPORT="/Library/Application Support/FaceID"
readonly BACKUP_DIR="$SUPPORT/backup"
readonly STATE_DIR="$SUPPORT/state"
readonly AGENT_LABEL="com.example.faceid.agent"
readonly LAUNCH_AGENT="/Library/LaunchAgents/$AGENT_LABEL.plist"
readonly APP_DEST="/Applications/FaceID.app"
# Relays lock-screen scan requests to the user's agent (system-wide, so the plugin host can reach it).
readonly BROKER_LABEL="com.example.faceid.broker"
readonly LAUNCH_DAEMON="/Library/LaunchDaemons/$BROKER_LABEL.plist"
readonly PLUGIN_NAME="FaceIDAuthPlugin.bundle"
readonly PLUGIN_DEST="/Library/Security/SecurityAgentPlugins/$PLUGIN_NAME"
# Written only after the plugin has been prototyped in a VM; until then --with-plugin refuses.
readonly PLUGIN_RULE="$ROOT/Plugins/FaceIDAuthPlugin/screensaver-rule.plist"
# Right referenced by PLUGIN_RULE; it runs the FaceIDAuthPlugin:face mechanism.
readonly FACE_RIGHT="com.example.faceid.face"
readonly FACE_RIGHT_FILE="$ROOT/Plugins/FaceIDAuthPlugin/face-right.plist"
readonly AUTH_RULES="system.login.screensaver"
readonly PLUGIN_MARKER="FaceIDAuthPlugin"

log() { echo "==> $*"; }
warn() { echo "warning: $*" >&2; }
die() { echo "error: $*" >&2; exit 1; }

with_plugin=false
allow_host=false
for arg in "$@"; do
    case "$arg" in
        --with-plugin) with_plugin=true ;;
        --allow-host) allow_host=true ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) die "unknown option: $arg" ;;
    esac
done

# ---------------------------------------------------------------------------
# Preflight — read-only checks. Nothing on the system changes in this section.
# ---------------------------------------------------------------------------

[[ $EUID -eq 0 ]] || die "run with sudo"
user="${SUDO_USER:-}"
[[ -n "$user" && "$user" != "root" ]] || die "run via sudo from the account that will use FaceID"
uid="$(id -u "$user")"

for path in "$DIST/FaceIDAgent" "$DIST/FaceID.app" "$DIST/agent.sb" "$DIST/FaceIDBroker" "$DIST/broker.sb"; do
    [[ -e "$path" ]] || die "missing $path — run Scripts/build-app.sh first"
done
for path in "$ROOT/LaunchAgents/$AGENT_LABEL.plist" "$ROOT/LaunchDaemons/$BROKER_LABEL.plist" \
    "$ROOT/Scripts/uninstall.sh" "$ROOT/Scripts/recovery.md"; do
    [[ -f "$path" ]] || die "missing $path"
done

# Prints the uppercase SHA-1 of a binary's leaf signing certificate; empty when ad-hoc.
leaf_certificate_sha1() {
    local tmp
    tmp="$(mktemp -d)"
    codesign -d --extract-certificates="$tmp/cert" "$1" >/dev/null 2>&1 || true
    if [[ -f "$tmp/cert0" ]]; then
        shasum -a 1 "$tmp/cert0" | awk '{ print toupper($1) }'
    fi
    rm -rf "$tmp"
}

# Uppercase cdhash of a signed binary.
code_hash() {
    codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p' | tr '[:lower:]' '[:upper:]'
}

signing_identifier() {
    codesign -dv "$1" 2>&1 | sed -n 's/^Identifier=//p'
}

require_signed() {
    local path="$1" identifier="$2"
    codesign --verify --strict --deep "$path" || die "$path: invalid signature"
    [[ "$(signing_identifier "$path")" == "$identifier" ]] || die "$path: expected identifier $identifier"
    # Capture first: with pipefail, `codesign | grep -q` can fail when grep exits early.
    local details
    details="$(codesign -d --verbose=2 "$path" 2>&1)"
    [[ "$details" =~ flags=0x[0-9a-f]+\([^\)]*runtime ]] || die "$path: hardened runtime is not enabled"
}

require_signed "$DIST/FaceIDAgent" "com.example.faceid.agent"
require_signed "$DIST/FaceID.app" "com.example.faceid.app"
require_signed "$DIST/FaceIDBroker" "com.example.faceid.broker"
# The broker is ad-hoc by design and verified everywhere by its code hash (see build-app.sh).
[[ "$(codesign -dv "$DIST/FaceIDBroker" 2>&1)" == *"Signature=adhoc"* ]] \
    || die "the broker must be ad-hoc signed — rebuild with Scripts/build-app.sh"
broker_cdhash="$(code_hash "$DIST/FaceIDBroker")"
[[ "$broker_cdhash" =~ ^[0-9A-F]{40}$ ]] || die "cannot read the broker's code hash"

certificate="$(leaf_certificate_sha1 "$DIST/FaceIDAgent")"
[[ -n "$certificate" ]] || die "the agent is ad-hoc signed — sign it with your certificate (docs/local-signing.md)"
[[ "$(leaf_certificate_sha1 "$DIST/FaceID.app")" == "$certificate" ]] \
    || die "the app and the agent are signed with different certificates"

/usr/bin/sandbox-exec -f "$DIST/agent.sb" "$DIST/FaceIDAgent" --check-isolation \
    || die "the agent is not network-isolated under agent.sb"
/usr/bin/sandbox-exec -f "$DIST/broker.sb" "$DIST/FaceIDBroker" --check-isolation \
    || die "the broker is not network-isolated under broker.sb"
plutil -lint "$ROOT/LaunchAgents/$AGENT_LABEL.plist" >/dev/null || die "invalid LaunchAgent plist"
plutil -lint "$ROOT/LaunchDaemons/$BROKER_LABEL.plist" >/dev/null || die "invalid LaunchDaemon plist"

have_model=false
if [[ -d "$DIST/FaceEmbedding.mlmodelc" ]]; then
    have_model=true
else
    warn "no dist/FaceEmbedding.mlmodelc — face unlock stays unavailable until a model is installed"
fi

if $with_plugin; then
    [[ -d "$DIST/$PLUGIN_NAME" ]] || die "plugin bundle $DIST/$PLUGIN_NAME is not built yet"
    [[ -f "$PLUGIN_RULE" ]] \
        || die "no $PLUGIN_RULE — the plugin's authorizationdb rule must be prototyped in a VM first"
    plutil -lint "$PLUGIN_RULE" >/dev/null || die "invalid rule file $PLUGIN_RULE"
    grep -q "$FACE_RIGHT" "$PLUGIN_RULE" || die "rule file does not reference $FACE_RIGHT"
    grep -q "authenticate-session-owner-or-admin" "$PLUGIN_RULE" \
        || die "rule file has no password fallback — refusing (CLAUDE.md §1: the password must always work)"
    [[ -f "$FACE_RIGHT_FILE" ]] || die "missing $FACE_RIGHT_FILE"
    plutil -lint "$FACE_RIGHT_FILE" >/dev/null || die "invalid rule file $FACE_RIGHT_FILE"
    grep -q "$PLUGIN_MARKER:face" "$FACE_RIGHT_FILE" || die "face right does not use $PLUGIN_MARKER:face"
    codesign --verify --strict --deep "$DIST/$PLUGIN_NAME" || die "plugin: invalid signature"
    [[ "$(leaf_certificate_sha1 "$DIST/$PLUGIN_NAME")" == "$certificate" ]] \
        || die "the plugin is signed with a different certificate"
    pinned="$(/usr/libexec/PlistBuddy -c 'Print :FaceIDAgentCertificateSHA1' "$DIST/$PLUGIN_NAME/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$pinned" == "$certificate" ]] \
        || die "the plugin does not pin the agent's certificate — rebuild it with Scripts/build-plugin.sh"
    # The plugin verifies the broker by its exact code hash (certificates cannot be checked at the lock screen).
    pinned_broker="$(/usr/libexec/PlistBuddy -c 'Print :FaceIDBrokerCDHash' "$DIST/$PLUGIN_NAME/Contents/Info.plist" 2>/dev/null || true)"
    [[ -n "$pinned_broker" && "$pinned_broker" == "$broker_cdhash" ]] \
        || die "the plugin does not pin this broker build — rebuild everything with Scripts/build-app.sh"

    if [[ "$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)" != "1" ]] && ! $allow_host; then
        die "refusing to change authorizationdb outside a VM. Test in a VM first, then pass --allow-host"
    fi
    echo
    echo "This changes the '$AUTH_RULES' authorization rule (screen unlock)."
    echo "Before continuing, make sure you can recover: read $ROOT/Scripts/recovery.md"
    echo "and enable Remote Login (SSH) or have a second admin account."
    read -r -p "Type INSTALL PLUGIN to continue: " answer
    [[ "$answer" == "INSTALL PLUGIN" ]] || die "cancelled"
fi

# ---------------------------------------------------------------------------
# Backup — always, before any change.
# ---------------------------------------------------------------------------

install -d -o root -g wheel -m 755 "$SUPPORT"
install -d -o root -g wheel -m 700 "$BACKUP_DIR"
stamp="$(date +%Y%m%d-%H%M%S)"
snapshot="$BACKUP_DIR/$stamp"
install -d -o root -g wheel -m 700 "$snapshot"

for rule in $AUTH_RULES; do
    security authorizationdb read "$rule" > "$snapshot/$rule.plist" 2>/dev/null \
        || die "could not back up authorization rule $rule"
    plutil -lint "$snapshot/$rule.plist" >/dev/null || die "backup of $rule is not a valid plist"
done
chmod 600 "$snapshot"/*.plist

# The first backup taken before FaceID ever touched the rules is the one uninstall restores.
if [[ ! -d "$BACKUP_DIR/original" ]]; then
    if grep -q "$PLUGIN_MARKER" "$snapshot"/*.plist; then
        die "the current rules already reference $PLUGIN_MARKER; no clean original to keep. See recovery.md"
    fi
    cp -Rp "$snapshot" "$BACKUP_DIR/original"
    log "kept original authorization rules in $BACKUP_DIR/original"
fi
log "backed up authorization rules to $snapshot"

# ---------------------------------------------------------------------------
# Rollback — if anything fails after authorizationdb changed, restore it.
# ---------------------------------------------------------------------------

authdb_changed=false
rollback() {
    local status=$?
    trap - EXIT
    if [[ $status -ne 0 ]]; then
        warn "installation failed (exit $status)"
        if $authdb_changed; then
            warn "restoring authorization rules from $BACKUP_DIR/original"
            for rule in $AUTH_RULES; do
                security authorizationdb write "$rule" < "$BACKUP_DIR/original/$rule.plist" \
                    || warn "could not restore $rule — follow recovery.md NOW"
            done
            security authorizationdb remove "$FACE_RIGHT" >/dev/null 2>&1 || true
            rm -rf "$PLUGIN_DEST"
            rm -f "$STATE_DIR/plugin-installed"
        fi
        warn "files may be partly installed; remove them with: sudo \"$SUPPORT/uninstall.sh\""
    fi
    exit $status
}
trap rollback EXIT

# ---------------------------------------------------------------------------
# Install files — root-owned, so user processes cannot swap the binaries.
# ---------------------------------------------------------------------------

install -d -o root -g wheel -m 755 "$SUPPORT/Models" "$STATE_DIR"
install -o root -g wheel -m 755 "$DIST/FaceIDAgent" "$SUPPORT/FaceIDAgent"
install -o root -g wheel -m 644 "$DIST/agent.sb" "$SUPPORT/agent.sb"
install -o root -g wheel -m 755 "$DIST/FaceIDBroker" "$SUPPORT/FaceIDBroker"
install -o root -g wheel -m 644 "$DIST/broker.sb" "$SUPPORT/broker.sb"
install -o root -g wheel -m 755 "$ROOT/Scripts/uninstall.sh" "$SUPPORT/uninstall.sh"
install -o root -g wheel -m 644 "$ROOT/Scripts/recovery.md" "$SUPPORT/recovery.md"

if $have_model; then
    rm -rf "$SUPPORT/Models/FaceEmbedding.mlmodelc"
    ditto "$DIST/FaceEmbedding.mlmodelc" "$SUPPORT/Models/FaceEmbedding.mlmodelc"
    chown -R root:wheel "$SUPPORT/Models"
    chmod -R go-w "$SUPPORT/Models"
fi

# A running copy of the old app would fail the agent's signature check once its file is replaced.
pkill -x -u "$uid" FaceIDApp 2>/dev/null || true
rm -rf "$APP_DEST"
ditto "$DIST/FaceID.app" "$APP_DEST"
chown -R root:wheel "$APP_DEST"
chmod -R go-w "$APP_DEST"

install -o root -g wheel -m 644 "$ROOT/LaunchAgents/$AGENT_LABEL.plist" "$LAUNCH_AGENT"
install -o root -g wheel -m 644 "$ROOT/LaunchDaemons/$BROKER_LABEL.plist" "$LAUNCH_DAEMON"

# Copying must not have broken the signatures.
codesign --verify --strict "$SUPPORT/FaceIDAgent" || die "installed agent signature is invalid"
codesign --verify --strict "$SUPPORT/FaceIDBroker" || die "installed broker signature is invalid"
[[ "$(code_hash "$SUPPORT/FaceIDBroker")" == "$broker_cdhash" ]] || die "installed broker does not match the built one"

# What the agent and the broker require of each other (root-owned; both refuse it otherwise).
pins_tmp="$(mktemp)"
plutil -create xml1 "$pins_tmp"
plutil -insert BrokerCDHash -string "$broker_cdhash" "$pins_tmp"
plutil -insert AgentCertificateSHA1 -string "$certificate" "$pins_tmp"
install -o root -g wheel -m 644 "$pins_tmp" "$SUPPORT/pins.plist"
rm -f "$pins_tmp"
plutil -lint "$SUPPORT/pins.plist" >/dev/null || die "invalid pins file"
codesign --verify --strict --deep "$APP_DEST" || die "installed app signature is invalid"
log "installed agent, broker, app, LaunchAgent and LaunchDaemon"

# ---------------------------------------------------------------------------
# Start the broker (system domain), then the agent in the user's GUI session.
# The agent registers with the broker on start and retries if the broker is not up yet.
# ---------------------------------------------------------------------------

# Stops a launchd job and (re)loads it. `bootstrap` right after `bootout` fails with
# "5: Input/output error" while launchd is still tearing the old job down, so wait and retry.
reload_job() {
    local domain="$1" label="$2" plist="$3" attempt
    launchctl bootout "$domain/$label" 2>/dev/null || true
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        launchctl print "$domain/$label" >/dev/null 2>&1 || break
        /bin/sleep 0.5
    done
    for attempt in 1 2 3 4 5; do
        if launchctl bootstrap "$domain" "$plist" 2>/dev/null; then
            launchctl print "$domain/$label" >/dev/null 2>&1 && return 0
        fi
        /bin/sleep 1
    done
    return 1
}

reload_job system "$BROKER_LABEL" "$LAUNCH_DAEMON" || die "could not load the broker"
log "broker loaded"

reload_job "gui/$uid" "$AGENT_LABEL" "$LAUNCH_AGENT" || die "could not load the agent for $user"
log "agent loaded for $user"

# ---------------------------------------------------------------------------
# Lock-screen plugin (optional, VM first).
# ---------------------------------------------------------------------------

if $with_plugin; then
    install -d -o root -g wheel -m 755 "$(dirname "$PLUGIN_DEST")"
    rm -rf "$PLUGIN_DEST"
    ditto "$DIST/$PLUGIN_NAME" "$PLUGIN_DEST"
    chown -R root:wheel "$PLUGIN_DEST"
    chmod -R go-w "$PLUGIN_DEST"
    codesign --verify --strict --deep "$PLUGIN_DEST" || die "installed plugin signature is invalid"

    # Marker first, so uninstall knows to restore even if we are interrupted mid-write.
    touch "$STATE_DIR/plugin-installed"
    authdb_changed=true
    # The face right must exist before the screensaver rule points at it.
    security authorizationdb write "$FACE_RIGHT" < "$FACE_RIGHT_FILE"
    security authorizationdb read "$FACE_RIGHT" >/dev/null 2>&1 || die "the face right was not created"
    security authorizationdb write system.login.screensaver < "$PLUGIN_RULE"
    current_rule="$(security authorizationdb read system.login.screensaver 2>/dev/null)"
    [[ "$current_rule" == *"$FACE_RIGHT"* ]] || die "the screensaver rule did not take effect"
    log "lock-screen plugin installed"
fi

echo "$stamp" > "$STATE_DIR/installed"
trap - EXIT

cat <<EOF

FaceID is installed. Your password keeps working as before.
Face unlock keeps its previous on/off setting (off after a first install).
Next:
  1. Open /Applications/FaceID.app (menu bar).
  2. First install: read the warning and enroll your face, then turn on "ใช้ใบหน้าปลดล็อก".
     After an update: if the app asks, press "อนุญาต" and choose Always Allow (no re-enrollment needed).
Uninstall:  sudo "$SUPPORT/uninstall.sh"
Recovery:   $SUPPORT/recovery.md
EOF
