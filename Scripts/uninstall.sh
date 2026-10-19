#!/bin/bash
# FaceID uninstaller. Also installed at "/Library/Application Support/FaceID/uninstall.sh".
#
#   sudo uninstall.sh                         # restore authorizationdb, remove everything, delete face data
#   sudo uninstall.sh --restore-authdb-only   # emergency: only put the screen-unlock rule back (works over SSH)
#   sudo uninstall.sh --keep-face-data        # keep the encrypted template in the keychain
#   sudo uninstall.sh --purge-backups         # also delete the authorizationdb backups
#
# Order matters: the authorization rule is restored BEFORE the plugin is removed, so the
# lock screen never points at a plugin that no longer exists. Every step tolerates
# "already gone", so running it twice is safe.
#
# Compatible with the macOS system bash (3.2).
set -uo pipefail

readonly SUPPORT="/Library/Application Support/FaceID"
readonly BACKUP_DIR="$SUPPORT/backup"
readonly STATE_DIR="$SUPPORT/state"
readonly AGENT_LABEL="com.example.faceid.agent"
readonly LAUNCH_AGENT="/Library/LaunchAgents/$AGENT_LABEL.plist"
readonly APP_DEST="/Applications/FaceID.app"
readonly BROKER_LABEL="com.example.faceid.broker"
readonly LAUNCH_DAEMON="/Library/LaunchDaemons/$BROKER_LABEL.plist"
readonly PLUGIN_DEST="/Library/Security/SecurityAgentPlugins/FaceIDAuthPlugin.bundle"
readonly AUTH_RULES="system.login.screensaver"
readonly PLUGIN_MARKER="FaceIDAuthPlugin"
# Rules written by install.sh reference this right (and through it, the plugin).
readonly FACE_RIGHT="com.example.faceid.face"
readonly KEYCHAIN_SERVICE="com.example.faceid"
readonly KEYCHAIN_ACCOUNTS="template template-key.secure-enclave template-key.software"
readonly PREFERENCES_DOMAIN="com.example.faceid"

log() { echo "==> $*"; }
warn() { echo "warning: $*" >&2; problems=$((problems + 1)); }
die() { echo "error: $*" >&2; exit 1; }
problems=0

restore_only=false
keep_face_data=false
purge_backups=false
for arg in "$@"; do
    case "$arg" in
        --restore-authdb-only) restore_only=true ;;
        --keep-face-data) keep_face_data=true ;;
        --purge-backups) purge_backups=true ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) die "unknown option: $arg" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "run with sudo"

