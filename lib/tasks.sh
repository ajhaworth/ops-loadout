#!/usr/bin/env bash
# lib/tasks.sh - macOS status/apply feed for the Ops Launcher's Setup tab
#
# Usage:
#   lib/tasks.sh status <section> [--profile name]
#   lib/tasks.sh apply  <section> <id> [--profile name]
#
# Sections: prereq, dotfiles, defaults
#
# status prints exactly one JSON array on stdout and nothing else - see
# CLAUDE.md "Setup Tasks (launcher)" for the row shape and state values.
# apply streams plain text and exits non-zero on failure.
#
# This file is both sourced (by platforms/macos/defaults.sh, so
# ./setup.sh defaults keeps working through defaults_set/defaults_hook) and
# run directly by the launcher. The include guard below stops the second
# sourcing from re-triggering main() when defaults.sh sources this file back.

if [[ -n "${_TASKS_SH_SOURCED:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_TASKS_SH_SOURCED=1

# No `set -e` here: this file is sourced by platforms/macos/defaults.sh (like
# every other lib/*.sh, which leave shell options to the entry script), and
# `set -e` inside a function invoked from an if/while/&&/|| test is silently
# suspended for that function's *entire* call tree - relying on it to abort
# on a nested defaults_set failure would not work. Failure is tracked
# explicitly via TASK_FAILED/TASK_MATCHED instead; see main() below, which
# turns `-euo pipefail` on for its own standalone-run case.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/detect.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/symlink.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/dotfiles.sh"

# ============================================================================
# Global state
# ============================================================================
# Always initialized so callers running under `set -u` (setup.sh) can
# reference these directly, whether or not lib/tasks.sh's own main() runs.

TASK_MODE=""          # status | apply (defaults to "apply" when unset)
TASK_ONLY=""          # id to apply; empty means "every item" (legacy full run)
TASK_MATCHED="false"  # did TASK_ONLY match a real item in this run?
TASK_GROUP_ID=""      # module id, set by the defaults discovery loop
TASK_GROUP=""         # title-cased module name, set by the defaults discovery loop
TASK_CHANGED=0
TASK_SKIPPED=0
TASK_FAILED=0
TASK_ROWS=()

# ============================================================================
# JSON helpers
# ============================================================================

json_str() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# Usage: emit_row id section group name state detail
emit_row() {
    local id="$1" section="$2" group="$3" name="$4" state="$5" detail="$6"
    TASK_ROWS+=("$(printf '{"id":"%s","section":"%s","group":"%s","name":"%s","state":"%s","detail":"%s"}' \
        "$(json_str "$id")" "$(json_str "$section")" "$(json_str "$group")" \
        "$(json_str "$name")" "$(json_str "$state")" "$(json_str "$detail")")")
}

print_rows_json() {
    local out="[" n i
    n=${#TASK_ROWS[@]}
    for ((i = 0; i < n; i++)); do
        if [[ $i -gt 0 ]]; then
            out+=","
        fi
        out+="${TASK_ROWS[$i]}"
    done
    out+="]"
    printf '%s\n' "$out" >&3
}

# ============================================================================
# Small helpers
# ============================================================================

tasks_trim() {
    printf '%s' "$1" | xargs 2>/dev/null || printf '%s' "$1"
}

# "software-dev" -> "Software Dev", "dock" -> "Dock"
tasks_title_case() {
    local input="$1" word out=""
    for word in $(printf '%s' "$input" | tr '_-' '  '); do
        local first="${word:0:1}" rest="${word:1}"
        first="$(printf '%s' "$first" | tr '[:lower:]' '[:upper:]')"
        out="$out$first$rest "
    done
    printf '%s' "${out% }"
}

tasks_load_profile() {
    local name="$1"
    if [[ -z "$name" ]]; then
        return 0
    fi

    local file="$REPO_ROOT/config/profiles/${name}.conf"
    if [[ ! -f "$file" ]]; then
        echo "Profile not found: $name" >&2
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$file"
    export PROFILE_NAME="$name"
}

# ============================================================================
# Declarative macOS defaults helpers, used by platforms/macos/defaults/*.sh
# ============================================================================
#
# defaults_set  <domain> <key> <type> <value> <label>   # type bool|int|float|string
# defaults_hook <hook-id> <label> <check-cmd> <apply-cmd>
#
# Both branch on TASK_MODE (unset == legacy "apply everything" behavior) and
# TASK_ONLY (the single id to apply; empty means every item), and honour
# is_dry_run in apply mode. Status is the apply traversal with writes turned
# off - there is one code path per item, not a separate checker.

defaults_normalize_bool() {
    case "$1" in
        true | yes | 1) echo 1 ;;
        *) echo 0 ;;
    esac
}

defaults_set() {
    local domain="$1" key="$2" type="$3" value="$4" label="$5"
    local id="defaults:${TASK_GROUP_ID}:${domain}/${key}"

    local desired="$value"
    if [[ "$type" == "bool" ]]; then
        desired="$(defaults_normalize_bool "$value")"
    fi
    # ponytail: float compares as text; no float settings exist today
    desired="$(tasks_trim "$desired")"

    local current state detail
    if ! current="$(defaults read "$domain" "$key" 2>/dev/null)"; then
        state="pending"
        detail="not set"
    else
        current="$(tasks_trim "$current")"
        if [[ "$current" == "$desired" ]]; then
            state="applied"
            detail="$current"
        else
            state="pending"
            detail="currently $current, want $desired"
        fi
    fi

    if [[ "${TASK_MODE:-apply}" == "status" ]]; then
        emit_row "$id" "defaults" "$TASK_GROUP" "$label" "$state" "$detail"
        return 0
    fi

    if [[ -n "$TASK_ONLY" ]] && [[ "$TASK_ONLY" != "$id" ]]; then
        return 0
    fi
    if [[ -n "$TASK_ONLY" ]]; then
        TASK_MATCHED="true"
    fi

    if [[ "$state" == "applied" ]]; then
        log_substep "Skip: $label ($detail)"
        TASK_SKIPPED=$((TASK_SKIPPED + 1))
        return 0
    fi

    if is_dry_run; then
        log_dry "defaults write $domain $key -$type $value  # $label"
        return 0
    fi

    local write_err
    if write_err=$(defaults write "$domain" "$key" "-$type" "$value" 2>&1); then
        log_substep "$label"
        TASK_CHANGED=$((TASK_CHANGED + 1))
    else
        # Sandboxed apps keep their plist in ~/Library/Containers, which TCC
        # gates per calling app - the launcher needs Full Disk Access.
        if [[ "$write_err" == *"/Library/Containers/"* ]]; then
            write_err="$write_err (grant Ops Launcher Full Disk Access in System Settings > Privacy & Security)"
        fi
        log_error "$label: $write_err"
        TASK_FAILED=$((TASK_FAILED + 1))
        if [[ -n "$TASK_ONLY" ]]; then
            return 1
        fi
    fi
}

# Usage: defaults_hook <hook-id> <label> <check-cmd> <apply-cmd>
# check exit 0 == applied; both commands are run via bash -c.
defaults_hook() {
    local hook_id="$1" label="$2" check_cmd="$3" apply_cmd="$4"
    local id="defaults:${TASK_GROUP_ID}:${hook_id}"

    local state detail
    if bash -c "$check_cmd" &>/dev/null; then
        state="applied"
        detail="$label"
    else
        state="pending"
        detail="not applied"
    fi

    if [[ "${TASK_MODE:-apply}" == "status" ]]; then
        emit_row "$id" "defaults" "$TASK_GROUP" "$label" "$state" "$detail"
        return 0
    fi

    if [[ -n "$TASK_ONLY" ]] && [[ "$TASK_ONLY" != "$id" ]]; then
        return 0
    fi
    if [[ -n "$TASK_ONLY" ]]; then
        TASK_MATCHED="true"
    fi

    if [[ "$state" == "applied" ]]; then
        log_substep "Skip: $label"
        TASK_SKIPPED=$((TASK_SKIPPED + 1))
        return 0
    fi

    if is_dry_run; then
        log_dry "$apply_cmd  # $label"
        return 0
    fi

    local apply_err
    if apply_err=$(bash -c "$apply_cmd" 2>&1); then
        log_substep "$label"
        TASK_CHANGED=$((TASK_CHANGED + 1))
    else
        log_error "$label: $apply_err"
        TASK_FAILED=$((TASK_FAILED + 1))
        if [[ -n "$TASK_ONLY" ]]; then
            return 1
        fi
    fi
}

# ============================================================================
# Section: defaults
# ============================================================================

tasks_defaults() {
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/platforms/macos/defaults.sh"
    setup_defaults
}

# ============================================================================
# Section: dotfiles
# ============================================================================

tasks_dotfiles() {
    local manifest="$REPO_ROOT/config/dotfiles/manifest.txt"
    if [[ ! -f "$manifest" ]]; then
        echo "Dotfiles manifest not found: $manifest" >&2
        return 1
    fi

    while IFS='|' read -r source destination backup condition || [[ -n "$source" ]]; do
        [[ -z "$source" ]] && continue
        [[ "$source" =~ ^[[:space:]]*# ]] && continue

        source="$(tasks_trim "$source")"
        destination="$(tasks_trim "$destination")"
        condition="$(tasks_trim "${condition:-}")"
        # The manifest backup column is reserved for future behavior and is ignored today.
        : "${backup:-}"

        if [[ -n "$condition" ]]; then
            local condition_value="${!condition:-true}"
            if [[ "$condition_value" != "true" ]]; then
                continue
            fi
        fi

        resolve_manifest_paths "$REPO_ROOT" "$source" "$destination"

        local id="dotfiles:$destination"
        local state detail
        if [[ ! -e "$MANIFEST_ABS_SOURCE" ]]; then
            state="failed"
            detail="source missing: $source"
        else
            local ms
            ms="$(manifest_state "$MANIFEST_ABS_SOURCE" "$MANIFEST_ABS_DEST")"
            case "$ms" in
                linked)
                    state="applied"
                    detail="linked"
                    ;;
                wrong)
                    state="pending"
                    detail="points to $(shorten_path "$(resolve_symlink_target "$MANIFEST_ABS_DEST")")"
                    ;;
                conflict)
                    state="pending"
                    detail="file exists, will be backed up"
                    ;;
                *)
                    state="pending"
                    detail="missing"
                    ;;
            esac
        fi

        if [[ "${TASK_MODE:-apply}" == "status" ]]; then
            emit_row "$id" "dotfiles" "Dotfiles" "$destination" "$state" "$detail"
            continue
        fi

        if [[ -n "$TASK_ONLY" ]] && [[ "$TASK_ONLY" != "$id" ]]; then
            continue
        fi
        if [[ -n "$TASK_ONLY" ]]; then
            TASK_MATCHED="true"
        fi

        if [[ "$state" == "failed" ]]; then
            log_error "$destination: $detail"
            TASK_FAILED=$((TASK_FAILED + 1))
            return 1
        fi
        if [[ "$state" == "applied" ]]; then
            log_substep "Already linked: $destination"
            continue
        fi

        create_symlink "$MANIFEST_ABS_SOURCE" "$destination"
    done < "$manifest"
}

