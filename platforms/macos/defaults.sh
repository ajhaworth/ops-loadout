#!/usr/bin/env bash
# platforms/macos/defaults.sh - System preferences orchestrator
#
# Each platforms/macos/defaults/*.sh file defines an apply_<name>() function
# built from defaults_set/defaults_hook calls (see lib/tasks.sh). This same
# discovery loop backs both `./setup.sh defaults` and the launcher's
# `lib/tasks.sh status|apply defaults ...` - one loop, one code path.

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/tasks.sh"

# Setup system defaults
setup_defaults() {
    local status_mode="false"
    if [[ "${TASK_MODE:-apply}" == "status" ]]; then
        status_mode="true"
    fi

    # A single targeted item (the launcher applying one toggle) skips the
    # orchestration side effects below too - quitting System Settings and
    # relaunching Finder/Dock/SystemUIServer for one setting is disruptive
    # and unnecessary; those only make sense for a full apply.
    local single_item="false"
    if [[ -n "${TASK_ONLY:-}" ]]; then
        single_item="true"
    fi

    print_header "System Preferences"

    local defaults_dir="$SCRIPT_DIR/platforms/macos/defaults"

    # Close System Settings/Preferences to prevent overriding changes
    # Note: Renamed from "System Preferences" to "System Settings" in macOS Ventura (13+)
    if [[ "$status_mode" != "true" ]] && [[ "$single_item" != "true" ]] && ! is_dry_run; then
        osascript -e 'tell application "System Settings" to quit' 2>/dev/null || \
        osascript -e 'tell application "System Preferences" to quit' 2>/dev/null || true
    fi

    TASK_CHANGED=0
    TASK_SKIPPED=0
    TASK_FAILED=0

    # Apply each defaults script
    for script in "$defaults_dir"/*.sh; do
        [[ -f "$script" ]] || continue

        local name
        name="$(basename "$script" .sh)"

        log_step "Applying: $name"

        TASK_GROUP_ID="$name"
        TASK_GROUP="$(tasks_title_case "$name")"

        # Source and run the script
        # shellcheck source=/dev/null
        source "$script"

        # Each script should define an apply_<name> function
        local func="apply_${name}"
        if declare -f "$func" &>/dev/null; then
            if ! "$func"; then
                log_warn "Some preferences in $name may not have been applied"
            fi
        else
            log_warn "No apply function found in $script"
        fi
    done

    log_success "System preferences applied"

    # Restart affected applications
    if [[ "$status_mode" != "true" ]] && [[ "$single_item" != "true" ]]; then
        restart_affected_apps
    fi

    if [[ "$status_mode" != "true" ]] && [[ "$single_item" != "true" ]]; then
        printf 'Defaults: %d changed, %d skipped, %d failed\n' "$TASK_CHANGED" "$TASK_SKIPPED" "$TASK_FAILED"
    fi
}

# Restart apps that need to pick up new preferences
restart_affected_apps() {
    log_step "Restarting affected applications"

    local apps=(
        "Dock"
        "Finder"
        "SystemUIServer"
    )

    for app in "${apps[@]}"; do
        if is_dry_run; then
            log_dry "killall $app"
        else
            killall "$app" 2>/dev/null || true
        fi
    done

    log_info "Some changes may require a logout/login to take effect"
}
