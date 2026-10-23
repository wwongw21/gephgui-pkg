#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/build-common.bash"

if grep -Eq '\$\{[^}]*,,\}' "$REPO_ROOT/build-common.bash"; then
    printf 'FAIL: build-common.bash uses a Bash 4 lowercase expansion\n' >&2
    exit 1
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    [[ "$expected" == "$actual" ]] || fail "$label: expected '$expected', got '$actual'"
}

assert_valid() {
    local version="$1"
    [[ "$version" =~ ^[0-9][A-Za-z0-9.+:~.-]*$ ]] || fail "invalid Debian/Flatpak version '$version'"
}

make_repo() {
    local path="$1"
    mkdir -p "$path"
    git -C "$path" init -q
    git -C "$path" config user.name 'Version Fixture'
    git -C "$path" config user.email 'version-fixture@example.invalid'
    git -C "$path" config core.autocrlf false
    printf 'one\n' > "$path/source.txt"
    git -C "$path" add source.txt
    git -C "$path" commit -qm 'fixture base'
}

assert_deb_safe_directory_argument() {
    local command_text capture_script capture_file git_command mock_bin mock_git glob_dir git_args_ok

    command_text="$(awk -v endquote="    '" '
        /^[[:space:]]*su -p builduser -c / { copying=1 }
        copying { print }
        copying && $0 == endquote { exit }
    ' "$REPO_ROOT/build-deb.bash")"
    [[ -n "$command_text" ]] || fail 'could not find the Debian build-user command'

    capture_script="$TMP_ROOT/capture-deb-su-command.bash"
    capture_file="$TMP_ROOT/deb-su-command.txt"
    cat > "$capture_script" <<'CAPTURE_SU'
#!/usr/bin/env bash
set -euo pipefail
su() {
    [[ "$#" -eq 4 ]] || exit 70
    [[ "$1" == -p && "$2" == builduser && "$3" == -c ]] || exit 71
    printf '%s\n' "$4" > "$CAPTURE_SU_COMMAND"
}
CAPTURE_SU
    printf '%s\n' "$command_text" >> "$capture_script"
    CAPTURE_SU_COMMAND="$capture_file" "$BASH" "$capture_script" || fail 'could not capture the assembled su command'

    git_command="$(sed -n '/git config --global --add safe.directory/p' "$capture_file")"
    [[ -n "$git_command" ]] || fail 'captured su command has no safe.directory setup'
    case "$git_command" in
        *'safe.directory "*"') ;;
        *) fail "outer su quoting removed the literal wildcard quotes: $git_command" ;;
    esac

    mock_bin="$TMP_ROOT/mock-bin"
    mock_git="$mock_bin/git"
    glob_dir="$TMP_ROOT/container-app"
    git_args_ok="$TMP_ROOT/git-args-ok"
    mkdir -p "$mock_bin" "$glob_dir"
    : > "$glob_dir/app-file-a"
    : > "$glob_dir/app-file-b"
    cat > "$mock_git" <<'MOCK_GIT'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" -ne 5 || "$1" != config || "$2" != --global || "$3" != --add || "$4" != safe.directory || "$5" != '*' ]]; then
    printf 'git received %s arguments: <%s>\n' "$#" "$*" >&2
    exit 1
fi
: > "$GIT_ARGS_OK"
MOCK_GIT
    chmod +x "$mock_git"
    (
        cd "$glob_dir"
        export PATH="$mock_bin:$PATH"
        export GIT_ARGS_OK="$git_args_ok"
        "$BASH" -c "$git_command"
    ) || fail 'safe.directory did not reach git as a name and literal wildcard value'
    [[ -f "$git_args_ok" ]] || fail 'mock git did not confirm the safe.directory arguments'
}

assert_deb_safe_directory_argument

