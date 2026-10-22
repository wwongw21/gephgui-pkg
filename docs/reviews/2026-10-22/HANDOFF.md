# gephgui-pkg engineering handoff

Review date: **22 October 2026**. All findings remain **OPEN**. This handoff contains proposed repairs and release checks; no source fixes or new runtime acceptance are claimed.

**Reviewed source:** [`master` at `f3a248b2aefe31158ebd1d1ecae1f689e604fdfe`](https://github.com/wwongw21/gephgui-pkg/tree/f3a248b2aefe31158ebd1d1ecae1f689e604fdfe).

The full structured handoff is in [report.json](report.json). Historical commands retain their original review-workspace paths; read the prerequisites before running them. Only repository-specific diagnostics listed below are attached.

## Audience and required outcome

### Audience

1. Packaging maintainer

2. Release engineer

3. Maintainer of the privileged Geph host manager integration

### Outcome

Give maintainers a concrete repair and release handoff for invalid native package versions and unreliable Flatpak host-manager removal. All changes below are proposed and OPEN; no repository code was changed.

## Scope and reviewed branches

All owned build scripts, Windows Inno installer, Debian maintainer scripts, macOS installer/uninstaller, Flatpak manifest/host installer/watchdog, CI workflow and submodule declarations reviewed. Vendored binary blobs were not reverse engineered; gitlink dependency source trees were not fetched.

## Architecture

### Purpose

Build a Geph GUI, privileged manager and engine into Windows, macOS, Debian and Flatpak distributables.

### Components

#### Item 1

##### Paths

1. build-common.bash

##### Responsibility

Stage source trees in a machine-local build root, retain incremental caches, build the frontend, and publish finished artifacts using a temporary file plus rename.

#### Item 2

##### Paths

1. gephgui-wry

2. geph5

3. .gitmodules

##### Responsibility

Pinned upstream source dependencies. gephgui-wry gitlink is 2590443988e2a944751796f2066d317bfefdf29e; geph5 is 3b7bc1a6ff5c34093353fe0f53bcdfd8d6971649. The GUI embeds its built frontend; the manager locates the engine beside its executable.

##### Review limit

Gitlink trees were not populated or reviewed in this pass.

#### Item 3

##### Paths

1. build-windows.bash

2. windows/setup.iss

##### Responsibility

Build i686 binaries, optionally sign them, compile an elevated Inno installer, register the manager service, and unregister it before removal. The installer consumes a numeric VERSION_NUM separately from the display VERSION.

#### Item 4

##### Paths

1. build-macos.bash

2. macos/pkg-scripts/preinstall

3. macos/pkg-scripts/postinstall

4. macos/uninstall.sh

##### Responsibility

Build per-architecture binaries, assemble the application, optionally sign/notarize, install into /Applications/Geph.app, register a root LaunchDaemon, and supply an explicit uninstaller.

#### Item 5

##### Paths

1. build-deb.bash

2. debian/build-deb-inner.sh

##### Responsibility

Build inside an Ubuntu 22.04 container, generate package control metadata, place the GUI/manager/engine in /usr/bin, and register/unregister the manager through Debian maintainer scripts.

#### Item 6

##### Paths

1. build-flatpak.bash

2. flatpak/io.geph.GephGui.yml

3. flatpak/install-host-manager.sh

4. flatpak/geph-flatpak-watchdog.sh

5. flatpak/geph-cleanup.service

6. flatpak/geph-cleanup.timer

##### Responsibility

Build the sandboxed GUI and bundle host-runnable manager/engine binaries. A privileged installer copies the host binaries into /usr/local/bin, registers the manager and a cleanup timer; the watchdog currently infers installation solely from an app-data directory.

#### Item 7

##### Paths

1. .github/workflows/build.yaml

##### Responsibility

Run four native builds and publish prerelease artifacts for version tags. The reviewed fork has no recorded CI runs according to the separate connector check supplied by the parent reviewer.

### Important contracts

1. Machine-local staging must continue to keep concurrent OS builds from mutating shared frontend or Cargo intermediates.

2. The manager and engine must remain siblings on every installed platform.

3. A packaging-owned uninstall operation must identify the installed manager it owns before unregistering or deleting it.

4. Display identifiers may include a git hash; native package fields must obey their platform version grammar.

## Prioritized sequence

### Item 1

#### Order

1

#### Status

OPEN

#### Work

Resolve and validate native version semantics before compiling. This removes the demonstrated packaging blocker.

#### Depends on

None recorded.

### Item 2

#### Order

2

#### Status

OPEN

#### Work

Trace the pinned bootstrap/manager integration and choose Flatpak host ownership behavior; implement the reconciliation or explicit uninstall repair.

#### Depends on

None recorded.

### Item 3

#### Order

3

#### Status

OPEN

#### Work

Run targeted version and ownership regression cases, then one clean build per supported platform with complete pinned submodules.

#### Depends on

1. 1

2. 2

### Item 4

#### Order

4

#### Status

OPEN

#### Work

Validate install, upgrade, disconnect/restoration and uninstall in disposable native environments; verify only owned services and paths are changed.

#### Depends on

1. 3

### Item 5

#### Order

5

#### Status

OPEN

#### Work

Inspect signed/notarized release metadata, retain checksums and test receipts, and review the concrete candidate before publication.

#### Depends on

1. 4

## Limits and mitigations

### Item 1

#### Limit

Pinned runtime/frontend gitlinks not reviewed

#### Mitigation

Populate exact gitlinks and inspect manager registration, engine lookup and bootstrap argument contracts before changing integration.

### Item 2

#### Limit

Full native builds and lifecycle tests unrun

#### Mitigation

Treat repaired artifacts as candidates until platform-specific build/install/upgrade/uninstall receipts exist.

### Item 3

#### Limit

Vendored executables and DLLs not reverse engineered or vulnerability-scanned

#### Mitigation

Retain provenance/hashes and perform a separate current dependency assessment when preparing a release.

### Item 4

#### Limit

No shellcheck installed

#### Mitigation

The current result establishes Bash parsing only; add the repository's chosen shell lint check when running release validation.

## Findings and implementation handoff

### VPN-1 High: The current untagged checkout generates invalid native package versions

**Status:** OPEN. [Pinned source](https://github.com/wwongw21/gephgui-pkg/blob/f3a248b2aefe31158ebd1d1ecae1f689e604fdfe/debian/build-deb-inner.sh#L24).

#### Evidence classification

Confirmed for Debian; strongly supported for Windows

#### Observed mechanism

The repository has zero remote tags (git ls-remote --tags origin). At the reviewed HEAD git describe --always returns f3a248b. The Debian build removes only an optional leading v, then writes f3a248b into DEBIAN/control Version. A local minimal control fixture with that exact value fails dpkg-deb --build with exit 2: 'Version field value f3a248b: version number does not start with digit'. The Windows path computes VERSION_NUM=f3a248b.0 and passes it to Inno Setup VersionInfoVersion, which accepts only a numeric quad (also acknowledged by the script comments).

#### Impact and scope

Current default-branch Debian builds cannot produce an installable package; Windows installer compilation also receives an invalid version. CI explicitly runs these paths for master pushes/PRs.

#### Repair direction

Separate semantic/numeric package version from the git display identifier. Supply a validated release version and valid untagged development fallback, such as Debian 0.0.0+git.<sha> and Windows 0.0.0.0; retain the SHA in display/build metadata. Add cheap package-version checks before compiling.

#### Verification already obtained

Confirmed with git describe, remote tag enumeration, and an actual dpkg-deb fixture build (exit 2). Full native builds were not run; Windows Inno compilation was not available. Regression validation should cover an untagged checkout, an annotated release tag, a lightweight release tag, and commits after a release tag.

#### Evidence classification

Confirmed Debian failure; Windows rejection strongly supported by the generated nonnumeric value and Inno's numeric VersionInfoVersion contract

#### Source locations

##### Item 1

###### Path

debian/build-deb-inner.sh

###### Lines

24-25, 43

###### Meaning

Use git describe --always, remove only v, and write that value into control Version.

##### Item 2

###### Path

build-windows.bash

###### Lines

16, 133-137

###### Meaning

Derive VERSION_NUM by stripping v and a suffix, then append .0.

##### Item 3

###### Path

windows/setup.iss

###### Lines

17-23

###### Meaning

Pass VERSION_NUM into the numeric-only VersionInfoVersion field.

##### Item 4

###### Path

.github/workflows/build.yaml

###### Lines

119-120, 169-174

###### Meaning

Default-branch CI invokes these build paths without supplying a separate semantic version.

#### Observed failure

This repository has zero remote tags. At the pinned HEAD, git describe --always returns f3a248b. Debian receives Version=f3a248b and dpkg-deb exits 2 because it does not start with a digit. Windows receives VERSION_NUM=f3a248b.0, which is not a numeric quad.

#### User impact

Maintainers cannot build a Debian artifact from the current default branch using the documented build entry point; Windows installer compilation also receives invalid version metadata. This blocks ordinary branch builds before usable artifacts can be produced.

#### Repair

##### Preferred change

Define validated native package versions independently of the git display identifier. Require an explicit release semantic version or a recognized release tag; for an untagged development checkout generate a valid fallback such as Debian 0.0.0+git.<sha> and Windows 0.0.0.0. Preserve git describe output in artifact/display build metadata. Validate versions before expensive compilation.

##### Change surface

1. build-common.bash: own shared version resolution/validation or expose clearly named outputs

2. build-deb.bash and debian/build-deb-inner.sh: consume Debian-native version

3. build-windows.bash and windows/setup.iss: consume validated numeric quad

4. .github/workflows/build.yaml: pass explicit release version on tag builds and exercise the untagged path

5. build-macos.bash: audit and explicitly define Apple bundle/package version use while changing the shared contract

##### Invariants

1. The current checkout's SHA remains visible in development build metadata.

2. A release build cannot silently fall back to a development version after malformed input.

3. Windows numeric components satisfy Inno's accepted bounds and component count.

4. Debian development ordering is intentional and does not masquerade as the next release.

5. A VERSION override has a documented meaning; existing signing/publication behavior is preserved unless separately approved.

##### Acceptance criteria

1. An untagged checkout resolves valid Debian and Windows native versions before compilation.

2. A valid release tag resolves to the intended package release version.

3. Malformed or unsupported version input fails early with an actionable error.

4. A minimal Debian package using the generated control Version builds successfully.

5. A clean Windows Inno compilation accepts generated VERSION_NUM.

6. The resulting UI/artifact metadata still identifies the reviewed commit.

##### Regression cases

1. No tags available, including this f3a248b checkout

2. Annotated vX.Y.Z tag

3. Lightweight vX.Y.Z tag: explicitly support or reject with explanation; plain git describe does not select lightweight tags by default

4. Commit after the latest release tag

5. Prerelease/build metadata

6. Malformed VERSION override

7. SHA beginning with a letter versus a digit

8. Numeric components outside Inno's allowed range

##### Risks

1. Version-order changes can prevent expected upgrades or accidentally make a development build appear newer than a release.

2. A shared version refactor can change macOS bundle metadata or updater comparisons; these consumers must be checked against actual upstream expectations.

##### Rollback

Revert the version-resolution change as one unit and retain the last known valid signed artifacts. Reverting source does not repair already published metadata; do not publish replacement artifacts under an existing immutable version.

#### Verification

##### Already observed

1. git describe --always -> f3a248b

2. git ls-remote --tags origin -> zero lines

3. Actual local dpkg-deb fixture with Version=f3a248b -> exit 2: version number does not start with digit

##### Exact reproduction prerequisites

1. Pinned local checkout

2. Git

3. Python 3

4. dpkg-deb; no project build dependencies or network required for the minimal rejection fixture

##### Commands

###### Item 1

**Command**

```
git -C /workspace/repos/gephgui-pkg describe --always
```

**Expected current**

f3a248b

**Status**

ALREADY_RUN

###### Item 2

**Command**

```
git -C /workspace/repos/gephgui-pkg ls-remote --tags origin
```

**Expected current**

Empty output

**Status**

ALREADY_RUN; requires GitHub network access if repeated

###### Item 3

**Command**

```
Create a temporary pkg/DEBIAN/control containing Package: gephgui-wry, Version: f3a248b, Architecture: amd64, Maintainer and Description, then run dpkg-deb --build <temp>/pkg <temp>/out.deb
```

**Expected current**

Exit 2 with invalid Version error

**Status**

ALREADY_RUN; fixture was temporary and removed

##### Proposed postrepair checks

1. Validate generated versions without compiling

2. Build minimal Debian control fixture with the generated value

3. Run clean Windows Inno installer compile

4. Build actual platform packages and inspect installed/display/updater version metadata

##### Not run

1. Full Debian Docker build

2. Windows Inno/native build

3. macOS packaging and updater compatibility

### VPN-2 Medium: Ordinary Flatpak removal leaves the privileged host manager installed indefinitely

**Status:** OPEN. [Pinned source](https://github.com/wwongw21/gephgui-pkg/blob/f3a248b2aefe31158ebd1d1ecae1f689e604fdfe/flatpak/geph-flatpak-watchdog.sh#L13).

#### Evidence classification

Strongly supported by actual watchdog execution and Flatpak's documented deletion semantics

#### Observed mechanism

The watchdog equates the existence of ~/.var/app/io.geph.GephGui with continued installation and exits at line 17. Flatpak retains application data during ordinary uninstall; deleting it is the separate --delete-data option. The current upstream command documentation states this option removes app data in ~/.var/app (flatpak/flatpak doc/flatpak-uninstall.xml, file blob cc29c049667b6369ba2a8a429facbdd2ed0fec62). An actual safe invocation of the unchanged watchdog with an existing retained data directory and no installed binaries returns 0 immediately, without attempting unregister-manager.

#### Impact and scope

After a normal flatpak uninstall, the privileged Geph manager/service, engine binaries and cleanup timer remain installed and potentially running. The advertised automatic uninstall cleanup never occurs unless the user separately deletes app data.

#### Repair direction

Determine actual app installation state across the relevant user/system Flatpak installations, retaining manager ownership for other users, or provide an explicit supported host-manager uninstall action. Do not use app-data presence as the install-state signal.

#### Verification already obtained

Executed the current watchdog safely against a temporary existing app-data directory, confirming immediate successful no-op. Consulted current Flatpak source documentation and option declaration. A full flatpak install/uninstall cycle and privileged service removal were not run. Regression validation should exercise both normal uninstall and --delete-data, with multiple-user ownership considered.

#### Evidence classification

Strongly supported by source, actual watchdog execution, and current upstream Flatpak deletion semantics

#### Source locations

##### Item 1

###### Path

flatpak/geph-flatpak-watchdog.sh

###### Lines

13-17

###### Meaning

Exit while the app-data directory exists, regardless of actual installed application state.

##### Item 2

###### Path

flatpak/install-host-manager.sh

###### Lines

22-39

###### Meaning

Install /usr/local/bin manager/engine, register its service, and enable the cleanup timer.

##### Item 3

###### Path

flatpak/geph-cleanup.service

###### Lines

7

###### Meaning

Pass the data directory as the watchdog's sole ownership signal.

#### Observed failure

Normal Flatpak uninstall retains ~/.var/app data; --delete-data is a separate option. The unchanged watchdog returns successful no-op when that retained directory exists, even with no installed binaries in the supplied temporary bindir.

#### User impact

A user who removes the Flatpak can retain an installed and potentially running privileged host manager, engine, and cleanup timer indefinitely. Deleting app data while the Flatpak remains installed is also not reliable proof that the host manager should be removed.

#### Repair

##### Preferred change

Replace the data-directory heuristic with explicit packaging ownership and verified installation state. Record the owning user/installation context in a root-owned record during privileged installation, reconcile all supported owners, and unregister only the matching packaging-owned host manager after no owner remains. If reliable cross-installation reconciliation cannot be implemented and tested immediately, replace the automatic promise with an explicit supported host-manager uninstall action; do not retain destructive automation keyed only to app-data deletion.

##### Open design decision

Choose and document ownership when user/system Flatpaks, multiple users, or a Debian-managed host service coexist. The existing global service and /usr/local/bin paths do not encode this ownership. This handoff does not authorize a new service architecture.

##### Change surface

1. flatpak/install-host-manager.sh: persist validated installation/owner context and manager identity

2. flatpak/geph-flatpak-watchdog.sh: query installation state and reconcile owners before removal

3. flatpak/geph-cleanup.service and geph-cleanup.timer: pass a root-owned ownership record instead of raw app-data existence

4. Flatpak bootstrap contract in pinned gephgui-wry dependency: inspect and coordinate argument changes; dependency source was not reviewed here

5. User-facing Flatpak installation/removal documentation or explicit uninstall entry point

##### Invariants

1. Retaining app data after uninstall does not prevent removal of an otherwise unowned host manager.

2. Deleting app data alone does not remove a manager still needed by an installed application.

3. One user removing a Flatpak does not remove a manager still needed by another supported owner.

4. A Flatpak cleanup operation never unregisters an unrelated Debian or manually installed manager.

5. Unknown installation state or unreadable ownership metadata retains the manager and reports a diagnostic rather than guessing.

6. Cleanup is idempotent and does not broaden deletion outside exact packaging-owned files/services.

7. Ownership records and executable paths consumed by a privileged cleanup action cannot be replaced by an unprivileged user.

##### Acceptance criteria

1. Normal uninstall with retained data eventually cleans an unowned packaging manager, or the documented explicit uninstall action demonstrably does so.

2. Uninstall with --delete-data produces the same host cleanup result.

3. Data reset while the app remains installed does not tear down the manager.

4. Multiple-user and user/system installation cases follow the documented ownership policy.

5. An unrelated host-manager service survives the cleanup test.

6. Interrupted or repeated cleanup converges without deleting foreign policy, data, or executables.

##### Regression cases

1. Installed app with existing data

2. Removed app with retained data

3. Removed app with --delete-data

4. Installed app whose data was manually removed

5. Two supported users, one uninstalls

6. System and user installs coexist

7. Flatpak metadata query fails

8. Ownership record missing/corrupt/redirected

9. Manager binary/service belongs to another packaging method

10. Partial cleanup and retry

##### Risks

1. Incorrect owner reconciliation can remove a live privileged networking manager and disrupt connectivity.

2. Running per-user Flatpak queries from a root cleanup context requires deliberate user/installation selection.

3. The existing argument-templating/bootstrap contract lives partly in a separate gitlink dependency and must be traced before changing installer arguments.

##### Rollback

Restore prior installer assets only with automatic destructive cleanup disabled until ownership is verified. Keep the explicit manager removal route available. Preserve root-owned ownership records and service identity evidence across rollback; do not delete retained user app data as a cleanup workaround.

#### Verification

##### Already observed

1. Executed /bin/sh flatpak/geph-flatpak-watchdog.sh <existing-temp-data-dir> <absent-temp-bindir>: exit 0 with no unregister attempt

2. Read current upstream flatpak/flatpak doc/flatpak-uninstall.xml: --delete-data separately removes app data in ~/.var/app; fetched file blob cc29c049667b6369ba2a8a429facbdd2ed0fec62

3. Read upstream app/flatpak-builtins-uninstall.c option declaration: opt_delete_data is separately opt-in

##### Exact reproduction prerequisites

1. Pinned source

2. /bin/sh

3. An existing temporary owner/app-data directory

##### Commands

###### Item 1

**Command**

```
/bin/sh /workspace/repos/gephgui-pkg/flatpak/geph-flatpak-watchdog.sh <existing-temp-data-dir> <absent-temp-bindir>
```

**Expected current**

Exit 0 without touching the absent bindir or calling unregister-manager

**Status**

ALREADY_RUN; only use the existing-directory branch for this unprivileged reproduction

##### Proposed postrepair checks

1. Exercise pure ownership/installation-state reconciliation with command doubles

2. Run full installation/removal cases in a disposable Linux VM with controlled service ownership

3. Inspect manager process, binaries, systemd unit/timer and retained app data before and after each removal mode

##### Not run

1. Actual Flatpak install/uninstall

2. Privileged manager registration/removal

3. Multi-user lifecycle

4. Mixed Debian/Flatpak ownership

## Checks already completed

### Historical shell syntax claim and correction

The original report recorded this command as `PASS; syntax only`:

```sh
bash -n build-common.bash build-windows.bash build-macos.bash build-deb.bash debian/build-deb-inner.sh build-flatpak.bash macos/pkg-scripts/preinstall macos/pkg-scripts/postinstall macos/uninstall.sh
```

Bash parses the first file named after its options. It treats later file names as arguments to that first script, so this one command does not check all nine listed files. The original PASS is kept as history, but it does not prove that the other eight files passed syntax checks. No per-file log from that earlier run was retained.

### Fresh per-file Bash syntax check

The portable runner is [check-bash-syntax.sh](check-bash-syntax.sh). Run it from any directory inside a Git checkout of this repository; it does not need a full history or network access:

```sh
bash docs/reviews/2026-10-22/check-bash-syntax.sh docs/reviews/2026-10-22/bash-syntax-check.log
```

The runner checks each worktree file against the Git blob recorded for source revision `f3a248b2aefe31158ebd1d1ecae1f689e604fdfe` before starting a separate `bash -n` process for that file. The fresh run used GNU bash, version 5.3.15(1)-release (x86_64-pc-cygwin). All 12 files matched the pinned source and returned exit code 0.

| Script | Git blob at pinned source | Result |
| --- | --- | --- |
| `build-common.bash` | `0e489d0b02a7fadbe49f71822ca74280f874f0ab` | PASS (exit 0) |
| `build-windows.bash` | `92bf618be3bb6b2526559d1c689f1d172bac620c` | PASS (exit 0) |
| `build-macos.bash` | `1c99b55465fa1dae85dbcaf20610ec300332870c` | PASS (exit 0) |
| `build-deb.bash` | `de2e9508b41bf5c978615fd89407854410c0e5e7` | PASS (exit 0) |
| `debian/build-deb-inner.sh` | `2150a2022038733cbe68fadff3f55f7b175897fc` | PASS (exit 0) |
| `build-flatpak.bash` | `b1b27cbf0aaeecb1c29154f8e655c8b81b570d37` | PASS (exit 0) |
| `flatpak/install-host-manager.sh` | `d375cd28d3c070d6c53747b80aaec16418a9e5af` | PASS (exit 0) |
| `flatpak/geph-flatpak-watchdog.sh` | `db874ad1937eda83cd0940f2bc12fad4ae38e988` | PASS (exit 0) |
| `macos/create-dmg` | `30646249b72365390d43c5fae8d0f1a22d79ef14` | PASS (exit 0) |
| `macos/pkg-scripts/preinstall` | `a8d66f03410fc7760acbd472dea2a83d9fc38017` | PASS (exit 0) |
| `macos/pkg-scripts/postinstall` | `a8f72a47ddab100b65ba11d3a4f8560fcd132795` | PASS (exit 0) |
| `macos/uninstall.sh` | `f8a88860cd740360c9690bf5631c687e2cf2d93f` | PASS (exit 0) |

The full output is in [bash-syntax-check.log](bash-syntax-check.log). [bash-syntax-check.sha256](bash-syntax-check.sha256) records SHA-256 digests for the runner and log. The repository [`.gitattributes`](../../../.gitattributes) keeps all three files in LF format, including on Windows when `core.autocrlf` is enabled, so the recorded digests and Bash runner remain usable after checkout. Git confirmed `text=set` and `eol=lf` for all three files with `core.autocrlf=true`. This check only parses syntax. It does not execute scripts, build packages, or validate installation and removal behavior.

### Other historical checks

The original review recorded that its source worktrees were clean and evidence was stored outside them. That described the earlier source-only review state. This handoff-repair branch now intentionally includes the runner, log and hash manifest under this review directory. The pinned source files checked above match their recorded Git blob IDs.

The focused invalid-version and retained-data watchdog reproductions remain recorded as completed in the original review. This documentation repair did not repeat them.

## Evidence files

1. `check-bash-syntax.sh` — portable per-file runner
2. `bash-syntax-check.log` — fresh output, source revision, per-file pins and exit codes
3. `bash-syntax-check.sha256` — SHA-256 digests for the runner and log
4. Repository-root `.gitattributes` — keeps the runner and evidence files in LF format on checkout

The earlier external `vpn.json` diagnostic was not included in this checkout.

## Delivery and diagnostic files

### Destination repository

wwongw21/gephgui-pkg

### Status

All findings remain OPEN; this change corrects and extends the engineering handoff. It does not apply package or lifecycle repairs.

### Portable evidence

The syntax runner, log and hash manifest are stored under this review directory. The log records the pinned source revision and a Git blob ID for every checked script. The root `.gitattributes` file keeps the runner and both evidence files in LF format when `core.autocrlf` is enabled. The original combined Bash command and its reported PASS remain visible as history with the limitation explained above.

### Diagnostics included

1. `check-bash-syntax.sh`
2. `bash-syntax-check.log`
3. `bash-syntax-check.sha256`
4. `.gitattributes`

### Not included

Original environments, model weights, user data and complete source snapshots are not included. Clone the pinned source and follow the recorded prerequisites. Bug-demonstration scripts intentionally assert pre-fix behavior; they are not a post-fix passing suite.


## Remaining review limits

1. Full Windows/macOS/Debian/Flatpak packages not built.

2. Gitlink dependencies geph5, gephgui-wry and shared-modules were not populated or reviewed; packaging-layer source only.

3. Native installation, upgrade, service registration, network restoration and privileged uninstall were not executed.

4. No shellcheck executable available.

5. Connected repository has zero CI runs as reported by parent reviewer.

## Completion boundary

This is an implementation/release handoff. Every repair remains OPEN. No fixes, releases, privileged host changes, issues, or pull requests were created.

## Delivery and diagnostic files

### Destination repository

wwongw21/gephgui-pkg

### Status

All findings remain OPEN; documentation transfer only.

### Portable evidence

This JSON retains the complete repository-specific handoff. Historical /workspace paths are evidence references and prerequisites, not portable hyperlinks. Applicable repository-specific diagnostics are included alongside the report.

### Diagnostics included

None recorded.

### Not included

Original environments, model weights, user data and complete source snapshots are not included. Clone the pinned source and follow the recorded prerequisites. Bug-demonstration scripts intentionally assert pre-fix behavior; they are not a post-fix passing suite.


## Remaining review limits

1. Full Windows/macOS/Debian/Flatpak packages not built.

2. Gitlink dependencies geph5, gephgui-wry and shared-modules were not populated or reviewed; packaging-layer source only.

3. Native installation, upgrade, service registration, network restoration and privileged uninstall were not executed.

4. No shellcheck executable available.

5. Connected repository has zero CI runs as reported by parent reviewer.

