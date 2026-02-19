#!/usr/bin/env bash
# lib/claude-plugins.sh - Claude Code plugin sync
#
# Reads symlinked plugin JSON configs and ensures marketplaces are registered
# and plugins are installed on the current machine. Fixes absolute home directory
# paths that differ between machines (e.g., /home/alx vs /Users/alx).

# Fix hardcoded home directory paths in a JSON file.
# Detects any /home/<user> or /Users/<user> prefix that doesn't match $HOME
# and replaces it with the current $HOME.
_fix_plugin_paths() {
    local file="$1"

    # Find any home dir in the file that isn't our current $HOME
    local stale_home
    stale_home=$(grep -oE '"(/home/[^/]+|/Users/[^/]+)/' "$file" \
        | tr -d '"' | sort -u | grep -v "^$HOME/" | head -1) || true

    if [[ -z "$stale_home" ]]; then
        return 0
    fi

    # Remove trailing slash for clean replacement
    stale_home="${stale_home%/}"

    log_info "Fixing paths: $stale_home → $HOME"
    if is_dry_run; then
        log_dry "sed -i '' 's|$stale_home|$HOME|g' $file"
    else
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "s|${stale_home}|${HOME}|g" "$file"
        else
            sed -i "s|${stale_home}|${HOME}|g" "$file"
        fi
    fi
}

setup_claude_plugins() {
    log_step "Syncing Claude Code plugins"

    if [[ "${DOTFILES_CLAUDE:-true}" == "false" ]]; then
        log_info "Skipping Claude plugins (disabled in profile)"
        return 0
    fi

    if ! command_exists claude; then
        log_warn "Claude Code not installed, skipping plugin sync"
        return 0
    fi

    local repo_root
    repo_root="$(get_repo_root)"
    local marketplaces_file="$repo_root/config/dotfiles/claude/plugins/known_marketplaces.json"
    local plugins_file="$repo_root/config/dotfiles/claude/plugins/installed_plugins.json"

    # Fix home directory paths in JSON files
    log_substep "Checking paths"
    [[ -f "$marketplaces_file" ]] && _fix_plugin_paths "$marketplaces_file"
    [[ -f "$plugins_file" ]] && _fix_plugin_paths "$plugins_file"

    # Register marketplaces
    if [[ -f "$marketplaces_file" ]]; then
        log_substep "Registering marketplaces"
        local repos
        repos=$(grep '"repo"' "$marketplaces_file" | sed 's/.*"repo"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

        while IFS= read -r repo; do
            [[ -z "$repo" ]] && continue
            if [[ -d "$HOME/.claude/plugins/marketplaces/$(basename "$repo")" ]]; then
                log_info "Marketplace already registered: $repo"
            else
                log_info "Adding marketplace: $repo"
                if ! run_cmd claude plugin marketplace add "$repo" 2>&1; then
                    log_warn "Failed to add marketplace: $repo"
                fi
            fi
        done <<< "$repos"
    fi

    # Install plugins (reinstall any with missing cache dirs)
    if [[ -f "$plugins_file" ]]; then
        log_substep "Installing plugins"
        local keys
        keys=$(grep -oE '"[^"]+@[^"]+"' "$plugins_file" | tr -d '"' | sort -u)

        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            local plugin_name="${key%@*}"
            local marketplace="${key#*@}"
            local cache_dir="$HOME/.claude/plugins/cache/$marketplace/$plugin_name"

            if [[ -d "$cache_dir" ]]; then
                log_info "Already cached: $key"
                continue
            fi

            log_info "Installing: $key"
            # Remove stale entry so install can re-create it
            if ! is_dry_run; then
                claude plugin uninstall "$key" 2>&1 || true
            else
                log_dry "claude plugin uninstall $key"
            fi
            if ! run_cmd claude plugin install "$key" 2>&1; then
                log_warn "Failed to install plugin: $key"
            fi
        done <<< "$keys"
    fi

    log_success "Claude plugin sync complete"
}