repo="$TMP_ROOT/untagged"
make_repo "$repo"
unset VERSION || true
resolve_build_versions "$repo" || fail 'untagged version resolution failed'
short_sha="$(git -C "$repo" rev-parse --short HEAD)"
assert_eq 'untagged display keeps commit id' "$short_sha" "$VERSION"
assert_eq 'untagged Debian version' "0.0.0+git.$short_sha" "$PACKAGE_VERSION_DEB"
assert_eq 'untagged Flatpak artifact version' "$PACKAGE_VERSION_DEB" "$PACKAGE_VERSION_FLATPAK"
assert_eq 'untagged macOS version' '0.0.0' "$PACKAGE_VERSION_MACOS"
assert_eq 'untagged Windows version' '0.0.0.0' "$VERSION_NUM"
assert_valid "$PACKAGE_VERSION_DEB"
assert_valid "$PACKAGE_VERSION_FLATPAK"

unrecognized_tag_repo="$TMP_ROOT/unrecognized-tag"
make_repo "$unrecognized_tag_repo"
git -C "$unrecognized_tag_repo" tag build-2026.10
unset VERSION || true
resolve_build_versions "$unrecognized_tag_repo" || fail 'non-release tag should fall back to commit identity'
unrecognized_sha="$(git -C "$unrecognized_tag_repo" rev-parse --short HEAD)"
assert_eq 'non-release tag ignored' "$unrecognized_sha" "$VERSION"
assert_eq 'non-release tag Debian fallback' "0.0.0+git.$unrecognized_sha" "$PACKAGE_VERSION_DEB"

printf 'dirty\n' >> "$repo/source.txt"
unset VERSION || true
resolve_build_versions "$repo" || fail 'dirty untagged version resolution failed'
assert_eq 'dirty checkout marker' "$short_sha-dirty" "$VERSION"
[[ "$PACKAGE_VERSION_DEB" == "0.0.0+git.$short_sha.dirty" ]] || fail "dirty Debian version '$PACKAGE_VERSION_DEB'"
assert_valid "$PACKAGE_VERSION_DEB"
VERSION='v2.4.6'
resolve_build_versions "$repo" || fail 'dirty explicit release override failed'
assert_eq 'dirty explicit override marker' 'v2.4.6-dirty' "$VERSION"
assert_eq 'dirty explicit Debian mapping' "2.4.6+git.$short_sha.dirty" "$PACKAGE_VERSION_DEB"

for tag_kind in annotated lightweight; do
    tag_repo="$TMP_ROOT/$tag_kind"
    make_repo "$tag_repo"
    if [[ "$tag_kind" == annotated ]]; then
        git -C "$tag_repo" tag -a v2.4.6 -m 'release 2.4.6'
    else
        git -C "$tag_repo" tag v2.4.6
    fi
    unset VERSION || true
    resolve_build_versions "$tag_repo" || fail "$tag_kind tag resolution failed"
    assert_eq "$tag_kind tag display" 'v2.4.6' "$VERSION"
    assert_eq "$tag_kind Debian version" '2.4.6' "$PACKAGE_VERSION_DEB"
    assert_eq "$tag_kind Flatpak artifact version" '2.4.6' "$PACKAGE_VERSION_FLATPAK"
    assert_eq "$tag_kind macOS version" '2.4.6' "$PACKAGE_VERSION_MACOS"
    assert_eq "$tag_kind Windows version" '2.4.6.0' "$VERSION_NUM"

    for n in 1 2 3; do
        printf '%s\n' "$n" >> "$tag_repo/source.txt"
        git -C "$tag_repo" add source.txt
        git -C "$tag_repo" commit -qm "fixture commit $n"
    done
    unset VERSION || true
    resolve_build_versions "$tag_repo" || fail "$tag_kind post-tag resolution failed"
    short_sha="$(git -C "$tag_repo" rev-parse --short HEAD)"
    assert_eq "$tag_kind post-tag display" "v2.4.6-3-g$short_sha" "$VERSION"
    assert_eq "$tag_kind post-tag Debian version" "2.4.6+git.3.g$short_sha" "$PACKAGE_VERSION_DEB"
    assert_eq "$tag_kind post-tag Flatpak artifact version" "$PACKAGE_VERSION_DEB" "$PACKAGE_VERSION_FLATPAK"
    assert_eq "$tag_kind post-tag macOS version" '2.4.6' "$PACKAGE_VERSION_MACOS"
    assert_eq "$tag_kind post-tag Windows version" '2.4.6.3' "$VERSION_NUM"

    git_dir_copy="$TMP_ROOT/$tag_kind-git-dir"
    cp -R "$tag_repo/.git" "$git_dir_copy"
    VERSION_GIT_DIR="$git_dir_copy"
    unset VERSION || true
    resolve_build_versions "$tag_repo" || fail "$tag_kind copied git-dir resolution failed"
    assert_eq "$tag_kind copied git-dir display" "v2.4.6-3-g$short_sha" "$VERSION"
    unset VERSION_GIT_DIR

    printf 'dirty\n' >> "$tag_repo/source.txt"
    unset VERSION || true
    resolve_build_versions "$tag_repo" || fail "$tag_kind dirty post-tag resolution failed"
    assert_eq "$tag_kind dirty marker" "v2.4.6-3-g$short_sha-dirty" "$VERSION"
    [[ "$PACKAGE_VERSION_DEB" == "2.4.6+git.3.g$short_sha.dirty" ]] || fail "$tag_kind dirty Debian version '$PACKAGE_VERSION_DEB'"
