#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
REGISTER_RELEASE=""
UNREGISTER_RELEASE=""
installer_one=""
installer_two=""
uninstaller_pid=""
reinstaller_pid=""
lock_holder=""
cleanup_fixtures() {
    [ -z "$REGISTER_RELEASE" ] || { mkdir -p "$(dirname "$REGISTER_RELEASE")"; : > "$REGISTER_RELEASE"; }
    [ -z "$UNREGISTER_RELEASE" ] || { mkdir -p "$(dirname "$UNREGISTER_RELEASE")"; : > "$UNREGISTER_RELEASE"; }
    for process_id in "$installer_one" "$installer_two" "$uninstaller_pid" "$reinstaller_pid" "$lock_holder"; do
        [ -z "$process_id" ] || kill "$process_id" 2>/dev/null || true
    done
    sleep 0.2
    rm -rf "$TMP_ROOT"
}
trap cleanup_fixtures EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_exists() { [[ -e "$1" ]] || fail "expected file: $1"; }
assert_absent() { [[ ! -e "$1" ]] || fail "unexpected file: $1"; }

make_test_sources() {
    local root="$1" version="${2:-new}"
    mkdir -p "$root/staging" "$root/home/user" "$root/stubs" \
        "$root/usr/local/bin" "$root/var/lib/geph-flatpak" \
        "$root/usr/lib/systemd/system" "$root/lib/systemd/system" "$root/run/systemd/system" \
        "$root/etc/systemd/system"
    cat > "$root/staging/geph5" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$*" >> "$CALL_LOG"
case "$1" in
    register-manager)
        printf 'ExecStart=%s manager\n' "$GEPh5_PATH" > "$SERVICE_PATH"
        if [ "${BLOCK_REGISTER:-0}" = 1 ]; then
            : > "$REGISTER_READY"
            wait_count=0
            while [ ! -e "$REGISTER_RELEASE" ]; do
                wait_count=$((wait_count + 1))
                [ "$wait_count" -lt 500 ] || exit 98
                sleep 0.02
            done
        fi
        if [ "${FAIL_INSTALL_AT:-}" = register ] && [ ! -e "$FAIL_MARKER" ]; then
            : > "$FAIL_MARKER"
            exit 61
        fi
        ;;
    unregister-manager)
        if [ "${BLOCK_UNREGISTER:-0}" = 1 ]; then
            : > "$UNREGISTER_READY"
            wait_count=0
            while [ ! -e "$UNREGISTER_RELEASE" ]; do
                wait_count=$((wait_count + 1))
                [ "$wait_count" -lt 500 ] || exit 99
                sleep 0.02
            done
        fi
        rm -f "$SERVICE_PATH"
        ;;
esac
exit 0
EOF
    chmod 0755 "$root/staging/geph5"
    printf 'fixture geph5-client %s\n' "$version" > "$root/staging/geph5-client"
    cat > "$root/staging/geph-cleanup.service" <<'EOF'
[Unit]
Description=Geph Flatpak legacy cleanup
[Service]
ExecStart=@BINDIR@/geph-flatpak-watchdog @OWNER@ @BINDIR@
EOF
    cat > "$root/staging/geph-cleanup.timer" <<'EOF'
[Unit]
Description=Periodically check whether the Geph Flatpak was uninstalled
[Timer]
OnBootSec=3min
EOF

    # These exact fixed-path substitutions exist only in the test copy. The
    # packaged privileged script retains its literal host-owned destinations.
    sed \
        -e 's|/usr/local/bin|$HMO_FIXTURE_ROOT/usr/local/bin|g' \
        -e 's|/var/lib/geph-flatpak|$HMO_FIXTURE_ROOT/var/lib/geph-flatpak|g' \
        -e 's|/etc/systemd/system|$HMO_FIXTURE_ROOT/etc/systemd/system|g' \
        -e 's|/usr/lib/systemd/system|$HMO_FIXTURE_ROOT/usr/lib/systemd/system|g' \
        -e 's|/lib/systemd/system|$HMO_FIXTURE_ROOT/lib/systemd/system|g' \
        -e 's|/run/systemd/system|$HMO_FIXTURE_ROOT/run/systemd/system|g' \
        -e 's|/usr/bin/systemctl|$HMO_FIXTURE_ROOT/stubs/systemctl|g' \
        "$REPO_ROOT/flatpak/install-host-manager.sh" > "$root/staging/install-host-manager.sh"
    chmod 0755 "$root/staging/install-host-manager.sh"
    sed \
        -e 's|/usr/local/bin|$HMO_FIXTURE_ROOT/usr/local/bin|g' \
        -e 's|/var/lib/geph-flatpak|$HMO_FIXTURE_ROOT/var/lib/geph-flatpak|g' \
        -e 's|/etc/systemd/system|$HMO_FIXTURE_ROOT/etc/systemd/system|g' \
        -e 's|/usr/bin/systemctl|$HMO_FIXTURE_ROOT/stubs/systemctl|g' \
        "$REPO_ROOT/flatpak/geph-flatpak-watchdog.sh" > "$root/staging/geph-flatpak-watchdog.sh"
    chmod 0755 "$root/staging/geph-flatpak-watchdog.sh"
    sed 's|/usr/local/bin|$HMO_FIXTURE_ROOT/usr/local/bin|g' \
        "$REPO_ROOT/flatpak/geph-uninstall-host-manager.sh" > "$root/staging/geph-uninstall-host-manager.sh"
    chmod 0755 "$root/staging/geph-uninstall-host-manager.sh"
}