# ============================================================================
# Section: prereq
# ============================================================================

tasks_load_prereq_deps() {
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/platforms/macos/setup.sh"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/platforms/macos/homebrew.sh"
}

# brew may be installed at /opt/homebrew/bin (Apple Silicon) or /usr/local/bin
# (Intel) without either being on PATH when the launcher runs this - check
# both explicitly rather than relying on command_exists alone.
tasks_brew_path() {
    if command_exists brew; then
        command -v brew
        return 0
    fi
    if [[ -x /opt/homebrew/bin/brew ]]; then
        echo /opt/homebrew/bin/brew
        return 0
    fi
    if [[ -x /usr/local/bin/brew ]]; then
        echo /usr/local/bin/brew
        return 0
    fi
    return 1
}

tasks_check_xcode_clt() { xcode-select -p &>/dev/null; }
tasks_check_brew() { tasks_brew_path >/dev/null 2>&1; }
tasks_check_mas() { command_exists mas; }
tasks_check_git() { command_exists git; }

tasks_detail_xcode_clt() {
    xcode-select -p 2>/dev/null || true
}

tasks_detail_brew() {
    local b
    b="$(tasks_brew_path)" || return 0
    "$b" --version 2>/dev/null | head -1 || true
}

tasks_detail_mas() {
    mas version 2>/dev/null || true
}