done

timestamp_repo="$TMP_ROOT/timestamp-only"
make_repo "$timestamp_repo"
git -C "$timestamp_repo" tag v4.2.1
touch -t 203001010000.00 "$timestamp_repo/source.txt"
VERSION='v4.2.1'
resolve_build_versions "$timestamp_repo" || fail 'timestamp-only explicit version failed'
assert_eq 'timestamp-only explicit version stays clean' 'v4.2.1' "$VERSION"
assert_eq 'timestamp-only explicit package stays clean' '4.2.1' "$PACKAGE_VERSION_DEB"
unset VERSION || true
resolve_build_versions "$timestamp_repo" || fail 'timestamp-only automatic version failed'
assert_eq 'timestamp-only automatic version stays clean' 'v4.2.1' "$VERSION"
assert_eq 'timestamp-only automatic package stays clean' '4.2.1' "$PACKAGE_VERSION_DEB"

printf 'staged change\n' >> "$timestamp_repo/source.txt"
git -C "$timestamp_repo" add source.txt
VERSION='v4.2.1'
resolve_build_versions "$timestamp_repo" || fail 'staged explicit dirty version failed'
staged_explicit_version="$VERSION"
staged_explicit_package="$PACKAGE_VERSION_DEB"
assert_eq 'staged explicit change marks version dirty' 'v4.2.1-dirty' "$staged_explicit_version"
unset VERSION || true
resolve_build_versions "$timestamp_repo" || fail 'staged automatic dirty version failed'
assert_eq 'staged automatic version matches explicit identity' "$staged_explicit_version" "$VERSION"
assert_eq 'staged automatic package matches explicit identity' "$staged_explicit_package" "$PACKAGE_VERSION_DEB"

printf 'unstaged change\n' >> "$timestamp_repo/source.txt"
VERSION='v4.2.1'
resolve_build_versions "$timestamp_repo" || fail 'unstaged explicit dirty version failed'
unstaged_explicit_version="$VERSION"
unstaged_explicit_package="$PACKAGE_VERSION_DEB"
assert_eq 'unstaged explicit change marks version dirty' 'v4.2.1-dirty' "$unstaged_explicit_version"
unset VERSION || true
resolve_build_versions "$timestamp_repo" || fail 'unstaged automatic dirty version failed'
assert_eq 'unstaged automatic version matches explicit identity' "$unstaged_explicit_version" "$VERSION"
assert_eq 'unstaged automatic package matches explicit identity' "$unstaged_explicit_package" "$PACKAGE_VERSION_DEB"