make_command_doubles() {
    local root="$1"
    cat > "$root/stubs/install" <<'EOF'
#!/bin/sh
set -eu
mode=0755
if [ "$1" = -d ]; then
    shift
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -o|-g|-m) flag="$1"; value="$2"; shift 2; [ "$flag" = -m ] && mode="$value" ;;
            *) destination="$1"; shift ;;
        esac
    done
    mkdir -p "$destination"
    chmod "$mode" "$destination"
    exit 0
fi
while [ "$#" -gt 0 ]; do
    case "$1" in
        -m) mode="$2"; shift 2 ;;
        *) source="$1"; destination="$2"; shift 2; break ;;
    esac
done
cp "$source" "$destination"
chmod "$mode" "$destination"
printf 'copy %s\n' "$(basename "$source")" >> "$INSTALL_LOG"
case "${FAIL_INSTALL_AT:-}" in
    copy1) [ "$destination" = "$HMO_FIXTURE_ROOT/usr/local/bin/geph5" ] && exit 62 ;;
    copy2) [ "$destination" = "$HMO_FIXTURE_ROOT/usr/local/bin/geph5-client" ] && exit 63 ;;
esac
exit 0
EOF
    cat > "$root/stubs/stat" <<'EOF'
#!/bin/sh
if [ "$1" = -c ] && [ "$2" = %u ]; then
    if [ "$3" = "$OWNER_DATA" ]; then printf '%s\n' "$PKEXEC_UID"; else printf '0\n'; fi
elif [ "$1" = -c ] && [ "$2" = %a ]; then
    exec /usr/bin/stat -c %a "$3"
else
    exec /usr/bin/stat "$@"
fi
EOF
    cat > "$root/stubs/chown" <<'EOF'
#!/bin/sh
exit 0
EOF
    cat > "$root/stubs/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$1" in
    is-active) exit 3 ;;
    disable)
        if [ "${FAIL_INSTALL_AT:-}" = disable ] && [ ! -e "$FAIL_MARKER" ]; then
            : > "$FAIL_MARKER"
            exit 77
        fi
        ;;
    daemon-reload)
        if [ "${FAIL_INSTALL_AT:-}" = crash-reload ] && [ ! -e "$FAIL_MARKER" ]; then
            : > "$FAIL_MARKER"
            kill -KILL "$PPID"
            exit 79
        fi
        if [ "${FAIL_INSTALL_AT:-}" = reload ] && [ ! -e "$FAIL_MARKER" ]; then
            : > "$FAIL_MARKER"
            exit 78
        fi
        ;;
esac
exit 0
EOF
    cat > "$root/stubs/mv" <<'EOF'
#!/bin/sh
for destination do :; done
if [ "${FAIL_INSTALL_AT:-}" = identity ] && [ "$destination" = "$HMO_FIXTURE_ROOT/var/lib/geph-flatpak/manager.identity" ] && [ ! -e "$FAIL_MARKER" ]; then
    : > "$FAIL_MARKER"
    exit 64
fi
exec /usr/bin/mv "$@"
EOF
    cat > "$root/stubs/id" <<'EOF'
#!/bin/sh
[ "$1" = -u ] || exit 2
printf '0\n'
EOF
    cat > "$root/stubs/flatpak-spawn" <<'EOF'
#!/bin/sh
[ "$1" = --host ] && [ "$2" = pkexec ] || exit 2
printf '%s\n' "$*" >> "$FLATPAK_LOG"
shift 2
exec "$@"
EOF
    cat > "$root/stubs/zenity" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$ZENITY_LOG"
exit "${ZENITY_RESPONSE:-0}"
EOF
    chmod 0755 "$root/stubs/"*
}

configure_fixture_env() {
    local root="$1"
    export HMO_FIXTURE_ROOT="$root"
    export PATH="$root/stubs:$PATH"
    export OWNER_DATA="$root/home/user"
    export PKEXEC_UID=1001
    export GEPh5_PATH="$root/usr/local/bin/geph5"
    export SERVICE_PATH="$root/etc/systemd/system/geph-manager.service"
    export CALL_LOG="$root/calls.log"
    export INSTALL_LOG="$root/install.log"
    export SYSTEMCTL_LOG="$root/systemctl.log"
    export FLATPAK_LOG="$root/flatpak-spawn.log"
    export ZENITY_LOG="$root/zenity.log"
    export FAIL_MARKER="$root/fail-once.marker"
}

fixture_env() {
    local root="$1"
    configure_fixture_env "$root"
    : > "$CALL_LOG"
    : > "$INSTALL_LOG"
    : > "$SYSTEMCTL_LOG"
    : > "$FLATPAK_LOG"
    : > "$ZENITY_LOG"
}

