#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HMO_LIBRARY_ONLY=1
. "$REPO_ROOT/flatpak/geph-flatpak-watchdog.sh"
unset HMO_LIBRARY_ONLY

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

grep -Fq 'Actions=MigrateHostManager;UninstallHostManager;' "$REPO_ROOT/flatpak/icons/io.geph.GephGui.desktop" || fail 'desktop lifecycle actions are missing'
grep -Fq 'Exec=geph-migrate-host-manager' "$REPO_ROOT/flatpak/icons/io.geph.GephGui.desktop" || fail 'desktop migration action is missing'
grep -Fq 'Exec=geph-uninstall-host-manager' "$REPO_ROOT/flatpak/icons/io.geph.GephGui.desktop" || fail 'desktop action does not invoke the sandbox wrapper'
grep -Fq 'geph-uninstall-host-manager.sh' "$REPO_ROOT/flatpak/io.geph.GephGui.yml" || fail 'host uninstall entry point is not packaged'
grep -Fq 'geph-migrate-host-manager.sh' "$REPO_ROOT/flatpak/io.geph.GephGui.yml" || fail 'host migration entry point is not packaged'
grep -Fq 'geph-cleanup.timer' "$REPO_ROOT/flatpak/io.geph.GephGui.yml" || fail 'pinned bootstrap staging contract is missing its legacy asset name'
if grep -Fq 'systemctl enable --now geph-cleanup.timer' "$REPO_ROOT/flatpak/install-host-manager.sh"; then
    fail 'installer still enables the automatic cleanup timer'
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

assert_exists() {
    [[ -e "$1" ]] || fail "expected file to remain: $1"
}

assert_absent() {
    [[ ! -e "$1" ]] || fail "expected file to be absent: $1"
}

make_fixture() {
    local name="$1" owner_list="$2"
    local root="$TMP_ROOT/$name"
    mkdir -p "$root/bin" "$root/state"
    cat > "$root/bin/geph5" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$CALL_LOG"
if [ "$1" = unregister-manager ]; then
    rm -f "$SERVICE_FILE"
    if [ "${FAIL_AFTER_UNREGISTER:-0}" = 1 ]; then exit 1; fi
fi
exit 0
EOF
    chmod +x "$root/bin/geph5"
    printf 'fixture engine\n' > "$root/bin/geph5-client"
    printf 'ExecStart=/usr/local/bin/geph5 manager\n' > "$root/state/geph-manager.service"
    hmo_file_sha256 "$root/bin/geph5" || fail "could not hash $name manager"
    local manager_hash="$HMO_HASH_VALUE"
    hmo_file_sha256 "$root/bin/geph5-client" || fail "could not hash $name engine"
    local client_hash="$HMO_HASH_VALUE"
    hmo_file_sha256 "$root/state/geph-manager.service" || fail "could not hash $name service"
    local service_hash="$HMO_HASH_VALUE"
    hmo_write_identity "$root/state/manager.identity" installed "$owner_list" '' \
        "$manager_hash" "$client_hash" "$service_hash" || fail "could not create $name identity fixture"
    printf '%s\n' "$root"
}

make_command_doubles() {
    local root="$1"
    mkdir -p "$root/doubles"
    cat > "$root/doubles/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
if [ "$1" = is-active ]; then exit 3; fi
if [ "${FAIL_RELOAD_ONCE:-0}" = 1 ] && [ ! -e "$RELOAD_MARKER" ]; then
    : > "$RELOAD_MARKER"
    exit 1
fi
exit 0
EOF
    chmod +x "$root/doubles/systemctl"
}

data_root="$TMP_ROOT/data-retained"
mkdir -p "$data_root/flatpak-app-data"
mkdir -p "$data_root/bin"
printf 'foreign manager\n' > "$data_root/bin/geph5"
printf 'foreign engine\n' > "$data_root/bin/geph5-client"
CALL_LOG="$data_root/calls.log"
SYSTEMCTL_LOG="$data_root/systemctl.log"
SERVICE_FILE="$data_root/geph-manager.service"
export CALL_LOG SYSTEMCTL_LOG SERVICE_FILE
make_command_doubles "$data_root"
if /bin/sh "$REPO_ROOT/flatpak/geph-flatpak-watchdog.sh" "$data_root/flatpak-app-data" "$data_root/bin"; then
    :
else
    fail 'legacy data-retention watchdog returned an error'
fi
assert_exists "$data_root/bin/geph5"
assert_absent "$CALL_LOG"

removed_root="$TMP_ROOT/data-removed"
mkdir -p "$removed_root/bin"
printf 'foreign manager\n' > "$removed_root/bin/geph5"
printf 'foreign engine\n' > "$removed_root/bin/geph5-client"
CALL_LOG="$removed_root/calls.log"
SYSTEMCTL_LOG="$removed_root/systemctl.log"
SERVICE_FILE="$removed_root/geph-manager.service"
export CALL_LOG SYSTEMCTL_LOG SERVICE_FILE
make_command_doubles "$removed_root"
if /bin/sh "$REPO_ROOT/flatpak/geph-flatpak-watchdog.sh" "$removed_root/missing-app-data" "$removed_root/bin"; then
    :
