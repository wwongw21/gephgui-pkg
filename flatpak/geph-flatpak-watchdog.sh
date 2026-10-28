#!/bin/sh
# Shared, data-only ownership and teardown helpers for the privileged Flatpak
# installer and explicit uninstaller. Callers supply fixed production paths;
# no path read from the identity file is ever executed or deleted.

hmo_error() {
    printf 'Geph Flatpak manager: %s\n' "$*" >&2
}

hmo_valid_uid() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

hmo_valid_sha256() {
    [ "${#1}" -eq 64 ] || return 1
    case "$1" in
        *[!0123456789abcdef]*) return 1 ;;
        *) return 0 ;;
    esac
}

hmo_mode_is_protected() {
    HMO_MODE="$1"
    case "$HMO_MODE" in
        ''|*[!0-7]*) return 1 ;;
    esac
    if [ "${#HMO_MODE}" -eq 4 ]; then HMO_MODE="${HMO_MODE#?}"; fi
    [ "${#HMO_MODE}" -eq 3 ] || return 1
    HMO_GROUP_WORLD="${HMO_MODE#?}"
    HMO_GROUP="${HMO_GROUP_WORLD%?}"
    HMO_OTHER="${HMO_MODE#??}"
    case "$HMO_GROUP$HMO_OTHER" in
        *[2367]*) return 1 ;;
        *) return 0 ;;
    esac
}

hmo_require_root_owned() {
    HMO_PROTECTED_PATH="$1"
    HMO_PROTECTED_KIND="$2"
    case "$HMO_PROTECTED_KIND" in
        file) [ -f "$HMO_PROTECTED_PATH" ] && [ ! -L "$HMO_PROTECTED_PATH" ] || return 1 ;;
        dir) [ -d "$HMO_PROTECTED_PATH" ] && [ ! -L "$HMO_PROTECTED_PATH" ] || return 1 ;;
        *) return 1 ;;
    esac
    HMO_PROTECTED_UID="$(stat -c %u "$HMO_PROTECTED_PATH")" || return 1
    HMO_PROTECTED_MODE="$(stat -c %a "$HMO_PROTECTED_PATH")" || return 1
    [ "$HMO_PROTECTED_UID" = 0 ] && hmo_mode_is_protected "$HMO_PROTECTED_MODE"
}

hmo_acquire_lifecycle_lock() {
    HMO_LOCK_REQUEST_PATH="$1"
    HMO_LOCK_ATTEMPTS="${2:-120}"
    HMO_LOCK_DELAY="${3:-0.25}"
    case "$HMO_LOCK_ATTEMPTS" in ''|*[!0-9]*) hmo_error 'lock wait bound is invalid'; return 1 ;; esac
    [ "$HMO_LOCK_ATTEMPTS" -gt 0 ] || { hmo_error 'lock wait bound must be positive'; return 1; }
    HMO_LOCK_TRIES=0
    while :; do
        if (umask 077; mkdir "$HMO_LOCK_REQUEST_PATH") 2>/dev/null; then
            HMO_LOCK_PID_TMP="$HMO_LOCK_REQUEST_PATH/pid.tmp.$$"
            if ! (umask 077; printf '%s\n' "$$" > "$HMO_LOCK_PID_TMP") ||
                ! mv -f "$HMO_LOCK_PID_TMP" "$HMO_LOCK_REQUEST_PATH/pid" ||
                ! chmod 0600 "$HMO_LOCK_REQUEST_PATH/pid" ||
                ! chown root:root "$HMO_LOCK_REQUEST_PATH/pid"; then
                rm -f "$HMO_LOCK_PID_TMP" "$HMO_LOCK_REQUEST_PATH/pid"
                rmdir "$HMO_LOCK_REQUEST_PATH" 2>/dev/null || true
                hmo_error 'could not create the lifecycle lock owner record'
                return 1
            fi
            chmod 0700 "$HMO_LOCK_REQUEST_PATH" && chown root:root "$HMO_LOCK_REQUEST_PATH" || {
                rm -f "$HMO_LOCK_REQUEST_PATH/pid"
                rmdir "$HMO_LOCK_REQUEST_PATH" 2>/dev/null || true
                hmo_error 'could not protect the lifecycle lock'
                return 1
            }
            HMO_LOCK_PATH="$HMO_LOCK_REQUEST_PATH"
            HMO_LOCK_HELD=1
            return 0
        fi

        [ -d "$HMO_LOCK_REQUEST_PATH" ] && [ ! -L "$HMO_LOCK_REQUEST_PATH" ] || {
            hmo_error 'lifecycle lock path is not a protected directory'
            return 1
        }
        if [ -f "$HMO_LOCK_REQUEST_PATH/pid" ] && [ ! -L "$HMO_LOCK_REQUEST_PATH/pid" ]; then
            HMO_LOCK_OWNER="$(cat "$HMO_LOCK_REQUEST_PATH/pid")" || return 1
            case "$HMO_LOCK_OWNER" in ''|*[!0-9]*) hmo_error 'lifecycle lock owner record is invalid'; return 1 ;; esac
            if ! kill -0 "$HMO_LOCK_OWNER" 2>/dev/null; then
                rm -f "$HMO_LOCK_REQUEST_PATH/pid"
                rmdir "$HMO_LOCK_REQUEST_PATH" 2>/dev/null || true
                continue
            fi
        fi
        HMO_LOCK_TRIES=$((HMO_LOCK_TRIES + 1))
        if [ "$HMO_LOCK_TRIES" -ge "$HMO_LOCK_ATTEMPTS" ]; then
            hmo_error 'another Geph host-manager operation holds the lifecycle lock; retry later'
            return 1
        fi
        sleep "$HMO_LOCK_DELAY" || { hmo_error 'could not wait for the host-manager lifecycle lock'; return 1; }
    done
}

