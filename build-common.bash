# build-common.bash — sourced by the build-*.bash scripts after they cd to the
# repo root. Not a standalone script.
#
# This checkout may be shared between several build machines (Syncthing, NFS,
# ...) with the Windows, macOS and Linux builds running CONCURRENTLY on
# different machines. To make that safe, a build must not mutate anything
# inside the shared checkout: two machines writing gephgui/node_modules,
# gephgui/dist or a cargo target/ tree at the same time would corrupt each
# other's builds (and thrash the sync). So every path a build writes lives
# under a machine-LOCAL root instead: sources are staged (copied) into it, all
# intermediates land in it, and only the finished artifact is published back
# into ./output/ — under a per-OS name, so no two machines ever write the same
# shared file.
#
# The exceptions, deliberate and safe:
#   - output/: final artifacts only, per-OS filenames, written via publish()
#     (temp file + rename) so other machines never sync a half-written file
#     under its final name.
#   - blobs/linux-x64: written only by build-flatpak.bash, read only by the
#     flatpak manifest on the same machine.
#   - .git: the submodule-bootstrap loops init MISSING submodules on first run.
#     Do that initial clone/init on one machine and let it sync before running
#     builds concurrently.

# Machine-local root for everything a build writes. $HOME/.cache is assumed to
# be local to the machine; override with GEPHGUI_PKG_BUILD_ROOT if you sync
# your home directory too.
LOCAL_BUILD_ROOT="${GEPHGUI_PKG_BUILD_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/gephgui-pkg}"
LOCAL_SRC="$LOCAL_BUILD_ROOT/src"

# One shared cargo target dir under the local root: keeps geph5/target &co out
# of the synced checkout, and makes rebuilds incremental (cargo install would
# otherwise rebuild from scratch in a temp dir every run). On git-bash, cargo
# is a native Windows binary that would misread a /c/Users/... POSIX path in an
# environment variable (argv gets auto-converted, env does not), so hand it a
# C:/Users/... mixed path via cygpath.
if command -v cygpath >/dev/null 2>&1; then
    CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$(cygpath -m "$LOCAL_BUILD_ROOT")/target}"
else
    CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$LOCAL_BUILD_ROOT/target}"
fi
export CARGO_TARGET_DIR

# copy_tree SRC DST [EXCLUDE...] — mirror SRC into DST, excludes being
# root-anchored paths relative to SRC. mtimes are preserved, so cargo/npm see
# unchanged files as unchanged and rebuilds stay incremental. Excluded paths
# already present in DST are left alone (that's how node_modules survives
# restaging). Uses rsync where available; git-bash has no rsync, so fall back
# to rm + (GNU) tar, carrying DST's node_modules across the wipe to keep npm
# installs incremental there too.
copy_tree() {
    local src="$1" dst="$2"
    shift 2
    mkdir -p "$dst"
    if command -v rsync >/dev/null 2>&1; then
        local args=(-a --delete)
        local ex
        for ex in "$@"; do args+=(--exclude "/$ex"); done
        rsync "${args[@]}" "$src/" "$dst/"
    else
        local keep=""
        if [ -d "$dst/gephgui/node_modules" ]; then
            keep="$dst.keep-node_modules"
            rm -rf "$keep"
            mv "$dst/gephgui/node_modules" "$keep"
        fi
        rm -rf "$dst"
        mkdir -p "$dst"
        local args=(--anchored)
        local ex
        for ex in "$@"; do args+=(--exclude "./$ex"); done
        (cd "$src" && tar -cf - "${args[@]}" .) | (cd "$dst" && tar -xf -)
        if [ -n "$keep" ] && [ -d "$dst/gephgui" ]; then
            rm -rf "$dst/gephgui/node_modules"
            mv "$keep" "$dst/gephgui/node_modules"
        fi
    fi
}

# Stage gephgui-wry and geph5 side by side under $LOCAL_SRC, mirroring the repo
# layout — gephgui-wry's Cargo.toml [patch] entries point at ../geph5/…, so the
# two must stay siblings (the flatpak manifest stages them the same way).
# Build-artifact dirs are excluded: the frontend is npm-built in the STAGED
# copy (build_frontend), never in the shared checkout.
stage_gephgui_wry() {
    copy_tree gephgui-wry "$LOCAL_SRC/gephgui-wry" .git target gephgui/node_modules gephgui/dist
}
stage_geph5() {
    copy_tree geph5 "$LOCAL_SRC/geph5" .git target
}
stage_sources() {
    echo ">> staging sources into $LOCAL_SRC"
    stage_gephgui_wry
    stage_geph5
}

# Build the frontend in the staged copy; rust-embed then embeds
# $LOCAL_SRC/gephgui-wry/gephgui/dist when the staged crate is compiled.
build_frontend() {
    (cd "$LOCAL_SRC/gephgui-wry/gephgui" && npm i -f && npm run build)
}