partial_repo="$TMP_ROOT/partial-repo"
make_repo "$partial_repo"
printf 'packaging source\n' > "$partial_repo/packaging.txt"
git -C "$partial_repo" add packaging.txt
git -C "$partial_repo" commit -qm 'track omitted packaging source'
git -C "$partial_repo" tag -a v3.5.7 -m 'release 3.5.7'
partial_git_dir="$TMP_ROOT/partial-git-dir"
cp -R "$partial_repo/.git" "$partial_git_dir"
partial_worktree="$TMP_ROOT/partial-worktree"
mkdir -p "$partial_worktree"
cp "$partial_repo/source.txt" "$partial_worktree/source.txt"
VERSION_GIT_DIR="$partial_git_dir"
if version_git "$partial_worktree" diff-index --quiet HEAD -- 2>/dev/null; then
    fail 'partial Flatpak fixture did not expose the missing tracked file'
fi

unset VERSION_GIT_DIR
unset VERSION || true
resolve_build_versions "$partial_repo" || fail 'clean host tag resolution failed'
clean_host_version="$VERSION"
assert_eq 'clean host tag' 'v3.5.7' "$clean_host_version"
VERSION_GIT_DIR="$partial_git_dir"
VERSION="$clean_host_version"
resolve_build_versions "$partial_worktree" skip-dirty || fail 'clean partial Flatpak version failed'
assert_eq 'partial worktree preserves clean tag identity' "$clean_host_version" "$VERSION"

printf 'dirty\n' >> "$partial_repo/source.txt"
unset VERSION || true
unset VERSION_GIT_DIR
resolve_build_versions "$partial_repo" || fail 'dirty host tag resolution failed'
dirty_host_version="$VERSION"
assert_eq 'dirty host tag identity' 'v3.5.7-dirty' "$dirty_host_version"
VERSION_GIT_DIR="$partial_git_dir"
VERSION="$dirty_host_version"
resolve_build_versions "$partial_worktree" skip-dirty || fail 'dirty partial Flatpak version failed'
assert_eq 'partial worktree preserves host dirty identity' "$dirty_host_version" "$VERSION"
unset VERSION_GIT_DIR

override_repo="$TMP_ROOT/override"
make_repo "$override_repo"
VERSION='v2.4.6-rc.1+build.5'
resolve_build_versions "$override_repo" || fail 'prerelease override failed'
assert_eq 'prerelease display keeps prefix and metadata' 'v2.4.6-rc.1+build.5' "$VERSION"
assert_eq 'prerelease Debian ordering' '2.4.6~rc.1+build.5' "$PACKAGE_VERSION_DEB"
assert_eq 'prerelease Flatpak artifact version' '2.4.6~rc.1+build.5' "$PACKAGE_VERSION_FLATPAK"
assert_eq 'prerelease macOS version' '2.4.6' "$PACKAGE_VERSION_MACOS"
assert_eq 'prerelease Windows version' '2.4.6.0' "$VERSION_NUM"

VERSION='v2.4.6;touch_INJECTION'
resolve_build_versions "$repo" >/dev/null 2>&1 && fail 'malformed override was accepted'
VERSION="v2.4.6; touch $TMP_ROOT/injected"
for script in build-deb.bash build-flatpak.bash build-macos.bash build-windows.bash; do
    if output="$(VERSION="$VERSION" "$BASH" "$REPO_ROOT/$script" 2>&1)"; then
        fail "$script accepted a shell-injection VERSION"
    fi
    [[ "$output" == *'version error: unsupported VERSION'* ]] || fail "$script did not report an actionable VERSION error: $output"
done
[[ ! -e "$TMP_ROOT/injected" ]] || fail 'malformed VERSION executed a shell command'