else
    fail 'legacy missing-data watchdog returned an error'
fi
assert_exists "$removed_root/bin/geph5"
assert_absent "$CALL_LOG"

shared="$(make_fixture shared '1001,1002')"
CALL_LOG="$shared/calls.log"
SYSTEMCTL_LOG="$shared/systemctl.log"
SERVICE_FILE="$shared/state/geph-manager.service"
RELOAD_MARKER="$shared/reload-once"
export CALL_LOG SYSTEMCTL_LOG SERVICE_FILE RELOAD_MARKER
make_command_doubles "$shared"
if hmo_cleanup_owned_manager "$shared/state/manager.identity" "$shared/bin" \
    "$shared/state/geph-manager.service" 1002 "$shared/state" "$shared/doubles/systemctl"; then
    fail 'an incomplete per-user owner list authorized removal'
fi
assert_exists "$shared/bin/geph5"
assert_exists "$shared/state/geph-manager.service"
if grep -q 'unregister-manager' "$CALL_LOG" 2>/dev/null; then
    fail 'removing one owner unregistered a manager still owned by another'
fi
hmo_read_identity "$shared/state/manager.identity" || fail 'shared ownership record became unreadable'
hmo_cleanup_owned_manager "$shared/state/manager.identity" "$shared/bin" \
    "$shared/state/geph-manager.service" 0 "$shared/state" "$shared/doubles/systemctl" 1 || fail 'explicit admin removal did not complete'
assert_absent "$shared/bin/geph5"

# Neither a healthy startup nor an old single-path timer proves a complete
# cross-user owner set, so migrated manager state must remain unknown.
hmo_legacy_migration_owners 1001 || fail 'legacy migration owner selection failed'
[[ "$HMO_MIGRATION_OWNERS" == unknown ]] || fail "legacy migration owner set is '$HMO_MIGRATION_OWNERS'"
migrated="$(make_fixture migrated "$HMO_MIGRATION_OWNERS")"
CALL_LOG="$migrated/calls.log"
SYSTEMCTL_LOG="$migrated/systemctl.log"
SERVICE_FILE="$migrated/state/geph-manager.service"
RELOAD_MARKER="$migrated/reload-once"
export CALL_LOG SYSTEMCTL_LOG SERVICE_FILE RELOAD_MARKER
make_command_doubles "$migrated"
if hmo_cleanup_owned_manager "$migrated/state/manager.identity" "$migrated/bin" \
    "$migrated/state/geph-manager.service" 1001 "$migrated/state" "$migrated/doubles/systemctl"; then
    fail 'migrated incomplete ownership authorized a user removal'
fi
assert_exists "$migrated/bin/geph5"
assert_exists "$migrated/state/geph-manager.service"
hmo_read_identity "$migrated/state/manager.identity" || fail 'migrated ownership record became unreadable'
hmo_cleanup_owned_manager "$migrated/state/manager.identity" "$migrated/bin" \
    "$migrated/state/geph-manager.service" 0 "$migrated/state" "$migrated/doubles/systemctl" 1 || fail 'administrator cleanup of migrated manager failed'
assert_absent "$migrated/bin/geph5"
assert_absent "$migrated/state/geph-manager.service"
assert_absent "$migrated/state/manager.identity"

retry="$(make_fixture retry 1001)"
CALL_LOG="$retry/calls.log"
SYSTEMCTL_LOG="$retry/systemctl.log"
SERVICE_FILE="$retry/state/geph-manager.service"
RELOAD_MARKER="$retry/reload-once"
export CALL_LOG SYSTEMCTL_LOG SERVICE_FILE RELOAD_MARKER
make_command_doubles "$retry"
if FAIL_AFTER_UNREGISTER=1 FAIL_RELOAD_ONCE=1 hmo_cleanup_owned_manager \
    "$retry/state/manager.identity" "$retry/bin" "$retry/state/geph-manager.service" \
    0 "$retry/state" "$retry/doubles/systemctl" 1; then
    fail 'injected interrupted cleanup unexpectedly completed'
fi
assert_exists "$retry/bin/geph5"
assert_exists "$retry/state/manager.identity"
assert_absent "$retry/state/geph-manager.service"
hmo_cleanup_owned_manager "$retry/state/manager.identity" "$retry/bin" \
    "$retry/state/geph-manager.service" 0 "$retry/state" "$retry/doubles/systemctl" 1 || fail 'cleanup retry did not converge'