# Removes a path only if it is one of ours — guards against an empty or wrong variable.
safe_remove() {
    local path="$1"
    case "$path" in
        "$SUPPORT"/*|"$APP_DEST"|"$LAUNCH_AGENT"|"$LAUNCH_DAEMON"|"$PLUGIN_DEST") ;;
        *) warn "refusing to remove unexpected path: $path"; return ;;
    esac
    if [[ -e "$path" || -L "$path" ]]; then
        rm -rf "$path" && log "removed $path" || warn "could not remove $path"
    fi
}

rule_references_plugin() {
    local text
    text="$(security authorizationdb read "$1" 2>/dev/null)"
    [[ "$text" == *"$PLUGIN_MARKER"* || "$text" == *"$FACE_RIGHT"* ]]
}

face_right_exists() {
    security authorizationdb read "$FACE_RIGHT" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 1. Authorization rules — the step that matters most for not being locked out.
# ---------------------------------------------------------------------------

restore_authdb() {
    local rule original needs_restore=false
    for rule in $AUTH_RULES; do
        if [[ -f "$STATE_DIR/plugin-installed" ]] || rule_references_plugin "$rule"; then
            needs_restore=true
        fi
    done
    face_right_exists && needs_restore=true
    if ! $needs_restore; then
        log "authorization rules were not changed by FaceID"
        return 0
    fi

    for rule in $AUTH_RULES; do
        original="$BACKUP_DIR/original/$rule.plist"
        if [[ ! -f "$original" ]]; then
            echo "error: no original backup for $rule. Follow recovery.md section 'ไม่มีไฟล์ backup'" >&2
            return 1
        fi
        if grep -q -e "$PLUGIN_MARKER" -e "$FACE_RIGHT" "$original"; then
            echo "error: the backup of $rule references $PLUGIN_MARKER; refusing to restore it. See recovery.md" >&2
            return 1
        fi
        if ! security authorizationdb write "$rule" < "$original"; then
            echo "error: could not restore $rule. See recovery.md" >&2
            return 1
        fi
        if rule_references_plugin "$rule"; then
            echo "error: $rule still references $PLUGIN_MARKER after restore. See recovery.md" >&2
            return 1
        fi
        log "restored $rule from $original"
    done

    # Only now that nothing points at it, remove the face right.
    if face_right_exists; then
        if ! security authorizationdb remove "$FACE_RIGHT" >/dev/null 2>&1 || face_right_exists; then
            echo "error: could not remove the $FACE_RIGHT right (screen unlock is already restored)" >&2
            return 1
        fi
        log "removed the $FACE_RIGHT right"
    fi
    rm -f "$STATE_DIR/plugin-installed"
}

if ! restore_authdb; then
    die "authorization rules NOT restored; nothing else was removed"
fi

if $restore_only; then
    log "done (authorization rules only). Run again without --restore-authdb-only to remove FaceID"
    exit 0
fi

# ---------------------------------------------------------------------------
# 2. Plugin, agent, app.
# ---------------------------------------------------------------------------

safe_remove "$PLUGIN_DEST"

# Every user with a GUI session runs a loginwindow process as that user.
gui_uids="$(ps -axo uid=,comm= | awk '$2 ~ /loginwindow$/ { print $1 }' | sort -u)"
for uid in $gui_uids; do
    if launchctl print "gui/$uid/$AGENT_LABEL" >/dev/null 2>&1; then
        launchctl bootout "gui/$uid/$AGENT_LABEL" && log "stopped agent for uid $uid" \
            || warn "could not stop the agent for uid $uid"
    fi
done
safe_remove "$LAUNCH_AGENT"

if launchctl print "system/$BROKER_LABEL" >/dev/null 2>&1; then
    launchctl bootout "system/$BROKER_LABEL" && log "stopped the broker" || warn "could not stop the broker"
fi
safe_remove "$LAUNCH_DAEMON"
pkill -x FaceIDApp 2>/dev/null || true
safe_remove "$APP_DEST"

# ---------------------------------------------------------------------------
# 3. Face data (encrypted template + its key), preferences, camera permission.
# ---------------------------------------------------------------------------

users=""
[[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && users="$SUDO_USER"
for uid in $gui_uids; do
    name="$(id -nu "$uid" 2>/dev/null || true)"
    [[ -n "$name" && "$name" != "root" && " $users " != *" $name "* ]] && users="$users $name"
done

for name in $users; do
    if ! $keep_face_data; then
        for account in $KEYCHAIN_ACCOUNTS; do
            # The item may not exist; deleting the key alone already makes the template unreadable.
            sudo -u "$name" security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$account" >/dev/null 2>&1 || true
        done
        remaining="$(sudo -u "$name" security find-generic-password -s "$KEYCHAIN_SERVICE" 2>/dev/null || true)"
        if [[ -n "$remaining" ]]; then
            warn "face data for $name is still in the keychain (locked keychain?). Delete it from the FaceID app or Keychain Access ($KEYCHAIN_SERVICE)"
        else
            log "deleted face data for $name"
        fi
    fi
    sudo -u "$name" defaults delete "$PREFERENCES_DOMAIN" >/dev/null 2>&1 || true
    sudo -u "$name" tccutil reset Camera "$AGENT_LABEL" >/dev/null 2>&1 || true
done

# ---------------------------------------------------------------------------
# 4. Support files. Backups stay unless --purge-backups.
# ---------------------------------------------------------------------------

if [[ -d "$SUPPORT" ]]; then
    for item in "$SUPPORT"/* "$SUPPORT"/.[!.]*; do
        [[ -e "$item" ]] || continue
        if [[ "$item" == "$BACKUP_DIR" ]] && ! $purge_backups; then
            continue
        fi
        safe_remove "$item"
    done
    if $purge_backups; then
        rmdir "$SUPPORT" 2>/dev/null && log "removed $SUPPORT"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Verify.
# ---------------------------------------------------------------------------

for path in "$PLUGIN_DEST" "$LAUNCH_AGENT" "$LAUNCH_DAEMON" "$APP_DEST" "$SUPPORT/FaceIDAgent" "$SUPPORT/FaceIDBroker"; do
    [[ -e "$path" ]] && warn "still present: $path"
done
for rule in $AUTH_RULES; do
    rule_references_plugin "$rule" && warn "$rule still references FaceID"
done
face_right_exists && warn "the $FACE_RIGHT right still exists"

if [[ $problems -eq 0 ]]; then
    log "FaceID removed. Screen unlock uses the password only."
    $purge_backups || log "authorization backups kept in $BACKUP_DIR"
else
    echo "FaceID removed with $problems warning(s) above." >&2
    exit 1
fi