# publish SRC DST — drop a finished artifact into the shared output/ via a
# temp file + same-directory rename, so machines syncing output/ never see a
# half-written file under its final name.
publish() {
    local src="$1" dst="$2"
    local tmp
    tmp="$(dirname "$dst")/.$(basename "$dst").partial"
    cp "$src" "$tmp"
    mv -f "$tmp" "$dst"
}

# Resolve the source/display identifier once, then map it to the native version
# fields used by each existing package. VERSION is an explicit source/display
# identity (not a native package version): it may be a SemVer release (optionally
# prefixed with v) or a git-describe value. When omitted, include annotated and
# lightweight tags and mark tracked local changes. For source commits after a
# release tag, Debian/Flatpak get a sortable +git revision, Windows gets the
# describe distance in its fourth numeric component, and macOS keeps a numeric
# three-part release identity. VERSION itself retains the tag and commit hash.
#
# Outputs:
#   VERSION                  source/display identity, including git revision
#   PACKAGE_VERSION_DEB      Debian control Version and Flatpak artifact label
#   PACKAGE_VERSION_FLATPAK  Flatpak artifact label (Flatpak has no manifest version field)
#   PACKAGE_VERSION_MACOS    numeric three-part bundle/package version
#   VERSION_NUM              numeric four-part Windows file version
version_error() {
    printf 'version error: %s\n' "$*" >&2
    return 1
}

version_git() {
    local repo_root="$1"
    shift
    if [[ -n "${VERSION_GIT_DIR:-}" ]]; then
        git --git-dir="$VERSION_GIT_DIR" --work-tree="$repo_root" "$@"
    else
        git -C "$repo_root" "$@"
    fi
}

lowercase_hex() {
    printf '%s' "$1" | LC_ALL=C tr 'ABCDEF' 'abcdef'
}

