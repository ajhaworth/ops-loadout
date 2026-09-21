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

test_macos_installer_scripts() {
    local houdini="$REPO_ROOT/platforms/macos/installers/houdini.sh"
    local labs="$REPO_ROOT/platforms/macos/installers/sidefxlabs.sh"
    local compositor="$REPO_ROOT/platforms/macos/installers/compositor.sh"
    local moonlight="$REPO_ROOT/platforms/macos/installers/moonlight-nightly.sh"
    local blender="$REPO_ROOT/platforms/macos/installers/blender.sh"

    [[ -x "$houdini" ]] || fail "houdini.sh is not executable"
    [[ -x "$labs" ]] || fail "sidefxlabs.sh is not executable"
    [[ -x "$compositor" ]] || fail "compositor.sh is not executable"
    [[ -x "$moonlight" ]] || fail "moonlight-nightly.sh is not executable"
    [[ -x "$blender" ]] || fail "blender.sh is not executable"

    bash -n "$houdini" || fail "houdini.sh has a syntax error"
    bash -n "$labs" || fail "sidefxlabs.sh has a syntax error"
    bash -n "$compositor" || fail "compositor.sh has a syntax error"
    bash -n "$moonlight" || fail "moonlight-nightly.sh has a syntax error"
    bash -n "$blender" || fail "blender.sh has a syntax error"

    # A Blender we did not install (cask, manual download) must read as absent:
    # status requires our own portable symlink. Skipped when this machine has it.
    if [[ "$(readlink /Applications/Blender.app/Contents/Resources/portable 2>/dev/null)" \
          != "$REPO_ROOT/config/dcc/blender/portable" ]]; then
        if run_capture "$blender" status; then
            fail "blender.sh status should fail without our portable symlink"
        fi
    fi

    [[ -f "$REPO_ROOT/config/dcc/blender/portable/scripts/presets/keyconfig/dcc.py" ]] \
        || fail "config/dcc/blender keymap preset is missing"

    # Without Houdini, SideFX Labs cannot be installed or reported as present.
    if ! run_capture "$houdini" status; then
        if run_capture "$labs" status; then
            fail "sidefxlabs.sh status should fail when Houdini is absent"
        fi
    fi

    # Missing credentials must point at the launcher's Settings dialog, not
    # fail obscurely.
    if run_capture env SIDEFX_CREDENTIALS="$REPO_ROOT/config/nonexistent-sidefx.local" "$houdini" install; then
        fail "houdini.sh install should fail without credentials"
    fi

    assert_contains "$RUN_OUTPUT" "Settings"
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

test_tasks_status_json() {
    local section
    for section in prereq dotfiles defaults; do
        local rows
        rows="$("$REPO_ROOT/lib/tasks.sh" status "$section" 2>/dev/null)" \
            || fail "lib/tasks.sh status $section failed"

        printf '%s' "$rows" | python3 -c '
import json, sys

section = sys.argv[1]
data = json.loads(sys.stdin.read())

assert isinstance(data, list) and len(data) > 0, "expected a non-empty list"

valid_states = {"applied", "pending", "failed", "needs_admin", "unknown"}
seen_ids = set()
for row in data:
    assert set(row.keys()) == {"id", "section", "group", "name", "state", "detail"}, sorted(row.keys())
    assert row["section"] == section, row["section"]
    assert row["state"] in valid_states, row["state"]
    assert row["id"] not in seen_ids, "duplicate id: " + row["id"]
    seen_ids.add(row["id"])
' "$section" || fail "lib/tasks.sh status $section produced invalid rows"
    done

    local work_rows
    work_rows="$("$REPO_ROOT/lib/tasks.sh" status defaults --profile work 2>/dev/null)" \
        || fail "lib/tasks.sh status defaults --profile work failed"

    printf '%s' "$work_rows" | python3 -c '
import json, sys
data = json.loads(sys.stdin.read())
assert isinstance(data, list) and len(data) > 0, "expected a non-empty list"
' || fail "lib/tasks.sh status defaults --profile work produced invalid JSON"
}

test_json_str_escaping() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    # Literal backslash, double quote, newline and tab in one string.
    printf 'back\\slash "quote"\nnewline\ttab' > "$tmpdir/input.txt"

    local output
    output="$(
        TMPDIR_FOR_TEST="$tmpdir" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -euo pipefail

tmpdir="$TMPDIR_FOR_TEST"
source "$REPO_ROOT/lib/tasks.sh"

input="$(cat "$tmpdir/input.txt")"
json_str "$input" > "$tmpdir/encoded.txt"

python3 -c '
import json, sys

with open(sys.argv[1]) as f:
    original = f.read()
with open(sys.argv[2]) as f:
    encoded = f.read()

decoded = json.loads("\"" + encoded + "\"")
assert decoded == original, (decoded, original)
' "$tmpdir/input.txt" "$tmpdir/encoded.txt"

echo "json-str-ok"
EOF
    )"

    assert_contains "$output" "json-str-ok"
}

