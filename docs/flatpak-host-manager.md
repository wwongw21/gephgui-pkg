# Flatpak host-manager migration and removal

The Geph Flatpak uses a shared host manager at `/usr/local/bin/geph5` and
`/usr/local/bin/geph5-client`, with the `geph-manager.service` system unit.
Flatpak users can share that manager. The pinned GUI bootstrap skips its
installer when the manager is healthy and its binaries match, so a root-owned
record cannot reliably prove that it has seen every user. The record therefore
marks ownership as unknown; ordinary per-user cleanup keeps the manager.

After installing a Flatpak release that includes these actions, use the
**Migrate Geph host manager** desktop action once on each host that already has
a Geph manager. This explicit action stages the current packaging files and
runs the existing privileged installer. It also disables and removes the old
app-data cleanup timer, installs the host removal command, and refreshes the
manager identity record. A package update alone may not run the installer when
the manager binaries have not changed, so do this migration before removing the
Flatpak. It may restart the host manager.

The **Remove shared Geph host manager for all users** desktop action is an
administrator-wide removal. Use it only after checking that no user or Flatpak
installation still needs the manager. It removes only the recorded Geph
binaries and service whose hashes match the root-owned identity record. It
preserves Flatpak app data and refuses damaged records or files that no longer
match that identity.

After the migration action has installed the host command, it remains available
after the Flatpak is removed:

```sh
sudo /usr/local/bin/geph-flatpak-uninstall --all
```

The `--all` form requires root because it can remove a manager used by any
Flatpak user. Without `--all`, the command refuses when the ownership set is
unknown. The installer and removal command require the util-linux flock
command. They stop before changing host files if it is missing. Both use the
same root-owned lock file; the kernel releases the lock when its owner exits,
and the file stays in place through final removal so later operations use the
same lock.

Before changing a legacy install, the migration journal records the existing
manager and the old cleanup service, timer, and watchdog. If disabling the old
timer, reloading systemd, copying files, registering the manager, or writing
the new identity fails, the installer restores that recorded state. Retry the
desktop migration action after the problem is fixed.

The installer refuses to replace an existing manager without a matching
Flatpak identity record, rejects a manager service in another systemd unit
directory, and never uses app-data presence or deletion as an install signal.