hmo_release_lifecycle_lock() {
    [ "${HMO_LOCK_HELD:-0}" = 1 ] || return 0
    if [ -f "$HMO_LOCK_PATH/pid" ] && [ ! -L "$HMO_LOCK_PATH/pid" ] &&
        [ "$(cat "$HMO_LOCK_PATH/pid" 2>/dev/null)" = "$$" ]; then
        rm -f "$HMO_LOCK_PATH/pid"
        rmdir "$HMO_LOCK_PATH" 2>/dev/null || true
    fi
    HMO_LOCK_HELD=0
}

hmo_valid_owner_list() {
    HMO_LIST_REST="$1"
    [ "$HMO_LIST_REST" = unknown ] && return 0
    HMO_LIST_SEEN=,
    [ -n "$HMO_LIST_REST" ] || return 1
    case "$HMO_LIST_REST" in
        ,*|*,|*,,*|*[!0-9,]*) return 1 ;;
    esac
    while [ -n "$HMO_LIST_REST" ]; do
        case "$HMO_LIST_REST" in
            *,*) HMO_LIST_UID="${HMO_LIST_REST%%,*}"; HMO_LIST_REST="${HMO_LIST_REST#*,}" ;;
            *) HMO_LIST_UID="$HMO_LIST_REST"; HMO_LIST_REST='' ;;
        esac
        hmo_valid_uid "$HMO_LIST_UID" || return 1
        case "$HMO_LIST_SEEN" in
            *,"$HMO_LIST_UID",*) return 1 ;;
        esac
        HMO_LIST_SEEN="${HMO_LIST_SEEN}${HMO_LIST_UID},"
    done
}

hmo_owner_list_contains() {
    HMO_CONTAINS_LIST="$1"
    HMO_CONTAINS_UID="$2"
    case ",$HMO_CONTAINS_LIST," in
        *,"$HMO_CONTAINS_UID",*) return 0 ;;
        *) return 1 ;;
    esac
}

hmo_owner_list_add() {
    HMO_ADD_LIST="$1"
    HMO_ADD_UID="$2"
    hmo_valid_uid "$HMO_ADD_UID" || return 1
    if hmo_owner_list_contains "$HMO_ADD_LIST" "$HMO_ADD_UID"; then
        HMO_OWNERS_UPDATED="$HMO_ADD_LIST"
    elif [ -n "$HMO_ADD_LIST" ]; then
        HMO_OWNERS_UPDATED="$HMO_ADD_LIST,$HMO_ADD_UID"
    else
        HMO_OWNERS_UPDATED="$HMO_ADD_UID"
    fi
    hmo_valid_owner_list "$HMO_OWNERS_UPDATED"
}

# The pinned GUI bootstrap skips the installer for healthy managers, so neither
# a new-user startup nor a packaging-only update proves that all users are
# recorded. Mark the shared manager's owner set unknown and require an explicit
# administrator-wide removal after checking every Flatpak installation.
hmo_legacy_migration_owners() {
    HMO_MIGRATION_UID="$1"
    hmo_valid_uid "$HMO_MIGRATION_UID" || return 1
    HMO_MIGRATION_OWNERS=unknown
}

hmo_owner_list_remove() {
    HMO_REMOVE_LIST="$1"
    HMO_REMOVE_UID="$2"
    HMO_OWNERS_REMAINING=''
    while [ -n "$HMO_REMOVE_LIST" ]; do
        case "$HMO_REMOVE_LIST" in
            *,*) HMO_REMOVE_ITEM="${HMO_REMOVE_LIST%%,*}"; HMO_REMOVE_LIST="${HMO_REMOVE_LIST#*,}" ;;
            *) HMO_REMOVE_ITEM="$HMO_REMOVE_LIST"; HMO_REMOVE_LIST='' ;;
        esac
        if [ "$HMO_REMOVE_ITEM" != "$HMO_REMOVE_UID" ]; then
            if [ -n "$HMO_OWNERS_REMAINING" ]; then HMO_OWNERS_REMAINING="$HMO_OWNERS_REMAINING,"; fi
            HMO_OWNERS_REMAINING="$HMO_OWNERS_REMAINING$HMO_REMOVE_ITEM"
        fi
    done
}

