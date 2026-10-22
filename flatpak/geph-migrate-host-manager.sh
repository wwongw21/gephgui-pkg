#!/bin/sh
# Explicitly reconcile the host manager after a Flatpak packaging update.
# The pinned GUI bootstrap skips its installer when the manager is healthy, so
# this desktop action stages the same assets and invokes the existing contract.
set -eu

DATA_HOME="${XDG_DATA_HOME:-${HOME:?HOME is required}/.local/share}"
case "$DATA_HOME" in /*) ;; *) printf '%s\n' 'Geph migration requires an absolute XDG data directory.' >&2; exit 1 ;; esac
mkdir -p "$DATA_HOME"
STAGING="$(mktemp -d "$DATA_HOME/geph-host-install.XXXXXX")"
trap 'rm -rf -- "$STAGING"' EXIT
trap 'exit 1' HUP INT TERM

install -m 0755 /app/bin/geph5 "$STAGING/geph5"
install -m 0755 /app/bin/geph5-client "$STAGING/geph5-client"
install -m 0755 /app/libexec/geph/install-host-manager.sh "$STAGING/install-host-manager.sh"
install -m 0755 /app/libexec/geph/geph-flatpak-watchdog.sh "$STAGING/geph-flatpak-watchdog.sh"
install -m 0644 /app/libexec/geph/geph-cleanup.service "$STAGING/geph-cleanup.service"
install -m 0644 /app/libexec/geph/geph-cleanup.timer "$STAGING/geph-cleanup.timer"

flatpak-spawn --host pkexec "$STAGING/install-host-manager.sh" "$STAGING" "$HOME"