VERSION='abcdef0'
resolve_build_versions "$override_repo" || fail 'letter-leading SHA override failed'
assert_eq 'letter-leading SHA Debian mapping' '0.0.0+git.abcdef0' "$PACKAGE_VERSION_DEB"
assert_eq 'letter-leading SHA Windows mapping' '0.0.0.0' "$VERSION_NUM"
VERSION='1234567'
resolve_build_versions "$override_repo" || fail 'digit-leading SHA override failed'
assert_eq 'digit-leading SHA Debian mapping' '0.0.0+git.1234567' "$PACKAGE_VERSION_DEB"
assert_eq 'digit-leading SHA Windows mapping' '0.0.0.0' "$VERSION_NUM"
VERSION='ABCDEF0'
resolve_build_versions "$override_repo" || fail 'uppercase letter-leading SHA override failed'
assert_eq 'uppercase SHA display is preserved' 'ABCDEF0' "$VERSION"
assert_eq 'uppercase SHA package mapping is normalized' '0.0.0+git.abcdef0' "$PACKAGE_VERSION_DEB"
VERSION='v1.2.3-2-gABCDEF0'
resolve_build_versions "$override_repo" || fail 'uppercase describe hash failed'
assert_eq 'uppercase describe package mapping is normalized' '1.2.3+git.2.gabcdef0' "$PACKAGE_VERSION_DEB"
assert_eq 'uppercase describe Windows mapping' '1.2.3.2' "$VERSION_NUM"

VERSION='v65536.0.0'
resolve_build_versions "$override_repo" || fail 'large Debian version should remain legal'
assert_eq 'large Debian release value' '65536.0.0' "$PACKAGE_VERSION_DEB"
if validate_windows_version "$VERSION_NUM" >/dev/null 2>&1; then
    fail 'Windows accepted a version component above 65535'
fi

# Execute the nested command from the actual Flatpak manifest. A rejected
# version must not return success or replace an earlier .version file.
flatpak_manifest_command="$(awk '/VERSION_GIT_DIR=.pkg-git bash / { sub(/^[[:space:]]*/, ""); print; exit }' \
    "$REPO_ROOT/flatpak/io.geph.GephGui.yml")"
[[ -n "$flatpak_manifest_command" ]] || fail 'could not find the Flatpak manifest version command'
run_flatpak_manifest_version() {
    local root="$1" version="$2"
    (
        cd "$root"
        VERSION="$version" bash -c "$flatpak_manifest_command"
    )
}

flatpak_version_common="$TMP_ROOT/flatpak-version-common.bash"
cp "$REPO_ROOT/build-common.bash" "$flatpak_version_common"
flatpak_existing="$TMP_ROOT/flatpak-version-existing"
mkdir -p "$flatpak_existing/.pkg-git"
cp "$flatpak_version_common" "$flatpak_existing/build-common.bash"
printf '%s' 'last-good' > "$flatpak_existing/.version"
if run_flatpak_manifest_version "$flatpak_existing" not-a-version > "$TMP_ROOT/flatpak-invalid-existing.log" 2>&1; then
    fail 'Flatpak manifest accepted an invalid version'
fi
assert_eq 'invalid Flatpak version keeps prior .version' 'last-good' "$(cat "$flatpak_existing/.version")"

flatpak_missing="$TMP_ROOT/flatpak-version-missing"
mkdir -p "$flatpak_missing/.pkg-git"
cp "$flatpak_version_common" "$flatpak_missing/build-common.bash"
if run_flatpak_manifest_version "$flatpak_missing" not-a-version > "$TMP_ROOT/flatpak-invalid-missing.log" 2>&1; then
    fail 'Flatpak manifest accepted an invalid version without a prior .version'
fi
[[ ! -e "$flatpak_missing/.version" ]] || fail 'invalid Flatpak version created .version'
run_flatpak_manifest_version "$flatpak_missing" v2.3.4 || fail 'Flatpak manifest rejected a valid release version'
assert_eq 'valid Flatpak manifest version' 'v2.3.4' "$(cat "$flatpak_missing/.version")"

printf 'PASS: version normalization fixtures\n'