hmo_read_identity() {
    HMO_IDENTITY_PATH="$1"
    [ -f "$HMO_IDENTITY_PATH" ] && [ ! -L "$HMO_IDENTITY_PATH" ] || {
        hmo_error 'ownership record is missing or is not a regular file'
        return 1
    }
    HMO_FORMAT=''; HMO_STATE=''; HMO_OWNERS=''; HMO_PENDING_UID=''
    HMO_GEPh5_SHA256=''; HMO_CLIENT_SHA256=''; HMO_SERVICE_SHA256=''
    HMO_SEEN_FORMAT=0; HMO_SEEN_STATE=0; HMO_SEEN_OWNERS=0; HMO_SEEN_PENDING=0
    HMO_SEEN_GEPh5=0; HMO_SEEN_CLIENT=0; HMO_SEEN_SERVICE=0
    while IFS='=' read -r HMO_KEY HMO_VALUE || [ -n "$HMO_KEY" ]; do
        case "$HMO_KEY" in
            format)
                [ "$HMO_SEEN_FORMAT" -eq 0 ] || { hmo_error 'duplicate format field'; return 1; }
                HMO_SEEN_FORMAT=1; HMO_FORMAT="$HMO_VALUE" ;;
            state)
                [ "$HMO_SEEN_STATE" -eq 0 ] || { hmo_error 'duplicate state field'; return 1; }
                HMO_SEEN_STATE=1; HMO_STATE="$HMO_VALUE" ;;
            owners)
                [ "$HMO_SEEN_OWNERS" -eq 0 ] || { hmo_error 'duplicate owners field'; return 1; }
                HMO_SEEN_OWNERS=1; HMO_OWNERS="$HMO_VALUE" ;;
            pending_uid)
                [ "$HMO_SEEN_PENDING" -eq 0 ] || { hmo_error 'duplicate pending owner field'; return 1; }
                HMO_SEEN_PENDING=1; HMO_PENDING_UID="$HMO_VALUE" ;;
            geph5_sha256)
                [ "$HMO_SEEN_GEPh5" -eq 0 ] || { hmo_error 'duplicate manager hash field'; return 1; }
                HMO_SEEN_GEPh5=1; HMO_GEPh5_SHA256="$HMO_VALUE" ;;
            geph5_client_sha256)
                [ "$HMO_SEEN_CLIENT" -eq 0 ] || { hmo_error 'duplicate engine hash field'; return 1; }
                HMO_SEEN_CLIENT=1; HMO_CLIENT_SHA256="$HMO_VALUE" ;;
            service_sha256)
                [ "$HMO_SEEN_SERVICE" -eq 0 ] || { hmo_error 'duplicate service hash field'; return 1; }
                HMO_SEEN_SERVICE=1; HMO_SERVICE_SHA256="$HMO_VALUE" ;;
            *) hmo_error "unknown ownership field '$HMO_KEY'"; return 1 ;;
        esac
    done < "$HMO_IDENTITY_PATH"

    [ "$HMO_SEEN_FORMAT$HMO_SEEN_STATE$HMO_SEEN_OWNERS$HMO_SEEN_PENDING$HMO_SEEN_GEPh5$HMO_SEEN_CLIENT$HMO_SEEN_SERVICE" = 1111111 ] || {
        hmo_error 'ownership record is incomplete'
        return 1
    }
    [ "$HMO_FORMAT" = geph-flatpak-manager-v1 ] || { hmo_error 'unsupported ownership record format'; return 1; }
    hmo_valid_sha256 "$HMO_GEPh5_SHA256" && hmo_valid_sha256 "$HMO_CLIENT_SHA256" && hmo_valid_sha256 "$HMO_SERVICE_SHA256" || {
        hmo_error 'ownership record contains an invalid file identity'
        return 1
    }
    case "$HMO_STATE" in
        installed)
            [ -z "$HMO_PENDING_UID" ] && hmo_valid_owner_list "$HMO_OWNERS" || {
                hmo_error 'invalid installed-owner list'
                return 1
            } ;;
        uninstalling)
            [ -z "$HMO_OWNERS" ] && hmo_valid_uid "$HMO_PENDING_UID" || {
                hmo_error 'invalid pending-uninstall owner'
                return 1
            } ;;
        *) hmo_error 'unknown ownership state'; return 1 ;;
    esac
}

hmo_file_sha256() {
    HMO_HASH_PATH="$1"
    [ -f "$HMO_HASH_PATH" ] && [ ! -L "$HMO_HASH_PATH" ] || return 1
    HMO_HASH_OUTPUT="$(sha256sum "$HMO_HASH_PATH")" || return 1
    HMO_HASH_VALUE="${HMO_HASH_OUTPUT%% *}"
    hmo_valid_sha256 "$HMO_HASH_VALUE" || return 1
}

