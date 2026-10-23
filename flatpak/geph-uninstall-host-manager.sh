#!/bin/sh
# App-side entry point for the explicit global host-manager removal action.
set -eu
if ! zenity --question \
    --title='Remove the shared Geph host manager?' \
    --text='This removes the host manager for every user. Continue only if no Geph Flatpak installation still needs it.'; then
    exit 0
fi
exec flatpak-spawn --host pkexec /usr/local/bin/geph-flatpak-uninstall --all