tasks_detail_git() {
    git --version 2>/dev/null || true
}

tasks_apply_homebrew() {
    if tasks_brew_path >/dev/null 2>&1; then
        eval_brew_shellenv
        return 0
    fi
    install_homebrew
}

tasks_apply_mas() {
    if command_exists mas; then
        return 0
    fi
    if is_dry_run; then
        log_dry "brew install mas"
        return 0
    fi
    brew install mas
}

# Usage: tasks_prereq_row id name check_fn apply_fn detail_fn
tasks_prereq_row() {
    local id="$1" name="$2" check_fn="$3" apply_fn="$4" detail_fn="$5"
    local state detail

    if "$check_fn"; then
        state="applied"
        detail="$("$detail_fn")" || detail=""
    else
        state="pending"
        detail="not installed"
    fi

    if [[ "${TASK_MODE:-apply}" == "status" ]]; then
        emit_row "$id" "prereq" "Tools" "$name" "$state" "$detail"
        return 0
    fi

    if [[ -n "$TASK_ONLY" ]] && [[ "$TASK_ONLY" != "$id" ]]; then
        return 0
    fi
    if [[ -n "$TASK_ONLY" ]]; then
        TASK_MATCHED="true"
    fi

    if [[ "$state" == "applied" ]]; then
        log_substep "Skip: $name ($detail)"
        return 0
    fi

    if is_dry_run; then
        log_dry "Install $name"
        return 0
    fi

    if "$apply_fn"; then
        log_substep "$name installed"
    else
        log_error "$name: install failed"
        TASK_FAILED=$((TASK_FAILED + 1))
        if [[ -n "$TASK_ONLY" ]]; then
            return 1
        fi
    fi
}