run_installer() {
    local root="$1"
    configure_fixture_env "$root"
    /bin/sh "$root/staging/install-host-manager.sh" "$root/staging" "$OWNER_DATA"
}

wait_for_marker() {
    local marker="$1" description="$2"
    local attempt
    for attempt in {1..400}; do
        [[ -e "$marker" ]] && return 0
        sleep 0.025
    done
    fail "timed out waiting for $description"
}

run_uninstaller_all() {
    local root="$1"
    configure_fixture_env "$root"
    PKEXEC_UID=1001 /bin/sh "$root/usr/local/bin/geph-flatpak-uninstall" --all
}

assert_unknown_identity() {
    local root="$1"
    grep -Fxq 'owners=unknown' "$root/var/lib/geph-flatpak/manager.identity" || fail 'manager identity did not mark owner set unknown'
}

make_root() {
    local name="$1"
    local root="$TMP_ROOT/$name"
    mkdir -p "$root"
    make_test_sources "$root"
    make_command_doubles "$root"
    printf '%s\n' "$root"
}

run_snapshot_journal_fixtures() (
    local root="$TMP_ROOT/snapshot-journals"
    local partial="$root/partial"
    local crash="$root/crash"
    local foreign="$root/foreign"
    HMO_LIBRARY_ONLY=1
    . "$REPO_ROOT/flatpak/geph-flatpak-watchdog.sh"
    unset HMO_LIBRARY_ONLY
    hmo_require_root_owned() { return 0; }
    chown() { return 0; }

    mkdir -p "$partial/state" "$partial/bin"
    printf 'prior manager\n' > "$partial/bin/geph5"
    printf 'prior engine\n' > "$partial/bin/geph5-client"
    cp() {
        local destination
        for destination do :; done
        printf 'partial snapshot\n' > "$destination"
        return 1
    }
    if hmo_begin_install_transaction "$partial/state" "$partial/bin" "$partial/service" \
        "$partial/legacy-service" "$partial/legacy-timer" "$partial/legacy-watchdog"; then
        fail 'partial snapshot copy unexpectedly started an install transaction'
    fi
    unset -f cp
    assert_absent "$partial/state/install-transaction"
    grep -Fxq 'prior manager' "$partial/bin/geph5" || fail 'partial snapshot copy changed the prior manager'
    grep -Fxq 'prior engine' "$partial/bin/geph5-client" || fail 'partial snapshot copy changed the prior engine'
    hmo_restore_install_transaction "$partial/state" "$partial/bin" "$partial/service" /bin/true \
        "$partial/legacy-service" "$partial/legacy-timer" "$partial/legacy-watchdog" || fail 'empty partial journal did not recover'
    hmo_begin_install_transaction "$partial/state" "$partial/bin" "$partial/service" \
        "$partial/legacy-service" "$partial/legacy-timer" "$partial/legacy-watchdog" || fail 'install retry failed after partial snapshot cleanup'
    hmo_clear_install_transaction "$partial/state/install-transaction" || fail 'successful retry journal did not clear'
    assert_absent "$partial/state/install-transaction"

    mkdir -p "$crash/state" "$crash/bin" "$crash/stubs"
    printf 'prior manager\n' > "$crash/bin/geph5"
    cat > "$crash/stubs/cp" <<'EOF'
#!/bin/sh
for destination do :; done
printf 'snapshot before interrupted process\n' > "$destination"
kill -KILL "$PPID"
exit 99
EOF
    cat > "$crash/start-transaction.sh" <<'EOF'
#!/bin/sh
set -eu
HMO_LIBRARY_ONLY=1
. "$HMO_HELPER"
unset HMO_LIBRARY_ONLY
hmo_require_root_owned() { return 0; }
chown() { return 0; }
hmo_begin_install_transaction "$HMO_STATE" "$HMO_BINDIR" "$HMO_SERVICE" \
    "$HMO_LEGACY_SERVICE" "$HMO_LEGACY_TIMER" "$HMO_LEGACY_WATCHDOG"
EOF
    chmod 0755 "$crash/stubs/cp" "$crash/start-transaction.sh"
    if HMO_HELPER="$REPO_ROOT/flatpak/geph-flatpak-watchdog.sh" \
        HMO_STATE="$crash/state" HMO_BINDIR="$crash/bin" HMO_SERVICE="$crash/service" \
        HMO_LEGACY_SERVICE="$crash/legacy-service" HMO_LEGACY_TIMER="$crash/legacy-timer" \
        HMO_LEGACY_WATCHDOG="$crash/legacy-watchdog" PATH="$crash/stubs:$PATH" \
        /bin/sh "$crash/start-transaction.sh"; then
        fail 'snapshot interruption did not stop the pre-active transaction'
    fi
    assert_exists "$crash/state/install-transaction/backup/geph5.backup.tmp"
    assert_absent "$crash/state/install-transaction/active"
    grep -Fxq 'prior manager' "$crash/bin/geph5" || fail 'interrupted snapshot changed the prior manager'
    hmo_restore_install_transaction "$crash/state" "$crash/bin" "$crash/service" /bin/true \
        "$crash/legacy-service" "$crash/legacy-timer" "$crash/legacy-watchdog" || fail 'pre-active transaction cleanup failed'
    assert_absent "$crash/state/install-transaction"
    hmo_begin_install_transaction "$crash/state" "$crash/bin" "$crash/service" \
        "$crash/legacy-service" "$crash/legacy-timer" "$crash/legacy-watchdog" || fail 'retry failed after pre-active recovery'
    hmo_clear_install_transaction "$crash/state/install-transaction" || fail 'post-crash retry journal did not clear'
    grep -Fxq 'prior manager' "$crash/bin/geph5" || fail 'pre-active recovery changed the prior manager'

    mkdir -p "$foreign/state/install-transaction/backup"
    printf 'foreign data\n' > "$foreign/state/install-transaction/backup/keep-me"
    if hmo_restore_install_transaction "$foreign/state" "$foreign/bin" "$foreign/service" /bin/true \
        "$foreign/legacy-service" "$foreign/legacy-timer" "$foreign/legacy-watchdog"; then
        fail 'recovery discarded unknown transaction backup data'
    fi
    assert_exists "$foreign/state/install-transaction/backup/keep-me"
)

