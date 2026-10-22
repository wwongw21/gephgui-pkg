#!/usr/bin/env bash
set -u

SOURCE_REV=f3a248b2aefe31158ebd1d1ecae1f689e604fdfe
BASH_BIN=${BASH_BIN:-bash}
LOG_FILE=${1:-}

if [ "$#" -gt 1 ]; then
  printf 'Usage: %s [log-file]\n' "$0" >&2
  exit 2
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel) || exit 2
cd "$REPO_ROOT" || exit 2

if [ -n "$LOG_FILE" ]; then
  case "$LOG_FILE" in
    /*) ;;
    *) LOG_FILE="$REPO_ROOT/$LOG_FILE" ;;
  esac
  mkdir -p "$(dirname -- "$LOG_FILE")" || exit 2
  exec >"$LOG_FILE" 2>&1
fi

if ! command -v "$BASH_BIN" >/dev/null 2>&1; then
  printf 'ERROR: Bash executable not found: %s\n' "$BASH_BIN"
  exit 2
fi

printf 'Bash syntax check (syntax only; no scripts are executed)\n'
printf 'Source revision: %s\n' "$SOURCE_REV"
printf 'Bash executable: %s\n' "$BASH_BIN"
"$BASH_BIN" --version | sed -n '1p'
printf '\n'

checked=0
failures=0
while IFS=' ' read -r expected_blob path; do
  [ -n "$path" ] || continue
  checked=$((checked + 1))
  actual_blob=$(git hash-object -- "$path") || actual_blob='HASH-ERROR'
  if [ "$actual_blob" != "$expected_blob" ]; then
    printf 'FAIL %s | pinned blob %s | worktree blob %s | syntax check skipped\n' \
      "$path" "$expected_blob" "$actual_blob"
    failures=$((failures + 1))
    continue
  fi
  if "$BASH_BIN" -n "$path"; then
    printf 'PASS %s | blob %s | bash -n exit 0\n' "$path" "$expected_blob"
  else
    result=$?
    printf 'FAIL %s | blob %s | bash -n exit %s\n' "$path" "$expected_blob" "$result"
    failures=$((failures + 1))
  fi
done <<'PINNED_SCRIPTS'
0e489d0b02a7fadbe49f71822ca74280f874f0ab build-common.bash
92bf618be3bb6b2526559d1c689f1d172bac620c build-windows.bash
1c99b55465fa1dae85dbcaf20610ec300332870c build-macos.bash
de2e9508b41bf5c978615fd89407854410c0e5e7 build-deb.bash
2150a2022038733cbe68fadff3f55f7b175897fc debian/build-deb-inner.sh
b1b27cbf0aaeecb1c29154f8e655c8b81b570d37 build-flatpak.bash
d375cd28d3c070d6c53747b80aaec16418a9e5af flatpak/install-host-manager.sh
db874ad1937eda83cd0940f2bc12fad4ae38e988 flatpak/geph-flatpak-watchdog.sh
30646249b72365390d43c5fae8d0f1a22d79ef14 macos/create-dmg
a8d66f03410fc7760acbd472dea2a83d9fc38017 macos/pkg-scripts/preinstall
a8f72a47ddab100b65ba11d3a4f8560fcd132795 macos/pkg-scripts/postinstall
f8a88860cd740360c9690bf5631c687e2cf2d93f macos/uninstall.sh
PINNED_SCRIPTS

printf '\nChecked: %s\nFailures: %s\n' "$checked" "$failures"
if [ "$failures" -eq 0 ]; then
  printf 'Result: PASS\n'
  exit 0
fi
printf 'Result: FAIL\n'
exit 1
