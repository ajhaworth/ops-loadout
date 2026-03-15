#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local haystack="$1"
    local needle="$2"

    if [[ "$haystack" != *"$needle"* ]]; then
        fail "expected output to contain: $needle"
    fi
}

run_capture() {
    RUN_OUTPUT=""
    set +e
    RUN_OUTPUT="$("$@" 2>&1)"
    local status=$?
    set -e

    return $status
}

test_mismatched_profile_rejected() {
    local current_os mismatched_profile output
    current_os="$(uname -s)"

    case "$current_os" in
        Darwin) mismatched_profile="windows" ;;
        Linux) mismatched_profile="personal" ;;
        *) fail "unsupported host for smoke test: $current_os" ;;
    esac

    if run_capture "$REPO_ROOT/setup.sh" --dry-run --profile "$mismatched_profile"; then
        fail "mismatched profile should have failed"
    fi

    assert_contains "$RUN_OUTPUT" "targets"
    assert_contains "$RUN_OUTPUT" "current OS"
}

test_supported_dry_runs() {
    local current_os output
    current_os="$(uname -s)"

    case "$current_os" in
        Darwin)
            run_capture "$REPO_ROOT/setup.sh" --dry-run --profile personal || fail "personal dry-run failed"
            assert_contains "$RUN_OUTPUT" "Workstation setup finished successfully"

            run_capture "$REPO_ROOT/setup.sh" --dry-run --profile work || fail "work dry-run failed"
            assert_contains "$RUN_OUTPUT" "Workstation setup finished successfully"
            ;;
        Linux)
            run_capture "$REPO_ROOT/setup.sh" --dry-run --profile linux || fail "linux dry-run failed"
            assert_contains "$RUN_OUTPUT" "Workstation setup finished successfully"
            ;;
    esac
}

test_symlink_safety() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    local output
    output="$(
        TMPDIR_FOR_TEST="$tmpdir" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -euo pipefail

tmpdir="$TMPDIR_FOR_TEST"
test_repo_root="$tmpdir/repo"
home_dir="$tmpdir/home"

mkdir -p "$test_repo_root/config/dotfiles" "$home_dir"
printf 'managed\n' > "$test_repo_root/config/dotfiles/test"
printf 'other\n' > "$test_repo_root/config/dotfiles/other"
printf 'foreign\n' > "$tmpdir/foreign"

manifest="$tmpdir/manifest.txt"
cat > "$manifest" <<MANIFEST
config/dotfiles/test|~/.relative||
MANIFEST

export HOME="$home_dir"
export DRY_RUN="false"

source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/symlink.sh"

get_repo_root() {
    echo "$test_repo_root"
}

managed_source="$test_repo_root/config/dotfiles/test"
managed_other="$test_repo_root/config/dotfiles/other"
dest_relative="$HOME/.relative"
dest_managed="$HOME/.managed"
dest_foreign="$HOME/.foreign"

rel_target="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], os.path.dirname(sys.argv[2])))' "$managed_source" "$dest_relative")"
ln -s "$rel_target" "$dest_relative"

check_manifest "$manifest"

ln -s "$managed_other" "$dest_managed"
create_symlink "$managed_source" "$dest_managed"

ln -s "$tmpdir/foreign" "$dest_foreign"
create_symlink "$managed_source" "$dest_foreign"

[[ "$(resolve_symlink_target "$dest_managed")" == "$managed_source" ]]
[[ "$(resolve_symlink_target "$dest_foreign")" == "$managed_source" ]]
[[ ! -e "$BACKUP_DIR/.managed" ]]
[[ -L "$BACKUP_DIR/.foreign" ]]

echo "symlink-tests-ok"
EOF
    )"

    assert_contains "$output" "symlink-tests-ok"
}

test_linux_package_failures_continue() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    local output
    output="$(
        TMPDIR_FOR_TEST="$tmpdir" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -euo pipefail

tmpdir="$TMPDIR_FOR_TEST"
repo_root="$tmpdir/repo"
bin_dir="$tmpdir/bin"

mkdir -p "$repo_root/config/packages/linux/apt" "$bin_dir"
cat > "$repo_root/config/packages/linux/apt/core.txt" <<'PKGS'
goodpkg
badpkg
PKGS

cat > "$bin_dir/sudo" <<'SUDO'
#!/usr/bin/env bash
exec "$@"
SUDO

cat > "$bin_dir/apt-get" <<'APT'
#!/usr/bin/env bash
if [[ "$1" == "update" ]]; then
    exit 0
fi
if [[ "$1" == "install" ]]; then
    pkg="${@: -1}"
    if [[ "$pkg" == "badpkg" ]]; then
        exit 1
    fi
    exit 0
fi
exit 1
APT

cat > "$bin_dir/dpkg" <<'DPKG'
#!/usr/bin/env bash
exit 1
DPKG

chmod +x "$bin_dir/sudo" "$bin_dir/apt-get" "$bin_dir/dpkg"

export PATH="$bin_dir:$PATH"
export SCRIPT_DIR="$repo_root"
export PROFILE_PACKAGES="true"
export PACKAGES_CORE="true"
export DRY_RUN="false"

source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/detect.sh"
source "$REPO_ROOT/lib/packages.sh"
source "$REPO_ROOT/platforms/linux/packages.sh"

get_linux_distro() {
    echo "ubuntu"
}

setup_packages
EOF
    )"

    assert_contains "$output" "1 installed"
    assert_contains "$output" "1 failed"
}

test_unsupported_linux_rejected() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    cat > "$tmpdir/unsupported-linux.sh" <<'EOF'
set -euo pipefail

tmpdir="$TMPDIR_FOR_TEST"
repo_root="$tmpdir/repo"
mkdir -p "$repo_root/config/packages/linux/apt"

export SCRIPT_DIR="$repo_root"
export PROFILE_PACKAGES="true"

source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/detect.sh"
source "$REPO_ROOT/lib/packages.sh"
source "$REPO_ROOT/platforms/linux/packages.sh"

get_linux_distro() {
    echo "fedora"
}

setup_packages
EOF
    chmod +x "$tmpdir/unsupported-linux.sh"

    if run_capture env TMPDIR_FOR_TEST="$tmpdir" REPO_ROOT="$REPO_ROOT" bash "$tmpdir/unsupported-linux.sh"; then
        fail "unsupported Linux distro should have failed"
    fi

    assert_contains "$RUN_OUTPUT" "limited to Debian/Ubuntu"
}

test_mismatched_profile_rejected
test_supported_dry_runs
test_symlink_safety
test_linux_package_failures_continue
test_unsupported_linux_rejected

echo "bash smoke tests passed"