run_snapshot_journal_fixtures

no_flock="$(make_root missing-flock)"
mkdir -p "$no_flock/empty-path"
rm -rf "$no_flock/usr/local/bin" "$no_flock/etc/systemd/system" "$no_flock/var/lib/geph-flatpak"
fixture_env "$no_flock"
if PATH="$no_flock/empty-path" /bin/sh "$no_flock/staging/install-host-manager.sh" \
    "$no_flock/staging" "$OWNER_DATA" > "$no_flock/missing-flock.log" 2>&1; then
    fail 'installer continued without the kernel-lock command'
fi
grep -Fq 'util-linux flock command is required' "$no_flock/missing-flock.log" || fail 'missing flock was rejected for an unexpected reason'
assert_absent "$no_flock/usr/local/bin"
assert_absent "$no_flock/etc/systemd/system"
assert_absent "$no_flock/var/lib/geph-flatpak"

prepare_legacy_fixture() {
    local root="$1"
    mkdir -p "$root/app/bin" "$root/app/libexec/geph" "$root/home/user/data"
    cp "$root/staging/geph5" "$root/usr/local/bin/geph5"
    cp "$root/staging/geph5-client" "$root/usr/local/bin/geph5-client"
    chmod 0755 "$root/usr/local/bin/geph5"
    printf 'ExecStart=%s manager\n' "$root/usr/local/bin/geph5" > "$root/etc/systemd/system/geph-manager.service"
    printf 'ExecStart=%s/geph-flatpak-watchdog %s %s\n' "$root/usr/local/bin" "$root/home/user" "$root/usr/local/bin" > "$root/etc/systemd/system/geph-cleanup.service"
    printf 'Description=Periodically check whether the Geph Flatpak was uninstalled\n' > "$root/etc/systemd/system/geph-cleanup.timer"
    cat > "$root/usr/local/bin/geph-flatpak-watchdog" <<'EOF'
#!/bin/sh
rm -f "$FIXTURE_BIN/geph5" "$FIXTURE_BIN/geph5-client"
EOF
    chmod 0755 "$root/usr/local/bin/geph-flatpak-watchdog"
    cp "$root/staging/geph5" "$root/app/bin/geph5"
    cp "$root/staging/geph5-client" "$root/app/bin/geph5-client"
    cp "$root/staging/install-host-manager.sh" "$root/app/libexec/geph/install-host-manager.sh"
    cp "$root/staging/geph-flatpak-watchdog.sh" "$root/app/libexec/geph/geph-flatpak-watchdog.sh"
    cp "$root/staging/geph-cleanup.service" "$root/app/libexec/geph/geph-cleanup.service"
    cp "$root/staging/geph-cleanup.timer" "$root/app/libexec/geph/geph-cleanup.timer"
    cp "$root/staging/geph-uninstall-host-manager.sh" "$root/app/bin/geph-uninstall-host-manager"
    sed 's|/app|$HMO_FIXTURE_ROOT/app|g' "$REPO_ROOT/flatpak/geph-migrate-host-manager.sh" > "$root/app/bin/geph-migrate-host-manager"
    chmod 0755 "$root/app/bin/geph-migrate-host-manager"
}

run_migration() {
    local root="$1"
    configure_fixture_env "$root"
    export XDG_DATA_HOME="$root/home/user/data"
    export HOME="$root/home/user"
    export FIXTURE_BIN="$root/usr/local/bin"
    "$root/app/bin/geph-migrate-host-manager"
}

# A held shared lock rejects a bounded installer attempt before it changes any
# manager target. The test copy shortens only the lock wait to two zero-delay tries.
lock_busy="$(make_root lock-busy)"
fixture_env "$lock_busy"
lock_file="$lock_busy/var/lib/geph-flatpak/lifecycle.lock"
printf '99999999\n' > "$lock_file"
chmod 0600 "$lock_file"
(
    exec 9>>"$lock_file"
    flock -n 9 || exit 70
    : > "$lock_busy/lock-held"
    while [ ! -e "$lock_busy/lock-release" ]; do sleep 0.01; done
) &
lock_holder=$!
wait_for_marker "$lock_busy/lock-held" 'kernel lock holder'
sed 's#hmo_acquire_lifecycle_lock "$LOCK_FILE" ||#hmo_acquire_lifecycle_lock "$LOCK_FILE" 2 0 ||#' \
    "$lock_busy/staging/install-host-manager.sh" > "$lock_busy/staging/install-host-manager-short-lock.sh"