tasks_prereq() {
    tasks_load_prereq_deps

    tasks_prereq_row "prereq:xcode-clt" "Xcode Command Line Tools" \
        tasks_check_xcode_clt ensure_xcode_clt tasks_detail_xcode_clt

    if [[ "${PROFILE_HOMEBREW:-true}" != "false" ]]; then
        tasks_prereq_row "prereq:homebrew" "Homebrew" \
            tasks_check_brew tasks_apply_homebrew tasks_detail_brew
        if [[ "${PROFILE_MAS:-true}" != "false" ]]; then
            tasks_prereq_row "prereq:mas" "mas (Mac App Store CLI)" \
                tasks_check_mas tasks_apply_mas tasks_detail_mas
        fi
    fi

    tasks_prereq_row "prereq:git" "git" \
        tasks_check_git ensure_xcode_clt tasks_detail_git
}

# ============================================================================
# CLI entry point
# ============================================================================

tasks_usage() {
    cat <<'EOF' >&2
Usage:
  lib/tasks.sh status <section> [--profile name]
  lib/tasks.sh apply  <section> <id> [--profile name]

Sections: prereq, dotfiles, defaults
EOF
}

main() {
    if [[ $# -lt 2 ]]; then
        tasks_usage
        exit 1
    fi

    local verb="$1" section="$2"
    shift 2

    case "$verb" in
        status) TASK_MODE="status" ;;
        apply) TASK_MODE="apply" ;;
        *)
            tasks_usage
            exit 1
            ;;
    esac

    local id=""
    if [[ "$TASK_MODE" == "apply" ]]; then
        if [[ $# -lt 1 ]]; then
            tasks_usage
            exit 1
        fi
        id="$1"
        shift
    fi

    local profile=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile)
                if [[ $# -lt 2 ]]; then
                    tasks_usage
                    exit 1
                fi
                profile="$2"
                shift 2
                ;;
            --profile=*)
                profile="${1#*=}"
                shift
                ;;
            *)
                echo "Unknown option: $1" >&2
                tasks_usage
                exit 1
                ;;
        esac
    done

    TASK_ONLY="$id"
    TASK_MATCHED="false"
    SCRIPT_DIR="$REPO_ROOT"
    DRY_RUN="${DRY_RUN:-false}"
    FORCE="${FORCE:-false}"
    export DRY_RUN FORCE SCRIPT_DIR

    tasks_load_profile "$profile"

    if [[ "$TASK_MODE" == "status" ]]; then
        exec 3>&1 1>&2
    fi

    case "$section" in
        prereq) tasks_prereq ;;
        dotfiles) tasks_dotfiles ;;
        defaults) tasks_defaults ;;
        *)
            echo "Unknown section: $section" >&2
            exit 1
            ;;
    esac

    if [[ "$TASK_MODE" == "status" ]]; then
        print_rows_json
        exit 0
    fi

    if [[ "$TASK_MATCHED" != "true" ]]; then
        echo "Unknown id: $TASK_ONLY" >&2
        exit 1
    fi

    if [[ "$TASK_FAILED" -gt 0 ]]; then
        exit 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # Only the standalone entry point gets the strict repo-wide shell
    # options; sourced usage leaves that to the entry script (setup.sh).
    set -euo pipefail
    main "$@"
fi