test_defaults_compare() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        echo "SKIP: test_defaults_compare (macOS only, current OS is $(uname -s))"
        return 0
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    # cfprefsd can leave an empty plist on disk after `defaults delete`, so
    # remove the file directly too - otherwise a junk domain lingers forever.
    trap 'rm -rf "$tmpdir"; defaults delete com.ops-desktop.smoke 2>/dev/null || true; rm -f "$HOME/Library/Preferences/com.ops-desktop.smoke.plist"' RETURN

    defaults delete com.ops-desktop.smoke 2>/dev/null || true
    rm -f "$HOME/Library/Preferences/com.ops-desktop.smoke.plist"

    local output
    output="$(
        TMPDIR_FOR_TEST="$tmpdir" REPO_ROOT="$REPO_ROOT" bash <<'EOF'
set -euo pipefail

tmpdir="$TMPDIR_FOR_TEST"
source "$REPO_ROOT/lib/tasks.sh"

row_field() {
    local last=$((${#TASK_ROWS[@]} - 1))
    printf '%s' "${TASK_ROWS[$last]}" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())[sys.argv[1]])' "$1"
}

TASK_GROUP_ID="smoke"
TASK_GROUP="Smoke"
TASK_MODE="status"
TASK_ONLY=""

TASK_ROWS=()
defaults_set com.ops-desktop.smoke Foo bool true "Foo"
[[ "$(row_field state)" == "pending" ]] || { echo "expected pending, got $(row_field state)"; exit 1; }
[[ "$(row_field detail)" == "not set" ]] || { echo "expected 'not set', got $(row_field detail)"; exit 1; }

defaults write com.ops-desktop.smoke Foo -bool true

TASK_ROWS=()
defaults_set com.ops-desktop.smoke Foo bool true "Foo"
[[ "$(row_field state)" == "applied" ]] || { echo "expected applied, got $(row_field state)"; exit 1; }

TASK_ROWS=()
defaults_set com.ops-desktop.smoke Foo bool false "Foo"
[[ "$(row_field state)" == "pending" ]] || { echo "expected pending, got $(row_field state)"; exit 1; }
[[ "$(row_field detail)" == "currently 1, want 0" ]] || { echo "expected 'currently 1, want 0', got $(row_field detail)"; exit 1; }

defaults write com.ops-desktop.smoke Num -int 128

TASK_ROWS=()
defaults_set com.ops-desktop.smoke Num int 128 "Num"
[[ "$(row_field state)" == "applied" ]] || { echo "expected applied, got $(row_field state)"; exit 1; }

TASK_ROWS=()
defaults_set com.ops-desktop.smoke Num int 64 "Num"
[[ "$(row_field state)" == "pending" ]] || { echo "expected pending, got $(row_field state)"; exit 1; }

# Real (non-dry-run) apply.
TASK_MODE="apply"
DRY_RUN="false"
TASK_ONLY=""
defaults_set com.ops-desktop.smoke Bar int 7 "Bar"
applied_value="$(defaults read com.ops-desktop.smoke Bar)"
[[ "$applied_value" == "7" ]] || { echo "expected Bar=7, got $applied_value"; exit 1; }

# defaults_hook: status mode, check command decides applied/pending.
TASK_MODE="status"
TASK_ROWS=()
defaults_hook "hooktest" "Hook Label" "true" "true"
[[ "$(row_field state)" == "applied" ]] || { echo "expected hook applied, got $(row_field state)"; exit 1; }

TASK_ROWS=()
defaults_hook "hooktest" "Hook Label" "false" "true"
[[ "$(row_field state)" == "pending" ]] || { echo "expected hook pending, got $(row_field state)"; exit 1; }

# In apply mode, a non-matching TASK_ONLY must run nothing.
TASK_MODE="apply"
TASK_ONLY="defaults:smoke:does-not-match"
rm -f "$tmpdir/touched"
defaults_hook "hooktest" "Hook Label" "false" "touch $tmpdir/touched"
[[ ! -e "$tmpdir/touched" ]] || { echo "hook ran despite non-matching TASK_ONLY"; exit 1; }

echo "defaults-compare-ok"
EOF
    )"

    assert_contains "$output" "defaults-compare-ok"
}

test_tasks_apply_unknown_id() {
    if run_capture "$REPO_ROOT/lib/tasks.sh" apply defaults "nope:nope"; then
        fail "lib/tasks.sh apply defaults nope:nope should have failed"
    fi

    assert_contains "$RUN_OUTPUT" "Unknown id"
}

test_mismatched_profile_rejected
test_supported_dry_runs
test_symlink_safety
test_linux_package_failures_continue
test_unsupported_linux_rejected
test_macos_installer_scripts
test_tasks_status_json
test_json_str_escaping
test_defaults_compare
test_tasks_apply_unknown_id

echo "bash smoke tests passed"