if /bin/sh "$lock_busy/staging/install-host-manager-short-lock.sh" "$lock_busy/staging" "$OWNER_DATA"; then
    fail 'installer ignored a held lifecycle lock'
fi
assert_absent "$lock_busy/usr/local/bin/geph5"
assert_absent "$lock_busy/etc/systemd/system/geph-manager.service"
assert_absent "$lock_busy/var/lib/geph-flatpak/manager.identity"
[[ ! -s "$INSTALL_LOG" ]] || fail 'failed lock acquisition copied manager files'
: > "$lock_busy/lock-release"
wait "$lock_holder" || fail 'kernel lock holder did not exit cleanly'
lock_holder=""

# Stale text in the persistent lock file cannot make two waiters own the lock.
concurrent_install="$(make_root concurrent-install)"
fixture_env "$concurrent_install"
concurrent_lock="$concurrent_install/var/lib/geph-flatpak/lifecycle.lock"
printf '99999999\n' > "$concurrent_lock"
chmod 0600 "$concurrent_lock"
concurrent_lock_inode="$(stat -c %i "$concurrent_lock")"

# Two installers interleave at registration. The second must wait until the
# first publishes its state, then re-check and finish with a consistent record.
export BLOCK_REGISTER=1
export REGISTER_READY="$concurrent_install/register.ready"
export REGISTER_RELEASE="$concurrent_install/register.release"
run_installer "$concurrent_install" > "$concurrent_install/installer-one.log" 2>&1 &
installer_one=$!
wait_for_marker "$REGISTER_READY" 'first installer registration'
run_installer "$concurrent_install" > "$concurrent_install/installer-two.log" 2>&1 &
installer_two=$!
sleep 0.3
[[ "$(grep -c 'register-manager' "$CALL_LOG")" == 1 ]] || fail 'second installer reached manager mutation while lock was held'
: > "$REGISTER_RELEASE"
wait "$installer_one" || { cat "$concurrent_install/installer-one.log"; fail 'first concurrent installer failed'; }
installer_one=""
wait "$installer_two" || { cat "$concurrent_install/installer-two.log"; fail 'second concurrent installer failed'; }
installer_two=""
[[ "$(grep -c 'register-manager' "$CALL_LOG")" == 2 ]] || fail 'both serialized installer registrations did not complete'
assert_exists "$concurrent_install/var/lib/geph-flatpak/manager.identity"
assert_unknown_identity "$concurrent_install"
[[ "$(stat -c %i "$concurrent_lock")" == "$concurrent_lock_inode" ]] || fail 'serialized installs replaced the shared lock inode'

# If an admin removal holds the lock first, a concurrent install waits. Once
# the removal finishes, the install runs last and its new active assets remain.
concurrent_remove="$(make_root concurrent-remove)"
run_installer "$concurrent_remove" || fail 'initial concurrent-removal install failed'
remove_lock="$concurrent_remove/var/lib/geph-flatpak/lifecycle.lock"
remove_lock_inode="$(stat -c %i "$remove_lock")"
fixture_env "$concurrent_remove"
export BLOCK_UNREGISTER=1
export UNREGISTER_READY="$concurrent_remove/unregister.ready"
export UNREGISTER_RELEASE="$concurrent_remove/unregister.release"
run_uninstaller_all "$concurrent_remove" > "$concurrent_remove/uninstaller.log" 2>&1 &
uninstaller_pid=$!
wait_for_marker "$UNREGISTER_READY" 'administrator removal before manager teardown'
run_installer "$concurrent_remove" > "$concurrent_remove/reinstall.log" 2>&1 &
reinstaller_pid=$!
sleep 0.3
[[ "$(grep -c 'register-manager' "$CALL_LOG")" == 1 ]] || fail 'installer bypassed the shared removal lock'
: > "$UNREGISTER_RELEASE"
wait "$uninstaller_pid" || { cat "$concurrent_remove/uninstaller.log"; fail 'serialized administrator removal failed'; }
uninstaller_pid=""
assert_exists "$remove_lock"
[[ "$(stat -c %i "$remove_lock")" == "$remove_lock_inode" ]] || fail 'final manager removal replaced or removed the shared lock inode'
wait "$reinstaller_pid" || { cat "$concurrent_remove/reinstall.log"; fail 'installer did not run after serialized removal'; }
reinstaller_pid=""
assert_exists "$concurrent_remove/usr/local/bin/geph5"
assert_exists "$concurrent_remove/etc/systemd/system/geph-manager.service"
assert_unknown_identity "$concurrent_remove"
[[ "$(stat -c %i "$remove_lock")" == "$remove_lock_inode" ]] || fail 'install after final removal used a replacement lock inode'
[[ "$(grep -c 'register-manager' "$CALL_LOG")" == 2 ]] || fail 'new manager was not registered after serialized removal'