hmo_write_identity() {
    HMO_WRITE_PATH="$1"; HMO_WRITE_STATE="$2"; HMO_WRITE_OWNERS="$3"
    HMO_WRITE_PENDING="$4"; HMO_WRITE_GEPh5="$5"; HMO_WRITE_CLIENT="$6"; HMO_WRITE_SERVICE="$7"
    case "$HMO_WRITE_STATE" in
        installed) [ -z "$HMO_WRITE_PENDING" ] && hmo_valid_owner_list "$HMO_WRITE_OWNERS" || return 1 ;;
        uninstalling) [ -z "$HMO_WRITE_OWNERS" ] && hmo_valid_uid "$HMO_WRITE_PENDING" || return 1 ;;
        *) return 1 ;;
    esac
    hmo_valid_sha256 "$HMO_WRITE_GEPh5" && hmo_valid_sha256 "$HMO_WRITE_CLIENT" && hmo_valid_sha256 "$HMO_WRITE_SERVICE" || return 1
    HMO_WRITE_TMP="${HMO_WRITE_PATH}.tmp.$$"
    (umask 077; set -C; printf 'format=geph-flatpak-manager-v1\nstate=%s\nowners=%s\npending_uid=%s\ngeph5_sha256=%s\ngeph5_client_sha256=%s\nservice_sha256=%s\n' "$HMO_WRITE_STATE" "$HMO_WRITE_OWNERS" "$HMO_WRITE_PENDING" "$HMO_WRITE_GEPh5" "$HMO_WRITE_CLIENT" "$HMO_WRITE_SERVICE" > "$HMO_WRITE_TMP") || { hmo_error 'could not create temporary ownership record'; return 1; }
    chmod 0600 "$HMO_WRITE_TMP" && mv -f "$HMO_WRITE_TMP" "$HMO_WRITE_PATH" || { rm -f "$HMO_WRITE_TMP"; hmo_error 'could not publish ownership record'; return 1; }
}

hmo_clear_install_transaction() {
    HMO_CLEAR_TXN="$1"
    for HMO_CLEAR_NAME in geph5 geph5-client geph-manager.service manager.identity geph-flatpak-uninstall; do
        rm -f "$HMO_CLEAR_TXN/backup/$HMO_CLEAR_NAME" "$HMO_CLEAR_TXN/$HMO_CLEAR_NAME.state" "$HMO_CLEAR_TXN/$HMO_CLEAR_NAME.backup.tmp"
    done
    rm -f "$HMO_CLEAR_TXN/active" "$HMO_CLEAR_TXN/active.tmp"
    rmdir "$HMO_CLEAR_TXN/backup" 2>/dev/null || true
    rmdir "$HMO_CLEAR_TXN" 2>/dev/null || true
}

hmo_snapshot_install_file() {
    HMO_SNAPSHOT_TXN="$1"; HMO_SNAPSHOT_NAME="$2"; HMO_SNAPSHOT_PATH="$3"
    if [ -e "$HMO_SNAPSHOT_PATH" ] || [ -L "$HMO_SNAPSHOT_PATH" ]; then
        hmo_require_root_owned "$HMO_SNAPSHOT_PATH" file || { hmo_error "cannot snapshot unprotected manager path: $HMO_SNAPSHOT_PATH"; return 1; }
        cp -p "$HMO_SNAPSHOT_PATH" "$HMO_SNAPSHOT_TXN/backup/$HMO_SNAPSHOT_NAME.backup.tmp" || return 1
        mv -f "$HMO_SNAPSHOT_TXN/backup/$HMO_SNAPSHOT_NAME.backup.tmp" "$HMO_SNAPSHOT_TXN/backup/$HMO_SNAPSHOT_NAME" || return 1
        printf 'present\n' > "$HMO_SNAPSHOT_TXN/$HMO_SNAPSHOT_NAME.state"
    else
        printf 'absent\n' > "$HMO_SNAPSHOT_TXN/$HMO_SNAPSHOT_NAME.state"
    fi
}

