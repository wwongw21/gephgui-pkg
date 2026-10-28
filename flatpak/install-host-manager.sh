#!/bin/sh
# Privileged Flatpak host-manager installer. The second argument is retained
# for the GUI bootstrap contract; the validated data-directory owner is
# recorded, but app-data existence never triggers manager cleanup.
#
# Usage: install-host-manager.sh <staging-dir> <flatpak-app-data-dir>
set -eu

STAGING="$1"
OWNER_DATA="$2"
BINDIR=/usr/local/bin
STATE_DIR=/var/lib/geph-flatpak
IDENTITY="$STATE_DIR/manager.identity"
LOCK_DIR="$STATE_DIR/lifecycle.lock"
SERVICE=/etc/systemd/system/geph-manager.service
OTHER_SERVICE_DIRS="/usr/lib/systemd/system /lib/systemd/system /run/systemd/system"
LEGACY_SERVICE=/etc/systemd/system/geph-cleanup.service
LEGACY_TIMER=/etc/systemd/system/geph-cleanup.timer
LEGACY_WATCHDOG="$BINDIR/geph-flatpak-watchdog"
SYSTEMCTL=/usr/bin/systemctl

fail() {
    printf 'Geph Flatpak installer: %s\n' "$*" >&2
    exit 1
}

case "${PKEXEC_UID:-}" in ''|*[!0-9]*) fail 'pkexec did not supply a valid caller UID' ;; esac
OWNER_UID="$PKEXEC_UID"
[ -d "$STAGING" ] && [ ! -L "$STAGING" ] || fail 'staging directory is missing or redirected'
[ -d "$OWNER_DATA" ] && [ ! -L "$OWNER_DATA" ] || fail 'Flatpak app-data directory is missing or redirected'
OWNER_DATA_UID="$(stat -c %u "$OWNER_DATA")" || fail 'could not identify the Flatpak data owner'
[ "$OWNER_DATA_UID" = "$OWNER_UID" ] || fail 'Flatpak data owner does not match the pkexec caller'

for asset in geph5 geph5-client geph-flatpak-watchdog.sh geph-cleanup.service geph-cleanup.timer; do
    [ -f "$STAGING/$asset" ] && [ ! -L "$STAGING/$asset" ] || fail "required staging asset is missing: $asset"
done
HMO_LIBRARY_ONLY=1
. "$STAGING/geph-flatpak-watchdog.sh"
unset HMO_LIBRARY_ONLY

for directory in "$BINDIR" /etc/systemd/system; do
    if [ ! -e "$directory" ]; then install -d -o root -g root -m 0755 "$directory"; fi
    hmo_require_root_owned "$directory" dir || fail "directory is not root-owned and protected: $directory"
done
if [ ! -e "$STATE_DIR" ]; then install -d -o root -g root -m 0755 "$STATE_DIR"; fi
hmo_require_root_owned "$STATE_DIR" dir || fail 'ownership directory is not root-owned and protected'
[ -x "$SYSTEMCTL" ] || fail 'systemctl is unavailable'
hmo_acquire_lifecycle_lock "$LOCK_DIR" || fail 'could not acquire the host-manager lifecycle lock'
hmo_require_root_owned "$LOCK_DIR" dir || fail 'lifecycle lock is not root-owned and protected'
hmo_require_root_owned "$LOCK_DIR/pid" file || fail 'lifecycle lock owner record is not root-owned and protected'
HMO_INSTALL_TXN_ACTIVE=0
hmo_installer_exit() {
    HMO_INSTALL_EXIT_STATUS="$1"
    trap - EXIT HUP INT TERM
    if [ "$HMO_INSTALL_EXIT_STATUS" -ne 0 ] && [ "${HMO_INSTALL_TXN_ACTIVE:-0}" = 1 ]; then
        hmo_restore_install_transaction "$STATE_DIR" "$BINDIR" "$SERVICE" "$SYSTEMCTL" ||
            printf '%s\n' 'Geph Flatpak installer: rollback is incomplete; retry the install or explicit uninstall to recover.' >&2
    fi
    hmo_release_lifecycle_lock
    exit "$HMO_INSTALL_EXIT_STATUS"
}
trap 'hmo_installer_exit $?' EXIT
trap 'exit 1' HUP INT TERM
hmo_restore_install_transaction "$STATE_DIR" "$BINDIR" "$SERVICE" "$SYSTEMCTL" || fail 'could not recover the previous install transaction; manager retained'
for unit_dir in $OTHER_SERVICE_DIRS; do
    unit="$unit_dir/geph-manager.service"
    if [ -e "$unit" ] || [ -L "$unit" ]; then
        fail "a Geph manager unit exists outside the Flatpak-owned path: $unit"
    fi
done