# First-install failures after each binary copy, manager registration and
# ownership-record publication must roll back to the empty prior state; a
# subsequent ordinary retry must install cleanly.
for failpoint in copy1 copy2 register identity; do
    root="$(make_root "first-$failpoint")"
    fixture_env "$root"
    if FAIL_INSTALL_AT="$failpoint" /bin/sh "$root/staging/install-host-manager.sh" "$root/staging" "$OWNER_DATA"; then
        fail "first install unexpectedly passed failpoint $failpoint"
    fi
    for path in \
        "$root/usr/local/bin/geph5" "$root/usr/local/bin/geph5-client" \
        "$root/usr/local/bin/geph-flatpak-uninstall" "$root/etc/systemd/system/geph-manager.service" \
        "$root/var/lib/geph-flatpak/manager.identity" "$root/var/lib/geph-flatpak/install-transaction"; do
        assert_absent "$path"
    done
    run_installer "$root" || fail "first install retry failed after $failpoint"
    assert_exists "$root/usr/local/bin/geph5"
    assert_exists "$root/usr/local/bin/geph5-client"
    assert_exists "$root/usr/local/bin/geph-flatpak-uninstall"
    assert_exists "$root/etc/systemd/system/geph-manager.service"
    assert_unknown_identity "$root"
done

# An upgrade failure after registration restores the previous binary, service,
# and identity hashes; the following retry publishes the new version.
upgrade="$(make_root upgrade)"
run_installer "$upgrade" || fail 'initial upgrade fixture install failed'
old_manager_hash="$(sha256sum "$upgrade/usr/local/bin/geph5" | cut -d ' ' -f 1)"
old_engine_hash="$(sha256sum "$upgrade/usr/local/bin/geph5-client" | cut -d ' ' -f 1)"
cp "$upgrade/var/lib/geph-flatpak/manager.identity" "$upgrade/original.identity"
sed -i 's/fixture geph5-client new/fixture geph5-client updated/' "$upgrade/staging/geph5-client"
if FAIL_INSTALL_AT=register run_installer "$upgrade"; then fail 'upgrade register failure was not injected'; fi
[[ "$(sha256sum "$upgrade/usr/local/bin/geph5" | cut -d ' ' -f 1)" == "$old_manager_hash" ]] || fail 'manager binary was not restored after upgrade failure'
[[ "$(sha256sum "$upgrade/usr/local/bin/geph5-client" | cut -d ' ' -f 1)" == "$old_engine_hash" ]] || fail 'engine binary was not restored after upgrade failure'
cmp -s "$upgrade/var/lib/geph-flatpak/manager.identity" "$upgrade/original.identity" || fail 'ownership identity was not restored after upgrade failure'
run_installer "$upgrade" || fail 'upgrade retry did not converge'
[[ "$(sha256sum "$upgrade/usr/local/bin/geph5-client" | cut -d ' ' -f 1)" != "$old_engine_hash" ]] || fail 'upgrade retry kept the old engine binary'
assert_unknown_identity "$upgrade"

# A foreign manager without the recognized legacy cleanup unit remains untouched.
foreign="$(make_root foreign)"
mkdir -p "$foreign/usr/local/bin"
printf 'foreign manager\n' > "$foreign/usr/local/bin/geph5"
printf 'foreign engine\n' > "$foreign/usr/local/bin/geph5-client"
fixture_env "$foreign"
if /bin/sh "$foreign/staging/install-host-manager.sh" "$foreign/staging" "$OWNER_DATA"; then fail 'foreign manager was replaced'; fi
grep -Fxq 'foreign manager' "$foreign/usr/local/bin/geph5" || fail 'foreign manager contents changed'
assert_absent "$foreign/var/lib/geph-flatpak/manager.identity"

# A healthy, equal-hash startup by a second user follows the pinned bootstrap's
# fast path, which skips installer registration. The incomplete record prevents
# the first user's ordinary action from tearing down the shared manager.
healthy="$(make_root healthy-user)"
run_installer "$healthy" || fail 'initial healthy-path fixture install failed'
before_registers="$(grep -c 'register-manager' "$CALL_LOG")"
healthy_hash="$(sha256sum "$healthy/usr/local/bin/geph5" | cut -d ' ' -f 1)"
bundled_hash="$(sha256sum "$healthy/staging/geph5" | cut -d ' ' -f 1)"
[[ "$healthy_hash" == "$bundled_hash" ]] || fail 'healthy-path hashes unexpectedly differ'
# This branch mirrors the reviewed bootstrap's reachable/equal-hash return.
if [[ "$healthy_hash" != "$bundled_hash" ]]; then run_installer "$healthy"; fi
[[ "$(grep -c 'register-manager' "$CALL_LOG")" == "$before_registers" ]] || fail 'healthy new-user startup invoked the skipped installer'
fixture_env "$healthy"
if PKEXEC_UID=1001 /bin/sh "$healthy/usr/local/bin/geph-flatpak-uninstall"; then fail 'unregistered healthy-path user removed the shared manager'; fi
assert_exists "$healthy/usr/local/bin/geph5"
assert_exists "$healthy/etc/systemd/system/geph-manager.service"
fixture_env "$healthy"
if ZENITY_RESPONSE=1 /bin/sh "$healthy/staging/geph-uninstall-host-manager.sh"; then :; else fail 'cancelled shared removal action failed'; fi
[[ ! -s "$FLATPAK_LOG" ]] || fail 'cancelled admin action still invoked the host command'
assert_exists "$healthy/usr/local/bin/geph5"
ZENITY_RESPONSE=0 /bin/sh "$healthy/staging/geph-uninstall-host-manager.sh" || fail 'confirmed admin removal action failed'
assert_absent "$healthy/usr/local/bin/geph5"
grep -Fq -- '--all' "$FLATPAK_LOG" || fail 'desktop removal action did not request explicit administrator-wide removal'

