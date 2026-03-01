#!/usr/bin/env bash
# lib/claude-plugins.sh - Claude Code plugin sync
#
# Deploys plugin JSON configs from repo templates to ~/.claude/plugins/,
# fixing platform-specific home directory paths at copy time.
# Also provides a "save" function to export runtime state back to the repo.

PLUGIN_DIR="$HOME/.claude/plugins"
PLUGIN_REPO_DIR="config/dotfiles/claude/plugins"

# Deploy a single plugin JSON file from repo to ~/.claude/plugins/.
# Replaces any stale home directory paths with current $HOME.
# Removes old symlinks (migration from previous approach).
# Skips write if destination content already matches.
_deploy_plugin_json() {
    local filename="$1"
    local repo_root
    repo_root="$(get_repo_root)"
    local src="$repo_root/$PLUGIN_REPO_DIR/$filename"
    local dest="$PLUGIN_DIR/$filename"

    if [[ ! -f "$src" ]]; then
        log_warn "Template not found: $src"
        return 1
    fi

    # Read source content and fix stale home paths
    local content
    content="$(<"$src")"

    # Find any /home/<user> or /Users/<user> that doesn't match $HOME
    local stale_home
    stale_home=$(echo "$content" | grep -oE '(/home/[^/]+|/Users/[^/]+)' \
        | sort -u | grep -v "^$HOME$" | head -1) || true

    if [[ -n "$stale_home" ]]; then
        log_info "Fixing paths: $stale_home → $HOME"
        content="${content//$stale_home/$HOME}"
    fi

    # Check if destination already has identical content
    if [[ -f "$dest" ]] && [[ ! -L "$dest" ]]; then
        local existing
        existing="$(<"$dest")"
        if [[ "$content" == "$existing" ]]; then
            log_info "Already up-to-date: $filename"
            return 0
        fi
    fi

    if is_dry_run; then
        log_dry "Deploy $filename → $dest"
        return 0
    fi

    # Remove old symlink if present (migration from symlink approach)
    if [[ -L "$dest" ]]; then
        log_info "Removing old symlink: $dest"
        rm "$dest"
    fi

    mkdir -p "$(dirname "$dest")"
    printf '%s\n' "$content" > "$dest"
    log_success "Deployed $filename"
}

# Copy a runtime plugin JSON file back to the repo.
_save_plugin_json() {
    local filename="$1"
    local repo_root
    repo_root="$(get_repo_root)"
    local src="$PLUGIN_DIR/$filename"
    local dest="$repo_root/$PLUGIN_REPO_DIR/$filename"

    if [[ ! -f "$src" ]]; then
        log_warn "Runtime file not found: $src"
        return 1
    fi

    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    log_success "Saved $filename → $PLUGIN_REPO_DIR/$filename"
}

# Deploy plugin configs and sync plugins with Claude Code CLI.
setup_claude_plugins() {
    log_step "Syncing Claude Code plugins"

    if [[ "${DOTFILES_CLAUDE:-true}" == "false" ]]; then
        log_info "Skipping Claude plugins (disabled in profile)"
        return 0
    fi

    # Deploy JSON configs (doesn't need the CLI)
    log_substep "Deploying plugin configs"
    _deploy_plugin_json "known_marketplaces.json"
    _deploy_plugin_json "installed_plugins.json"

    if ! command_exists claude; then
        log_warn "Claude Code not installed, skipping plugin sync"
        return 0
    fi

    local marketplaces_file="$PLUGIN_DIR/known_marketplaces.json"
    local plugins_file="$PLUGIN_DIR/installed_plugins.json"

    # Register marketplaces
    if [[ -f "$marketplaces_file" ]]; then
        log_substep "Registering marketplaces"
        local repos
        repos=$(grep '"repo"' "$marketplaces_file" | sed 's/.*"repo"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

        while IFS= read -r repo; do
            [[ -z "$repo" ]] && continue
            if [[ -d "$PLUGIN_DIR/marketplaces/$(basename "$repo")" ]]; then
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
            local cache_dir="$PLUGIN_DIR/cache/$marketplace/$plugin_name"

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

# Save current plugin state from ~/.claude/plugins/ back to the repo.
save_claude_plugins() {
    log_step "Saving Claude plugin state to repo"

    _save_plugin_json "installed_plugins.json"
    _save_plugin_json "known_marketplaces.json"

    log_success "Plugin state saved — commit changes in $PLUGIN_REPO_DIR/"
}