parse_build_version() {
    local raw="$1" candidate="$1" base="$1"
    local dirty=0 distance=0 hash="" untagged=0
    local core pre build major minor patch part value repo_root
    repo_root="${2:-$PWD}"

    if [[ "$candidate" == *-dirty ]]; then
        dirty=1
        candidate="${candidate%-dirty}"
    fi

    if [[ "$candidate" =~ ^(.+)-([0-9]+)-g([[:xdigit:]]{4,40})$ ]]; then
        base="${BASH_REMATCH[1]}"
        distance="${BASH_REMATCH[2]}"
        hash="$(lowercase_hex "${BASH_REMATCH[3]}")"
        if [[ "$distance" != 0 && "$distance" == 0* ]]; then
            version_error "VERSION '$raw' has a git revision count with a leading zero"
            return 1
        fi
    elif [[ "$candidate" =~ ^([[:xdigit:]]{7,40})$ ]]; then
        base="0.0.0"
        hash="$(lowercase_hex "${BASH_REMATCH[1]}")"
        untagged=1
    else
        base="$candidate"
    fi

    if [[ ! "$base" =~ ^v?([0-9]+\.[0-9]+\.[0-9]+)(-([0-9A-Za-z.-]+))?(\+([0-9A-Za-z.-]+))?$ ]]; then
        version_error "unsupported VERSION '$raw'; use vMAJOR.MINOR.PATCH (optionally with SemVer prerelease/build metadata) or a git-describe value"
        return 1
    fi
    core="${BASH_REMATCH[1]}"
    pre="${BASH_REMATCH[3]:-}"
    build="${BASH_REMATCH[5]:-}"

    IFS=. read -r major minor patch <<< "$core"
    for part in "$major" "$minor" "$patch"; do
        if [[ "$part" != 0 && "$part" == 0* ]]; then
            version_error "VERSION '$raw' has a SemVer numeric component with a leading zero"
            return 1
        fi
    done
    for value in "$pre" "$build"; do
        if [[ -n "$value" && ( "$value" == .* || "$value" == *. || "$value" == *..* ) ]]; then
            version_error "VERSION '$raw' has an empty prerelease/build identifier"
            return 1
        fi
    done
    if [[ -n "$pre" ]]; then
        local -a identifiers=()
        local identifier
        IFS=. read -r -a identifiers <<< "$pre"
        for identifier in "${identifiers[@]}"; do
            if [[ "$identifier" =~ ^[0-9]+$ && ${#identifier} -gt 1 && "$identifier" == 0* ]]; then
                version_error "VERSION '$raw' has a prerelease numeric identifier with a leading zero"
                return 1
            fi
        done
    fi

    if [[ "$dirty" == 1 && -z "$hash" ]]; then
        hash="$(version_git "$repo_root" rev-parse --short HEAD 2>/dev/null)" || {
            version_error "VERSION '$raw' is marked dirty, but the current commit cannot be identified"
            return 1
        }
        [[ "$hash" =~ ^[[:xdigit:]]{4,40}$ ]] || {
            version_error "VERSION '$raw' is marked dirty, but the current commit hash is unavailable"
            return 1
        }
        hash="$(lowercase_hex "$hash")"
    fi

    VERSION_CORE="$core"
    VERSION_PRE="$pre"
    VERSION_BUILD="$build"
    VERSION_DISTANCE="$distance"
    VERSION_HASH="$hash"
    VERSION_DIRTY="$dirty"
    VERSION_UNTAGGED="$untagged"
}

# The optional `skip-dirty` mode is for partial work trees such as the Flatpak
# module: its host VERSION already carries dirty state, while omitted tracked
# files would make a local diff check report a false change. If VERSION is
# absent in this mode, derive a clean tag/hash identity from Git metadata only.
resolve_build_versions() {
    local repo_root="${1:-$PWD}"
    local dirty_check="${2:-check-dirty}"
    local source_version="${VERSION:-}"
    local deb_version suffix

    if [[ -z "$source_version" ]]; then
        local -a describe_args=(describe --tags --match 'v[0-9]*' --always)
        [[ "$dirty_check" == skip-dirty ]] || describe_args+=(--dirty)
        source_version="$(version_git "$repo_root" "${describe_args[@]}" 2>/dev/null)" || {
            version_error "cannot derive VERSION from Git in '$repo_root'"
            return 1
        }
    elif [[ "$dirty_check" != skip-dirty ]] && version_git "$repo_root" rev-parse --verify HEAD >/dev/null 2>&1; then
        # An explicit VERSION is a source/display identity, not permission to
        # label modified tracked sources as a clean release.
        if ! version_git "$repo_root" diff-index --quiet HEAD --; then
            [[ "$source_version" == *-dirty ]] || source_version+="-dirty"
        fi
    fi
    parse_build_version "$source_version" "$repo_root" || return 1

    # Debian orders '~' before the corresponding release, so SemVer prereleases
    # remain prereleases. Git revisions and dirty sources sort after their base
    # tag while staying before the next normal release.
    deb_version="$VERSION_CORE"
    [[ -z "$VERSION_PRE" ]] || deb_version+="~$VERSION_PRE"
    [[ -z "$VERSION_BUILD" ]] || deb_version+="+$VERSION_BUILD"
    suffix=""
    if [[ "$VERSION_DISTANCE" != 0 ]]; then
        suffix="git.$VERSION_DISTANCE.g$VERSION_HASH"
    elif [[ "$VERSION_UNTAGGED" == 1 || "$VERSION_DIRTY" == 1 ]]; then
        suffix="git.$VERSION_HASH"
    fi
    if [[ -n "$suffix" ]]; then
        if [[ "$deb_version" == *+* ]]; then deb_version+="."; else deb_version+="+"; fi
        deb_version+="$suffix"
    fi
    [[ "$VERSION_DIRTY" == 1 ]] && deb_version+=".dirty"

    VERSION="$source_version"
    PACKAGE_VERSION_DEB="$deb_version"
    PACKAGE_VERSION_FLATPAK="$deb_version"
    PACKAGE_VERSION_MACOS="$VERSION_CORE"
    VERSION_NUM="$VERSION_CORE.$VERSION_DISTANCE"
    [[ "$VERSION_UNTAGGED" == 1 ]] && VERSION_NUM='0.0.0.0'
    VERSION_ARTIFACT="$PACKAGE_VERSION_FLATPAK"
    export VERSION PACKAGE_VERSION_DEB PACKAGE_VERSION_FLATPAK
    export PACKAGE_VERSION_MACOS VERSION_NUM VERSION_ARTIFACT

    validate_debian_version "$PACKAGE_VERSION_DEB" || return 1
    validate_flatpak_artifact_version "$PACKAGE_VERSION_FLATPAK" || return 1
    validate_macos_version "$PACKAGE_VERSION_MACOS" || return 1
}

validate_debian_version() {
    local value="$1"
    [[ "$value" =~ ^[0-9][A-Za-z0-9.+:~.-]*$ ]] || {
        version_error "invalid Debian package version '$value'"
        return 1
    }
}

validate_flatpak_artifact_version() {
    local value="$1"
    [[ "$value" =~ ^[0-9][A-Za-z0-9.+:~.-]*$ ]] || {
        version_error "invalid Flatpak artifact version '$value'"
        return 1
    }
}

validate_macos_version() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        version_error "invalid macOS bundle/package version '$value'; expected three numeric components"
        return 1
    }
}

validate_windows_version() {
    local value="$1" component normalized
    local -a components=()
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        version_error "invalid Windows file version '$value'; expected four numeric components"
        return 1
    }
    IFS=. read -r -a components <<< "$value"
    for component in "${components[@]}"; do
        normalized="$component"
        while [[ ${#normalized} -gt 1 && "$normalized" == 0* ]]; do
            normalized="${normalized#0}"
        done
        if [[ ${#normalized} -gt 5 ]] || (( 10#$normalized > 65535 )); then
            version_error "Windows file version component '$component' exceeds the 65535 limit"
            return 1
        fi
    done
}