# The migration transaction must restore its ownership proof at each failure
# point, then allow the same desktop action to retry successfully.
for failpoint in disable reload crash-reload copy1 copy2 register identity; do
    legacy_fault="$(make_root "legacy-fault-$failpoint")"
    prepare_legacy_fixture "$legacy_fault"
    legacy_fault_manager_hash="$(sha256sum "$legacy_fault/usr/local/bin/geph5" | cut -d ' ' -f 1)"
    legacy_fault_engine_hash="$(sha256sum "$legacy_fault/usr/local/bin/geph5-client" | cut -d ' ' -f 1)"
    legacy_fault_service_hash="$(sha256sum "$legacy_fault/etc/systemd/system/geph-manager.service" | cut -d ' ' -f 1)"
    legacy_fault_cleanup_service_hash="$(sha256sum "$legacy_fault/etc/systemd/system/geph-cleanup.service" | cut -d ' ' -f 1)"
    legacy_fault_cleanup_timer_hash="$(sha256sum "$legacy_fault/etc/systemd/system/geph-cleanup.timer" | cut -d ' ' -f 1)"
    legacy_fault_watchdog_hash="$(sha256sum "$legacy_fault/usr/local/bin/geph-flatpak-watchdog" | cut -d ' ' -f 1)"
    if FAIL_INSTALL_AT="$failpoint" run_migration "$legacy_fault" > "$legacy_fault/fault-injection.log" 2>&1; then
        fail "legacy migration unexpectedly passed failpoint $failpoint"
    fi
    [[ "$(sha256sum "$legacy_fault/usr/local/bin/geph5" | cut -d ' ' -f 1)" == "$legacy_fault_manager_hash" ]] || fail "migration rollback changed the manager at $failpoint"
    [[ "$(sha256sum "$legacy_fault/usr/local/bin/geph5-client" | cut -d ' ' -f 1)" == "$legacy_fault_engine_hash" ]] || fail "migration rollback changed the engine at $failpoint"
    [[ "$(sha256sum "$legacy_fault/etc/systemd/system/geph-manager.service" | cut -d ' ' -f 1)" == "$legacy_fault_service_hash" ]] || fail "migration rollback changed the service at $failpoint"
    assert_absent "$legacy_fault/var/lib/geph-flatpak/manager.identity"
    if [[ "$failpoint" == crash-reload ]]; then
        assert_absent "$legacy_fault/etc/systemd/system/geph-cleanup.service"
        assert_absent "$legacy_fault/etc/systemd/system/geph-cleanup.timer"
        assert_absent "$legacy_fault/usr/local/bin/geph-flatpak-watchdog"
        assert_exists "$legacy_fault/var/lib/geph-flatpak/install-transaction/active"
    else
        for path in \
            "$legacy_fault/etc/systemd/system/geph-cleanup.service" "$legacy_fault/etc/systemd/system/geph-cleanup.timer" \
            "$legacy_fault/usr/local/bin/geph-flatpak-watchdog"; do
            assert_exists "$path"
        done
        [[ "$(sha256sum "$legacy_fault/etc/systemd/system/geph-cleanup.service" | cut -d ' ' -f 1)" == "$legacy_fault_cleanup_service_hash" ]] || fail "migration rollback lost its service proof at $failpoint"
        [[ "$(sha256sum "$legacy_fault/etc/systemd/system/geph-cleanup.timer" | cut -d ' ' -f 1)" == "$legacy_fault_cleanup_timer_hash" ]] || fail "migration rollback lost its timer proof at $failpoint"
        [[ "$(sha256sum "$legacy_fault/usr/local/bin/geph-flatpak-watchdog" | cut -d ' ' -f 1)" == "$legacy_fault_watchdog_hash" ]] || fail "migration rollback lost its watchdog proof at $failpoint"
        assert_absent "$legacy_fault/var/lib/geph-flatpak/install-transaction"
    fi

    unset FAIL_INSTALL_AT
    run_migration "$legacy_fault" > "$legacy_fault/retry.log" 2>&1 || { cat "$legacy_fault/retry.log"; fail "migration retry failed after $failpoint"; }
    assert_absent "$legacy_fault/etc/systemd/system/geph-cleanup.service"
    assert_absent "$legacy_fault/etc/systemd/system/geph-cleanup.timer"
    assert_absent "$legacy_fault/usr/local/bin/geph-flatpak-watchdog"
    assert_exists "$legacy_fault/usr/local/bin/geph-flatpak-uninstall"
    assert_unknown_identity "$legacy_fault"