hmo_begin_install_transaction() {
    HMO_TXN_STATE_DIR="$1"; HMO_TXN_BINDIR="$2"; HMO_TXN_SERVICE="$3"
    HMO_TXN_DIR="$HMO_TXN_STATE_DIR/install-transaction"
    if [ -e "$HMO_TXN_DIR" ] || [ -L "$HMO_TXN_DIR" ]; then
        hmo_error 'an unfinished install transaction must be recovered first'
        return 1
    fi
    (umask 077; mkdir "$HMO_TXN_DIR" && mkdir "$HMO_TXN_DIR/backup") || {
        hmo_clear_install_transaction "$HMO_TXN_DIR"
        hmo_error 'could not create the install transaction journal'
        return 1
    }
    chmod 0700 "$HMO_TXN_DIR" "$HMO_TXN_DIR/backup" && chown root:root "$HMO_TXN_DIR" "$HMO_TXN_DIR/backup" || {
        hmo_clear_install_transaction "$HMO_TXN_DIR"
        hmo_error 'could not protect the install transaction journal'
        return 1
    }
    hmo_snapshot_install_file "$HMO_TXN_DIR" geph5 "$HMO_TXN_BINDIR/geph5" || { hmo_clear_install_transaction "$HMO_TXN_DIR"; return 1; }
    hmo_snapshot_install_file "$HMO_TXN_DIR" geph5-client "$HMO_TXN_BINDIR/geph5-client" || { hmo_clear_install_transaction "$HMO_TXN_DIR"; return 1; }
    hmo_snapshot_install_file "$HMO_TXN_DIR" geph-manager.service "$HMO_TXN_SERVICE" || { hmo_clear_install_transaction "$HMO_TXN_DIR"; return 1; }
    hmo_snapshot_install_file "$HMO_TXN_DIR" manager.identity "$HMO_TXN_STATE_DIR/manager.identity" || { hmo_clear_install_transaction "$HMO_TXN_DIR"; return 1; }
    hmo_snapshot_install_file "$HMO_TXN_DIR" geph-flatpak-uninstall "$HMO_TXN_BINDIR/geph-flatpak-uninstall" || { hmo_clear_install_transaction "$HMO_TXN_DIR"; return 1; }
    (umask 077; printf 'active\n' > "$HMO_TXN_DIR/active.tmp") &&
        mv -f "$HMO_TXN_DIR/active.tmp" "$HMO_TXN_DIR/active" || {
        hmo_clear_install_transaction "$HMO_TXN_DIR"
        hmo_error 'could not activate the install transaction journal'
        return 1
    }
    HMO_INSTALL_TXN_DIR="$HMO_TXN_DIR"
    HMO_INSTALL_TXN_ACTIVE=1
}

hmo_restore_install_file() {
    HMO_RESTORE_TXN="$1"; HMO_RESTORE_NAME="$2"; HMO_RESTORE_PATH="$3"
    HMO_RESTORE_STATE="$(cat "$HMO_RESTORE_TXN/$HMO_RESTORE_NAME.state")" || return 1
    case "$HMO_RESTORE_STATE" in
        present)
            HMO_RESTORE_BACKUP="$HMO_RESTORE_TXN/backup/$HMO_RESTORE_NAME"
            [ -f "$HMO_RESTORE_BACKUP" ] && [ ! -L "$HMO_RESTORE_BACKUP" ] || return 1
            if [ -e "$HMO_RESTORE_PATH" ] || [ -L "$HMO_RESTORE_PATH" ]; then
                hmo_require_root_owned "$HMO_RESTORE_PATH" file || return 1
            fi
            HMO_RESTORE_TMP="$HMO_RESTORE_PATH.restore.$$"
            cp -p "$HMO_RESTORE_BACKUP" "$HMO_RESTORE_TMP" && mv -f "$HMO_RESTORE_TMP" "$HMO_RESTORE_PATH" || {
                rm -f "$HMO_RESTORE_TMP"
                return 1
            }
            ;;
        absent)
            if [ -e "$HMO_RESTORE_PATH" ] || [ -L "$HMO_RESTORE_PATH" ]; then
                hmo_require_root_owned "$HMO_RESTORE_PATH" file || return 1
                rm -f "$HMO_RESTORE_PATH" || return 1
            fi
            ;;
        *) return 1 ;;
    esac
}