# Migrate the old timer only when its unit identity proves it came from this
# Flatpak package. Replace its worker with a no-op before stopping the timer.
LEGACY_OWNED=0
if [ -e "$LEGACY_SERVICE" ] || [ -L "$LEGACY_SERVICE" ] || [ -e "$LEGACY_TIMER" ] || [ -L "$LEGACY_TIMER" ] || [ -e "$LEGACY_WATCHDOG" ] || [ -L "$LEGACY_WATCHDOG" ]; then
    [ -f "$LEGACY_SERVICE" ] && [ ! -L "$LEGACY_SERVICE" ] || fail 'legacy cleanup service state is incomplete or redirected'
    [ -f "$LEGACY_TIMER" ] && [ ! -L "$LEGACY_TIMER" ] || fail 'legacy cleanup timer state is incomplete or redirected'
    hmo_require_root_owned "$LEGACY_SERVICE" file || fail 'legacy cleanup service is not root-owned'
    hmo_require_root_owned "$LEGACY_TIMER" file || fail 'legacy cleanup timer is not root-owned'
    grep -Fq "$LEGACY_WATCHDOG" "$LEGACY_SERVICE" || fail 'legacy cleanup service does not match the old Flatpak watchdog'
    grep -Fq 'Periodically check whether the Geph Flatpak was uninstalled' "$LEGACY_TIMER" || fail 'legacy cleanup timer identity is unknown'
    if [ -e "$LEGACY_WATCHDOG" ] || [ -L "$LEGACY_WATCHDOG" ]; then
        hmo_require_root_owned "$LEGACY_WATCHDOG" file || fail 'legacy watchdog is not root-owned'
    fi
    if [ -e "$SERVICE" ] || [ -L "$SERVICE" ]; then
        hmo_require_root_owned "$SERVICE" file || fail 'manager service is not root-owned'
        grep -Fq "ExecStart=$BINDIR/geph5 manager" "$SERVICE" || fail 'manager service points at an unrelated executable'
    fi
    for binary in "$BINDIR/geph5" "$BINDIR/geph5-client"; do
        if [ -e "$binary" ] || [ -L "$binary" ]; then
            hmo_require_root_owned "$binary" file || fail "legacy manager binary is not root-owned: $binary"
        fi
    done
    cat > "$LEGACY_WATCHDOG" <<'NOOP_EOF'
#!/bin/sh
echo 'Automatic Geph host-manager cleanup is disabled; use the explicit owner action.' >&2
exit 0
NOOP_EOF
    chmod 0755 "$LEGACY_WATCHDOG"
    chown root:root "$LEGACY_WATCHDOG"
    "$SYSTEMCTL" disable --now geph-cleanup.timer || fail 'could not stop the legacy cleanup timer; retry after checking systemd'
    rm -f "$LEGACY_SERVICE" "$LEGACY_TIMER" "$LEGACY_WATCHDOG"
    "$SYSTEMCTL" daemon-reload || fail 'could not reload systemd after removing legacy cleanup units'
    LEGACY_OWNED=1
fi

if [ -e "$IDENTITY" ] || [ -L "$IDENTITY" ]; then
    hmo_require_root_owned "$IDENTITY" file || fail 'ownership record is not root-owned and protected'
    hmo_read_identity "$IDENTITY" || fail 'ownership record is corrupt; manager retained'
    [ "$HMO_STATE" = installed ] || fail 'manager removal is in progress; retry its explicit uninstall first'
    for path in "$BINDIR/geph5" "$BINDIR/geph5-client" "$SERVICE"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            hmo_require_root_owned "$path" file || fail "manager path is not root-owned and protected: $path"
        fi
    done
    hmo_check_recorded_files "$BINDIR" "$SERVICE" || fail 'manager files changed outside the recorded Flatpak identity'
    OWNERS=unknown
elif [ "$LEGACY_OWNED" -eq 1 ]; then
    # The old service stored only one app-data path, so it cannot prove which
    # other users previously shared the global manager. Keep a root-owned
    # sentinel until an administrator explicitly reconciles that old state.
    hmo_legacy_migration_owners "$OWNER_UID" || fail 'could not record the migration owner'
    OWNERS="$HMO_MIGRATION_OWNERS"
elif [ -e "$BINDIR/geph5" ] || [ -L "$BINDIR/geph5" ] || [ -e "$BINDIR/geph5-client" ] || [ -L "$BINDIR/geph5-client" ] || [ -e "$SERVICE" ] || [ -L "$SERVICE" ]; then
    fail 'a manager already exists without a Flatpak ownership record; refusing to replace it'
else
    OWNERS=unknown
fi

# Snapshot all owned targets before the first mutation. Any failed copy,
# registration or identity publication restores the previous installation;
# an interrupted process leaves a journal that the next locked operation replays.
hmo_begin_install_transaction "$STATE_DIR" "$BINDIR" "$SERVICE" || fail 'could not prepare a retry-safe install transaction'

# The manager, engine and host-uninstall command all have fixed root-owned
# paths. The uninstall command validates the record and hashes before acting.
install -m 0755 "$STAGING/geph5" "$BINDIR/geph5"
install -m 0755 "$STAGING/geph5-client" "$BINDIR/geph5-client"
install -m 0755 "$STAGING/geph-flatpak-watchdog.sh" "$BINDIR/geph-flatpak-uninstall"
"$BINDIR/geph5" register-manager
hmo_require_root_owned "$SERVICE" file || fail 'registered manager service is missing or not root-owned'
grep -Fq "ExecStart=$BINDIR/geph5 manager" "$SERVICE" || fail 'registered service points outside the Flatpak-owned manager path'
hmo_file_sha256 "$BINDIR/geph5" || fail 'could not identify installed manager'
MANAGER_SHA="$HMO_HASH_VALUE"
hmo_file_sha256 "$BINDIR/geph5-client" || fail 'could not identify installed engine'
CLIENT_SHA="$HMO_HASH_VALUE"
hmo_file_sha256 "$SERVICE" || fail 'could not identify registered manager service'
SERVICE_SHA="$HMO_HASH_VALUE"
hmo_write_identity "$IDENTITY" installed "$OWNERS" '' "$MANAGER_SHA" "$CLIENT_SHA" "$SERVICE_SHA" || fail 'could not save root-owned manager identity'
chmod 0600 "$IDENTITY"
chown root:root "$IDENTITY"
hmo_commit_install_transaction "$STATE_DIR" || fail 'could not commit the install transaction; retry to recover safely'
trap - EXIT HUP INT TERM
hmo_release_lifecycle_lock
printf 'Geph host manager is installed for Flatpak owner UID(s): %s\n' "$OWNERS"