done

# Packaging-only update: unchanged manager hashes leave the legacy timer in
# place on the healthy fast path. The explicit packaged migration action stages
# the assets and runs the actual installer, which removes the old timer safely.
legacy="$(make_root legacy-migration)"
mkdir -p "$legacy/app/bin" "$legacy/app/libexec/geph" "$legacy/home/user/data"
cp "$legacy/staging/geph5" "$legacy/usr/local/bin/geph5"
cp "$legacy/staging/geph5-client" "$legacy/usr/local/bin/geph5-client"
chmod 0755 "$legacy/usr/local/bin/geph5"
printf 'ExecStart=%s manager\n' "$legacy/usr/local/bin/geph5" > "$legacy/etc/systemd/system/geph-manager.service"
printf 'ExecStart=%s/geph-flatpak-watchdog %s %s\n' "$legacy/usr/local/bin" "$legacy/home/user" "$legacy/usr/local/bin" > "$legacy/etc/systemd/system/geph-cleanup.service"
printf 'Description=Periodically check whether the Geph Flatpak was uninstalled\n' > "$legacy/etc/systemd/system/geph-cleanup.timer"
cat > "$legacy/usr/local/bin/geph-flatpak-watchdog" <<'EOF'
#!/bin/sh
rm -f "$FIXTURE_BIN/geph5" "$FIXTURE_BIN/geph5-client"
EOF
chmod 0755 "$legacy/usr/local/bin/geph-flatpak-watchdog"
cp "$legacy/staging/geph5" "$legacy/app/bin/geph5"
cp "$legacy/staging/geph5-client" "$legacy/app/bin/geph5-client"
cp "$legacy/staging/install-host-manager.sh" "$legacy/app/libexec/geph/install-host-manager.sh"
cp "$legacy/staging/geph-flatpak-watchdog.sh" "$legacy/app/libexec/geph/geph-flatpak-watchdog.sh"
cp "$legacy/staging/geph-cleanup.service" "$legacy/app/libexec/geph/geph-cleanup.service"
cp "$legacy/staging/geph-cleanup.timer" "$legacy/app/libexec/geph/geph-cleanup.timer"
cp "$legacy/staging/geph-uninstall-host-manager.sh" "$legacy/app/bin/geph-uninstall-host-manager"
sed 's|/app|$HMO_FIXTURE_ROOT/app|g' "$REPO_ROOT/flatpak/geph-migrate-host-manager.sh" > "$legacy/app/bin/geph-migrate-host-manager"
chmod 0755 "$legacy/app/bin/geph-migrate-host-manager"
legacy_hash_before="$(sha256sum "$legacy/usr/local/bin/geph5" | cut -d ' ' -f 1)"
fixture_env "$legacy"
export XDG_DATA_HOME="$legacy/home/user/data"
export HOME="$legacy/home/user"
export FIXTURE_BIN="$legacy/usr/local/bin"
# An unchanged healthy manager does not trigger the pinned install path.
[[ "$legacy_hash_before" == "$(sha256sum "$legacy/app/bin/geph5" | cut -d ' ' -f 1)" ]] || fail 'legacy fixture is not a packaging-only update'
assert_exists "$legacy/etc/systemd/system/geph-cleanup.timer"
"$legacy/app/bin/geph-migrate-host-manager" || fail 'explicit migration desktop action failed'
assert_absent "$legacy/etc/systemd/system/geph-cleanup.timer"
assert_absent "$legacy/etc/systemd/system/geph-cleanup.service"
assert_absent "$legacy/usr/local/bin/geph-flatpak-watchdog"
assert_exists "$legacy/usr/local/bin/geph-flatpak-uninstall"
assert_unknown_identity "$legacy"
[[ "$(sha256sum "$legacy/usr/local/bin/geph5" | cut -d ' ' -f 1)" == "$legacy_hash_before" ]] || fail 'packaging-only migration unexpectedly changed manager bytes'
grep -Fq -- '--host pkexec' "$FLATPAK_LOG" || fail 'migration action did not use the host pkexec route'
grep -Fq "$legacy/home/user" "$FLATPAK_LOG" || fail 'migration action did not preserve the second installer argument'

# The installed post-removal command remains usable after the Flatpak app tree
# is gone; normal mode refuses unknown ownership and explicit root --all works.
rm -rf "$legacy/app"
fixture_env "$legacy"
export HOME="$legacy/home/user"
if PKEXEC_UID=1001 /bin/sh "$legacy/usr/local/bin/geph-flatpak-uninstall"; then fail 'normal cleanup removed an unknown-owner manager'; fi
assert_exists "$legacy/usr/local/bin/geph5"
PKEXEC_UID=1001 /bin/sh "$legacy/usr/local/bin/geph-flatpak-uninstall" --all || fail 'post-removal administrator command failed'
assert_absent "$legacy/usr/local/bin/geph5"
assert_absent "$legacy/usr/local/bin/geph5-client"
assert_exists "$legacy/usr/local/bin/geph-flatpak-uninstall"

printf 'PASS: actual installer transactions, healthy-path ownership fallback, and explicit migration fixtures\n'