hmo_restore_install_transaction() {
    HMO_RECOVER_STATE_DIR="$1"; HMO_RECOVER_BINDIR="$2"; HMO_RECOVER_SERVICE="$3"
    HMO_RECOVER_SYSTEMCTL="$4"
    HMO_RECOVER_TXN="$HMO_RECOVER_STATE_DIR/install-transaction"
    HMO_RECOVER_COMMITTED="$HMO_RECOVER_STATE_DIR/install-committed"
    if [ -e "$HMO_RECOVER_COMMITTED" ] || [ -L "$HMO_RECOVER_COMMITTED" ]; then
        [ -d "$HMO_RECOVER_COMMITTED" ] && [ ! -L "$HMO_RECOVER_COMMITTED" ] || return 1
        hmo_clear_install_transaction "$HMO_RECOVER_COMMITTED"
    fi
    if [ ! -e "$HMO_RECOVER_TXN" ] && [ ! -L "$HMO_RECOVER_TXN" ]; then return 0; fi
    [ -d "$HMO_RECOVER_TXN" ] && [ ! -L "$HMO_RECOVER_TXN" ] || { hmo_error 'install transaction journal is redirected'; return 1; }
    if [ ! -f "$HMO_RECOVER_TXN/active" ]; then
        hmo_clear_install_transaction "$HMO_RECOVER_TXN"
        return 0
    fi
    hmo_require_root_owned "$HMO_RECOVER_TXN" dir || { hmo_error 'install transaction journal is not protected'; return 1; }
    for HMO_RECOVER_NAME in geph5 geph5-client geph-manager.service manager.identity geph-flatpak-uninstall; do
        [ -f "$HMO_RECOVER_TXN/$HMO_RECOVER_NAME.state" ] && [ ! -L "$HMO_RECOVER_TXN/$HMO_RECOVER_NAME.state" ] || {
            hmo_error 'install transaction journal is incomplete; manager retained'
            return 1
        }
    done
    HMO_OLD_SERVICE_STATE="$(cat "$HMO_RECOVER_TXN/geph-manager.service.state")" || return 1
    if [ "$HMO_OLD_SERVICE_STATE" = absent ] && { [ -e "$HMO_RECOVER_SERVICE" ] || [ -L "$HMO_RECOVER_SERVICE" ]; }; then
        if [ -x "$HMO_RECOVER_BINDIR/geph5" ]; then
            "$HMO_RECOVER_BINDIR/geph5" unregister-manager || {
                if [ -e "$HMO_RECOVER_SERVICE" ] || [ -L "$HMO_RECOVER_SERVICE" ]; then
                    hmo_error 'could not stop a partially registered manager; install journal retained'
                    return 1
                fi
            }
        fi
    fi
    hmo_restore_install_file "$HMO_RECOVER_TXN" geph5 "$HMO_RECOVER_BINDIR/geph5" || return 1
    hmo_restore_install_file "$HMO_RECOVER_TXN" geph5-client "$HMO_RECOVER_BINDIR/geph5-client" || return 1
    hmo_restore_install_file "$HMO_RECOVER_TXN" geph-manager.service "$HMO_RECOVER_SERVICE" || return 1
    hmo_restore_install_file "$HMO_RECOVER_TXN" manager.identity "$HMO_RECOVER_STATE_DIR/manager.identity" || return 1
    hmo_restore_install_file "$HMO_RECOVER_TXN" geph-flatpak-uninstall "$HMO_RECOVER_BINDIR/geph-flatpak-uninstall" || return 1
    if [ "$HMO_OLD_SERVICE_STATE" = present ] && [ -x "$HMO_RECOVER_BINDIR/geph5" ]; then
        "$HMO_RECOVER_BINDIR/geph5" register-manager || { hmo_error 'could not restart the prior manager; install journal retained'; return 1; }
        hmo_restore_install_file "$HMO_RECOVER_TXN" geph-manager.service "$HMO_RECOVER_SERVICE" || return 1
    elif [ "$HMO_OLD_SERVICE_STATE" = absent ]; then
        if "$HMO_RECOVER_SYSTEMCTL" is-active --quiet geph-manager.service; then
            hmo_error 'partially installed manager remains active; install journal retained'
            return 1
        else
            HMO_RECOVER_ACTIVE_STATUS=$?
            case "$HMO_RECOVER_ACTIVE_STATUS" in
                3|4) : ;;
                *) hmo_error 'could not verify the partially installed manager stopped'; return 1 ;;
            esac
        fi
    fi
    "$HMO_RECOVER_SYSTEMCTL" daemon-reload || { hmo_error 'could not reload systemd after transaction recovery'; return 1; }
    hmo_clear_install_transaction "$HMO_RECOVER_TXN"
    HMO_INSTALL_TXN_ACTIVE=0
    printf 'Recovered the previous Geph host-manager installation state.\n' >&2
}

hmo_commit_install_transaction() {
    HMO_COMMIT_STATE_DIR="$1"
    HMO_COMMIT_TXN="$HMO_COMMIT_STATE_DIR/install-transaction"
    HMO_COMMIT_DONE="$HMO_COMMIT_STATE_DIR/install-committed"
    [ -d "$HMO_COMMIT_TXN" ] && [ ! -L "$HMO_COMMIT_TXN" ] || return 1
    [ ! -e "$HMO_COMMIT_DONE" ] && [ ! -L "$HMO_COMMIT_DONE" ] || return 1
    mv "$HMO_COMMIT_TXN" "$HMO_COMMIT_DONE" || return 1
    HMO_INSTALL_TXN_ACTIVE=0
    hmo_clear_install_transaction "$HMO_COMMIT_DONE"
}

hmo_check_recorded_files() {
    HMO_CHECK_BINDIR="$1"; HMO_CHECK_SERVICE="$2"
    HMO_GEPh5_PRESENT=0; HMO_CLIENT_PRESENT=0; HMO_SERVICE_PRESENT=0
    if [ -e "$HMO_CHECK_BINDIR/geph5" ] || [ -L "$HMO_CHECK_BINDIR/geph5" ]; then
        hmo_file_sha256 "$HMO_CHECK_BINDIR/geph5" || { hmo_error 'manager executable is not a regular file'; return 1; }
        [ "$HMO_HASH_VALUE" = "$HMO_GEPh5_SHA256" ] || { hmo_error 'manager executable does not match the ownership record'; return 1; }
        HMO_GEPh5_PRESENT=1
    fi
    if [ -e "$HMO_CHECK_BINDIR/geph5-client" ] || [ -L "$HMO_CHECK_BINDIR/geph5-client" ]; then
        hmo_file_sha256 "$HMO_CHECK_BINDIR/geph5-client" || { hmo_error 'engine executable is not a regular file'; return 1; }
        [ "$HMO_HASH_VALUE" = "$HMO_CLIENT_SHA256" ] || { hmo_error 'engine executable does not match the ownership record'; return 1; }
        HMO_CLIENT_PRESENT=1
    fi
    if [ -e "$HMO_CHECK_SERVICE" ] || [ -L "$HMO_CHECK_SERVICE" ]; then
        hmo_file_sha256 "$HMO_CHECK_SERVICE" || { hmo_error 'manager service file is not a regular file'; return 1; }
        [ "$HMO_HASH_VALUE" = "$HMO_SERVICE_SHA256" ] || { hmo_error 'manager service file does not match the ownership record'; return 1; }
        HMO_SERVICE_PRESENT=1
    fi
}