assert_absent "$retry/bin/geph5"
assert_absent "$retry/bin/geph5-client"
assert_absent "$retry/state/manager.identity"
hmo_cleanup_owned_manager "$retry/state/manager.identity" "$retry/bin" \
    "$retry/state/geph-manager.service" 0 "$retry/state" "$retry/doubles/systemctl" 1 || fail 'repeated cleanup was not idempotent'

foreign="$(make_fixture foreign 1001)"
CALL_LOG="$foreign/calls.log"
SYSTEMCTL_LOG="$foreign/systemctl.log"
SERVICE_FILE="$foreign/state/geph-manager.service"
RELOAD_MARKER="$foreign/reload-once"
export CALL_LOG SYSTEMCTL_LOG SERVICE_FILE RELOAD_MARKER
make_command_doubles "$foreign"
printf 'manual replacement\n' > "$foreign/bin/geph5"
if hmo_cleanup_owned_manager "$foreign/state/manager.identity" "$foreign/bin" \
    "$foreign/state/geph-manager.service" 0 "$foreign/state" "$foreign/doubles/systemctl" 1; then
    fail 'unrelated replacement manager was accepted'
fi
assert_exists "$foreign/bin/geph5"
assert_exists "$foreign/state/manager.identity"
assert_absent "$CALL_LOG"

corrupt="$(make_fixture corrupt 1001)"
CALL_LOG="$corrupt/calls.log"
SYSTEMCTL_LOG="$corrupt/systemctl.log"
SERVICE_FILE="$corrupt/state/geph-manager.service"
RELOAD_MARKER="$corrupt/reload-once"
export CALL_LOG SYSTEMCTL_LOG SERVICE_FILE RELOAD_MARKER
make_command_doubles "$corrupt"
printf 'format=geph-flatpak-manager-v1\nstate=installed\nowners=../redirect\n' > "$corrupt/state/manager.identity"
if hmo_cleanup_owned_manager "$corrupt/state/manager.identity" "$corrupt/bin" \
    "$corrupt/state/geph-manager.service" 0 "$corrupt/state" "$corrupt/doubles/systemctl" 1; then
    fail 'corrupt owner record was accepted'
fi
assert_exists "$corrupt/bin/geph5"
assert_exists "$corrupt/state/geph-manager.service"
assert_absent "$CALL_LOG"
chmod 0666 "$corrupt/state/manager.identity"
if hmo_require_root_owned "$corrupt/state/manager.identity" file; then
    fail 'group/world-writable ownership record was accepted'
fi

unauthorized="$(make_fixture unauthorized 1001)"
CALL_LOG="$unauthorized/calls.log"
SYSTEMCTL_LOG="$unauthorized/systemctl.log"
SERVICE_FILE="$unauthorized/state/geph-manager.service"
RELOAD_MARKER="$unauthorized/reload-once"
export CALL_LOG SYSTEMCTL_LOG SERVICE_FILE RELOAD_MARKER
make_command_doubles "$unauthorized"
if hmo_cleanup_owned_manager "$unauthorized/state/manager.identity" "$unauthorized/bin" \
    "$unauthorized/state/geph-manager.service" 1002 "$unauthorized/state" "$unauthorized/doubles/systemctl"; then
    fail 'normal user action was authorized to remove the shared manager'
fi
assert_exists "$unauthorized/bin/geph5"
assert_absent "$CALL_LOG"

admin_guard="$(make_fixture admin-guard '1001,1002')"
CALL_LOG="$admin_guard/calls.log"
SYSTEMCTL_LOG="$admin_guard/systemctl.log"
SERVICE_FILE="$admin_guard/state/geph-manager.service"
RELOAD_MARKER="$admin_guard/reload-once"
export CALL_LOG SYSTEMCTL_LOG SERVICE_FILE RELOAD_MARKER
make_command_doubles "$admin_guard"
if hmo_cleanup_owned_manager "$admin_guard/state/manager.identity" "$admin_guard/bin" \
    "$admin_guard/state/geph-manager.service" 0 "$admin_guard/state" "$admin_guard/doubles/systemctl"; then
    fail 'root removal without --all bypassed the incomplete owner set'
fi
assert_exists "$admin_guard/bin/geph5"
assert_absent "$CALL_LOG"
grep -Fq 'geph-flatpak-uninstall [--all]' "$REPO_ROOT/flatpak/geph-flatpak-watchdog.sh" || fail 'administrator-wide action is not explicitly named'
hmo_cleanup_owned_manager "$admin_guard/state/manager.identity" "$admin_guard/bin" \
    "$admin_guard/state/geph-manager.service" 0 "$admin_guard/state" "$admin_guard/doubles/systemctl" 1 || fail 'explicit administrator-wide cleanup failed'
assert_absent "$admin_guard/bin/geph5"
assert_absent "$admin_guard/state/geph-manager.service"
assert_absent "$admin_guard/state/manager.identity"

printf 'PASS: Flatpak host-manager ownership fixtures\n'