hmo_cleanup_owned_manager() {
    HMO_CLEAN_RECORD="$1"; HMO_CLEAN_BINDIR="$2"; HMO_CLEAN_SERVICE="$3"
    HMO_CLEAN_UID="$4"; HMO_CLEAN_STATE_DIR="$5"; HMO_CLEAN_SYSTEMCTL="${6:-systemctl}"
    HMO_CLEAN_ADMIN_OVERRIDE="${7:-0}"
    hmo_valid_uid "$HMO_CLEAN_UID" || { hmo_error 'requesting UID is invalid'; return 1; }
    case "$HMO_CLEAN_ADMIN_OVERRIDE" in 0|1) : ;; *) hmo_error 'administrator override flag is invalid'; return 1 ;; esac
    [ -e "$HMO_CLEAN_RECORD" ] || { hmo_error 'no Flatpak ownership record; nothing to remove'; return 0; }
    hmo_read_identity "$HMO_CLEAN_RECORD" || return 1
    hmo_check_recorded_files "$HMO_CLEAN_BINDIR" "$HMO_CLEAN_SERVICE" || return 1

    if [ "$HMO_STATE" = uninstalling ]; then
        if [ "$HMO_CLEAN_UID" != 0 ] && [ "$HMO_CLEAN_UID" != "$HMO_PENDING_UID" ]; then
            hmo_error 'another owner is completing manager removal'
            return 1
        fi
    else
        if [ "$HMO_CLEAN_ADMIN_OVERRIDE" -eq 1 ]; then
            [ "$HMO_CLEAN_UID" = 0 ] || { hmo_error 'administrator override requires root'; return 1; }
            HMO_OWNERS_REMAINING=''
        else
            hmo_error 'shared Flatpak ownership is incomplete; use --all only after checking all installations'
            return 1
        fi
        if [ -n "$HMO_OWNERS_REMAINING" ]; then
            hmo_write_identity "$HMO_CLEAN_RECORD" installed "$HMO_OWNERS_REMAINING" '' "$HMO_GEPh5_SHA256" "$HMO_CLIENT_SHA256" "$HMO_SERVICE_SHA256" || return 1
            printf 'Geph host manager kept for remaining owners: %s\n' "$HMO_OWNERS_REMAINING"
            return 0
        fi
        hmo_write_identity "$HMO_CLEAN_RECORD" uninstalling '' "$HMO_CLEAN_UID" "$HMO_GEPh5_SHA256" "$HMO_CLIENT_SHA256" "$HMO_SERVICE_SHA256" || return 1
    fi

    # A previous attempt may already have removed the unit file. The exact
    # manager hash is checked above before this command is allowed to run.
    if [ "$HMO_GEPh5_PRESENT" -eq 1 ]; then
        if "$HMO_CLEAN_BINDIR/geph5" unregister-manager; then
            :
        elif [ -e "$HMO_CLEAN_SERVICE" ] || [ -L "$HMO_CLEAN_SERVICE" ]; then
            hmo_error 'manager refused to unregister; keeping binaries and ownership record'
            return 1
        fi
    elif [ "$HMO_SERVICE_PRESENT" -eq 1 ]; then
        hmo_error 'manager binary is missing while its service is still installed'
        return 1
    fi
    if [ -e "$HMO_CLEAN_SERVICE" ] || [ -L "$HMO_CLEAN_SERVICE" ]; then
        hmo_error 'manager service is still present after unregister'
        return 1
    fi
    if "$HMO_CLEAN_SYSTEMCTL" is-active --quiet geph-manager.service; then
        hmo_error 'manager service is still active; keeping binaries and ownership record'
        return 1
    else
        HMO_SYSTEMCTL_STATUS=$?
        case "$HMO_SYSTEMCTL_STATUS" in
            3|4) : ;;
            *) hmo_error 'could not verify manager service state; keeping binaries and ownership record'; return 1 ;;
        esac
    fi
    "$HMO_CLEAN_SYSTEMCTL" daemon-reload || { hmo_error 'systemd reload failed; retry the explicit uninstall'; return 1; }
    [ "$HMO_GEPh5_PRESENT" -eq 0 ] || rm -f "$HMO_CLEAN_BINDIR/geph5"
    [ "$HMO_CLIENT_PRESENT" -eq 0 ] || rm -f "$HMO_CLEAN_BINDIR/geph5-client"
    rm -f "$HMO_CLEAN_RECORD" || { hmo_error 'could not remove ownership record'; return 1; }
    rmdir "$HMO_CLEAN_STATE_DIR" 2>/dev/null || true
    printf 'Geph host manager removed for the final owner.\n'
}

hmo_explicit_uninstall() {
    set -eu
    HMO_BINDIR=/usr/local/bin
    HMO_STATE_DIR=/var/lib/geph-flatpak
    HMO_IDENTITY="$HMO_STATE_DIR/manager.identity"
    HMO_LOCK_DIR="$HMO_STATE_DIR/lifecycle.lock"
    HMO_SERVICE=/etc/systemd/system/geph-manager.service
    HMO_SCRIPT=/usr/local/bin/geph-flatpak-uninstall
    HMO_SYSTEMCTL=/usr/bin/systemctl
    HMO_ADMIN_OVERRIDE=0
    if [ "$#" -eq 0 ]; then
        HMO_REQUEST_UID="${PKEXEC_UID:-0}"
    elif [ "$#" -eq 1 ] && [ "$1" = --all ]; then
        HMO_REQUEST_UID=0
        HMO_ADMIN_OVERRIDE=1
    else
        hmo_error 'usage: geph-flatpak-uninstall [--all]'
        return 2
    fi
    [ "$(id -u)" -eq 0 ] || { hmo_error 'run this command through pkexec'; return 1; }
    hmo_valid_uid "$HMO_REQUEST_UID" || { hmo_error 'pkexec caller UID is invalid'; return 1; }
    hmo_require_root_owned "$HMO_SCRIPT" file || { hmo_error 'uninstaller path is not root-owned and protected'; return 1; }
    hmo_require_root_owned "$HMO_BINDIR" dir || { hmo_error 'manager directory is not root-owned and protected'; return 1; }
    [ ! -e "$HMO_STATE_DIR" ] && [ ! -L "$HMO_STATE_DIR" ] && {
        printf 'No Flatpak ownership record; nothing to remove.\n'
        return 0
    }
    hmo_require_root_owned "$HMO_STATE_DIR" dir || { hmo_error 'ownership directory is not root-owned and protected'; return 1; }
    hmo_acquire_lifecycle_lock "$HMO_LOCK_DIR" || return 1
    trap 'hmo_release_lifecycle_lock' EXIT
    hmo_require_root_owned "$HMO_LOCK_DIR" dir || { hmo_error 'lifecycle lock is not root-owned and protected'; return 1; }
    hmo_require_root_owned "$HMO_LOCK_DIR/pid" file || { hmo_error 'lifecycle lock owner record is not root-owned and protected'; return 1; }
    hmo_restore_install_transaction "$HMO_STATE_DIR" "$HMO_BINDIR" "$HMO_SERVICE" "$HMO_SYSTEMCTL" || {
        hmo_error 'could not recover the previous install transaction; manager retained'
        return 1
    }
    if [ -e "$HMO_IDENTITY" ] || [ -L "$HMO_IDENTITY" ]; then
        hmo_require_root_owned "$HMO_IDENTITY" file || { hmo_error 'ownership record is not root-owned and protected'; return 1; }
    fi
    for HMO_PATH in "$HMO_BINDIR/geph5" "$HMO_BINDIR/geph5-client" "$HMO_SERVICE"; do
        if [ -e "$HMO_PATH" ] || [ -L "$HMO_PATH" ]; then
            hmo_require_root_owned "$HMO_PATH" file || { hmo_error "manager path is not root-owned and protected: $HMO_PATH"; return 1; }
        fi
    done
    hmo_require_root_owned /etc/systemd/system dir || { hmo_error 'systemd unit directory is not root-owned and protected'; return 1; }
    [ -x "$HMO_SYSTEMCTL" ] || { hmo_error 'systemctl is unavailable; manager retained'; return 1; }
    HMO_UNINSTALL_STATUS=0
    hmo_cleanup_owned_manager "$HMO_IDENTITY" "$HMO_BINDIR" "$HMO_SERVICE" "$HMO_REQUEST_UID" "$HMO_STATE_DIR" "$HMO_SYSTEMCTL" "$HMO_ADMIN_OVERRIDE" || HMO_UNINSTALL_STATUS=$?
    hmo_release_lifecycle_lock
    trap - EXIT
    return "$HMO_UNINSTALL_STATUS"
}

# The GUI's pinned bootstrap still stages this file under its historical
# watchdog name. In library mode it supplies ownership functions to the
# installer; when installed as geph-flatpak-uninstall, the owner action accepts
# no arguments and an administrator-wide action accepts --all. Legacy timer
# invocations with arguments are harmless no-ops.
if [ "${HMO_LIBRARY_ONLY:-0}" != 1 ]; then
    if [ "${0##*/}" != geph-flatpak-uninstall ]; then
        printf '%s\n' 'Automatic Geph host-manager cleanup is disabled. Use pkexec /usr/local/bin/geph-flatpak-uninstall after removing all Flatpak owners.' >&2
        exit 0
    fi
    hmo_explicit_uninstall "$@" || exit $?
fi
