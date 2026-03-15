#!/usr/bin/env bash
# dotfiles.sh - Shared dotfiles setup functions

# Create local override files for user-specific settings
create_local_overrides() {
    log_step "Checking local override files"

    # Create zshrc.local if needed
    create_zshrc_local

    # Create gitconfig.local if git dotfiles are enabled
    if [[ "${DOTFILES_GIT:-true}" == "true" ]]; then
        create_gitconfig_local
    fi
}

# Create ~/.zshrc.local with template
create_zshrc_local() {
    local file="$HOME/.zshrc.local"

    if [[ -f "$file" ]]; then
        log_substep "Already exists: $file"
        return 0
    fi

    log_substep "Creating: $file"

    if is_dry_run; then
        log_dry "touch $file"
        return 0
    fi

    cat > "$file" << 'EOF'
# ~/.zshrc.local - Machine-specific shell configuration
# This file is sourced by .zshrc and is not tracked by git

# Add your machine-specific aliases and functions here
# Example:
# export PATH="$HOME/custom/bin:$PATH"
# alias myalias='my-command'
EOF
}

# Create ~/.gitconfig.local, prompting for user info if interactive
create_gitconfig_local() {
    local file="$HOME/.gitconfig.local"

    if [[ -f "$file" ]]; then
        log_substep "Already exists: $file"
        return 0
    fi

    log_substep "Creating: $file"

    if is_dry_run; then
        log_dry "Would prompt for git name and email (interactive) or create template"
        return 0
    fi

    # Interactive mode: prompt for git user info
    if [[ -t 0 ]] && [[ "${FORCE:-false}" != "true" ]]; then
        log_info "Setting up git configuration..."
        echo ""

        prompt_input "Git user name" ""
        local git_name="$REPLY"

        prompt_input "Git email" ""
        local git_email="$REPLY"

        cat > "$file" << EOF
# ~/.gitconfig.local - Machine-specific git configuration
# This file is included by .gitconfig and is not tracked by git

[user]
    name = $git_name
    email = $git_email

# Credential helper (uncomment one based on your OS and preference)
# [credential]
#     helper = osxkeychain                    # macOS Keychain
#     helper = cache --timeout=3600           # Linux: cache for 1 hour
#     helper = store                          # Linux: store in plaintext (~/.git-credentials)
#     helper = /usr/local/share/gcm-core/git-credential-manager  # Git Credential Manager

# Optional: signing key
# [user]
#     signingkey = YOUR_GPG_KEY_ID
# [commit]
#     gpgsign = true
EOF
        log_success "Git configuration saved to $file"
    else
        # Non-interactive: create template with placeholders
        cat > "$file" << 'EOF'
# ~/.gitconfig.local - Machine-specific git configuration
# This file is included by .gitconfig and is not tracked by git

# IMPORTANT: Set your user info here
[user]
    name = Your Name
    email = your.email@example.com

# Credential helper (uncomment one based on your OS and preference)
# [credential]
#     helper = osxkeychain                    # macOS Keychain
#     helper = cache --timeout=3600           # Linux: cache for 1 hour
#     helper = store                          # Linux: store in plaintext (~/.git-credentials)
#     helper = /usr/local/share/gcm-core/git-credential-manager  # Git Credential Manager

# Optional: signing key
# [user]
#     signingkey = YOUR_GPG_KEY_ID
# [commit]
#     gpgsign = true
EOF
        log_info "Please edit $file with your settings"
    fi
}

# Configure git credential helper for GitHub CLI in .gitconfig.local
# We write to .gitconfig.local instead of using 'gh auth setup-git' because
# ~/.gitconfig is symlinked to our shared config, and the credential helper
# path is OS-specific (e.g., /usr/bin/gh on Linux, /opt/homebrew/bin/gh on macOS)
configure_gh_credential_helper() {
    local config_file="$HOME/.gitconfig.local"
    local gh_path
    gh_path="$(command -v gh)"

    # Check if credential helper is already configured
    if grep -q "gh auth git-credential" "$config_file" 2>/dev/null; then
        log_substep "GitHub CLI credential helper already configured"
        return 0
    fi

    log_substep "Adding GitHub CLI credential helper to .gitconfig.local"

    if is_dry_run; then
        log_dry "Would add credential helper to $config_file"
        return 0
    fi

    # Append credential helper configuration
    cat >> "$config_file" << EOF

# GitHub CLI credential helper
[credential "https://github.com"]
    helper =
    helper = !${gh_path} auth git-credential
[credential "https://gist.github.com"]
    helper =
    helper = !${gh_path} auth git-credential
EOF
    log_success "Configured git to use GitHub CLI for credentials"
}

# Setup GitHub CLI authentication
setup_gh_auth() {
    log_step "Checking GitHub CLI authentication"

    # Check if gh is installed
    if ! command_exists gh; then
        log_substep "GitHub CLI (gh) not installed - skipping"
        return 0
    fi

    # Check if already authenticated
    if gh auth status &>/dev/null; then
        log_substep "GitHub CLI already authenticated"
        configure_gh_credential_helper
        return 0
    fi

    log_substep "GitHub CLI not authenticated"

    if is_dry_run; then
        log_dry "Would prompt for GitHub CLI authentication"
        return 0
    fi

    # Only prompt in interactive mode
    if [[ -t 0 ]] && [[ "${FORCE:-false}" != "true" ]]; then
        echo ""
        log_info "GitHub CLI is installed but not authenticated."
        log_info "Authentication enables: git push/pull, PR creation, and more."
        echo ""

        while true; do
            if yes_no "Would you like to authenticate GitHub CLI now?" "y"; then
                echo ""
                log_info "Choose 'Login with a web browser' for easiest setup."
                log_info "If using a token, ensure it has scopes: repo, read:org, workflow"
                echo ""
                gh auth login

                if gh auth status &>/dev/null; then
                    log_success "GitHub CLI authenticated successfully"
                    configure_gh_credential_helper
                    break
                else
                    echo ""
                    log_warn "GitHub CLI authentication incomplete"
                    if ! yes_no "Would you like to try again?" "y"; then
                        log_info "You can authenticate later with: gh auth login"
                        break
                    fi
                fi
            else
                log_info "Skipped. You can authenticate later with: gh auth login"
                break
            fi
        done
    else
        log_info "Run 'gh auth login' to authenticate"
    fi
}

# List dotfiles and their symlink status
cmd_dotfiles_ls() {
    local manifest="$SCRIPT_DIR/config/dotfiles/manifest.txt"

    if [[ ! -f "$manifest" ]]; then
        log_error "Manifest not found: $manifest"
        return 1
    fi

    echo ""
    log_step "Dotfiles"
    echo ""

    # Print header
    printf "  ${BOLD}%-40s  %-50s  %s${RESET}\n" "SOURCE" "DESTINATION" "STATUS"
    printf "  ${DIM}%-40s  %-50s  %s${RESET}\n" "$(printf '─%.0s' {1..40})" "$(printf '─%.0s' {1..50})" "$(printf '─%.0s' {1..12})"

    local count_ok=0
    local count_missing=0
    local count_wrong=0
    local count_conflict=0

    while IFS='|' read -r source destination _ condition || [[ -n "$source" ]]; do
        # Skip empty lines and comments
        [[ -z "$source" ]] && continue
        [[ "$source" =~ ^[[:space:]]*# ]] && continue

        # Trim whitespace
        source="$(echo "$source" | xargs)"
        destination="$(echo "$destination" | xargs)"
        condition="$(echo "${condition:-}" | xargs)"

        # Check condition if specified
        if [[ -n "$condition" ]]; then
            local condition_value="${!condition:-true}"
            if [[ "$condition_value" != "true" ]]; then
                continue
            fi
        fi

        # Make paths absolute
        local abs_source="$source"
        if [[ "$source" != /* ]]; then
            abs_source="$SCRIPT_DIR/$source"
        fi
        abs_source="$(normalize_path "$abs_source")"
        local abs_dest="${destination/#\~/$HOME}"

        # Shorten paths for display
        local display_source="${source#config/dotfiles/}"
        local display_dest="${destination/#\~\//~/}"

        # Check symlink status
        local status status_color
        if [[ -L "$abs_dest" ]]; then
            local target
            target="$(resolve_symlink_target "$abs_dest")"
            if [[ "$target" == "$abs_source" ]]; then
                status="linked"
                status_color="${GREEN}"
                ((count_ok++))
            else
                status="wrong target"
                status_color="${YELLOW}"
                ((count_wrong++))
            fi
        elif [[ -e "$abs_dest" ]]; then
            status="conflict"
            status_color="${RED}"
            ((count_conflict++))
        else
            status="missing"
            status_color="${RED}"
            ((count_missing++))
        fi

        printf "  %-40s  %-50s  ${status_color}%s${RESET}\n" "$display_source" "$display_dest" "$status"
    done < "$manifest"

    # Print summary
    echo ""
    printf "  ${DIM}%-40s  %-50s  %s${RESET}\n" "$(printf '─%.0s' {1..40})" "$(printf '─%.0s' {1..50})" "$(printf '─%.0s' {1..12})"
    echo ""
    echo -e "  ${BOLD}Summary:${RESET} ${GREEN}$count_ok linked${RESET}"
    if [[ $count_missing -gt 0 ]]; then
        echo -e "           ${RED}$count_missing missing${RESET}"
    fi
    if [[ $count_wrong -gt 0 ]]; then
        echo -e "           ${YELLOW}$count_wrong wrong target${RESET}"
    fi
    if [[ $count_conflict -gt 0 ]]; then
        echo -e "           ${RED}$count_conflict conflict${RESET} (file exists but not a symlink)"
    fi
    echo ""

    if [[ $count_missing -gt 0 ]] || [[ $count_wrong -gt 0 ]] || [[ $count_conflict -gt 0 ]]; then
        log_info "Run './setup.sh dotfiles' to fix issues"
        echo ""
    fi
}

# Configure shell to set terminal title (for tmux hostname display)
cmd_shell_title() {
    local bashrc="$HOME/.bashrc"
    local zshrc="$HOME/.zshrc"
    local marker="# Terminal title for tmux"
    local bash_config='
# Terminal title for tmux (shows hostname in status bar)
PROMPT_COMMAND='\''printf "\\e]2;%s\\a" "$HOSTNAME"'\''${PROMPT_COMMAND:+;$PROMPT_COMMAND}'

    local zsh_config='
# Terminal title for tmux (shows hostname in status bar)
precmd_set_title() { print -Pn "\\e]2;%m\\a" }
autoload -Uz add-zsh-hook
add-zsh-hook precmd precmd_set_title'

    local added=false

    # Configure bashrc
    if [[ -f "$bashrc" ]]; then
        if grep -q "$marker" "$bashrc" 2>/dev/null; then
            log_info "bashrc already configured"
        else
            if is_dry_run; then
                log_info "[DRY-RUN] Would add terminal title config to $bashrc"
            else
                echo "" >> "$bashrc"
                echo "$marker" >> "$bashrc"
                echo "$bash_config" >> "$bashrc"
                log_success "Added terminal title config to $bashrc"
                added=true
            fi
        fi
    fi

    # Configure zshrc
    if [[ -f "$zshrc" ]]; then
        if grep -q "$marker" "$zshrc" 2>/dev/null; then
            log_info "zshrc already configured"
        else
            if is_dry_run; then
                log_info "[DRY-RUN] Would add terminal title config to $zshrc"
            else
                echo "" >> "$zshrc"
                echo "$marker" >> "$zshrc"
                echo "$zsh_config" >> "$zshrc"
                log_success "Added terminal title config to $zshrc"
                added=true
            fi
        fi
    fi

    # Create bashrc if neither exists
    if [[ ! -f "$bashrc" ]] && [[ ! -f "$zshrc" ]]; then
        if is_dry_run; then
            log_info "[DRY-RUN] Would create $bashrc with terminal title config"
        else
            echo "$marker" > "$bashrc"
            echo "$bash_config" >> "$bashrc"
            log_success "Created $bashrc with terminal title config"
            added=true
        fi
    fi

    if [[ "$added" == "true" ]]; then
        echo ""
        log_info "Restart your shell or run: source ~/.bashrc (or ~/.zshrc)"
    fi
}

# Setup Docker authentication with GitHub Container Registry
setup_docker_ghcr_auth() {
    log_step "Configuring Docker for GitHub Container Registry"

    # Check if Docker is installed
    if ! command_exists docker; then
        log_substep "Docker not installed - skipping ghcr.io authentication"
        return 0
    fi

    # Check if GitHub CLI is installed and authenticated
    if ! command_exists gh; then
        log_substep "GitHub CLI not installed - skipping ghcr.io authentication"
        return 0
    fi

    if ! gh auth status &>/dev/null; then
        log_substep "GitHub CLI not authenticated - skipping ghcr.io authentication"
        return 0
    fi

    # Check if already logged into ghcr.io
    if docker login ghcr.io --get-login &>/dev/null 2>&1; then
        log_substep "Docker already authenticated with ghcr.io"
        return 0
    fi

    if is_dry_run; then
        log_dry "Would authenticate Docker with ghcr.io using GitHub CLI token"
        return 0
    fi

    log_substep "Authenticating Docker with ghcr.io..."
    local gh_user
    gh_user=$(gh api user --jq .login)

    if gh auth token | docker login ghcr.io -u "$gh_user" --password-stdin; then
        log_success "Docker authenticated with ghcr.io as $gh_user"
    else
        log_error "Failed to authenticate Docker with ghcr.io"
        return 1
    fi
}

# Unified dotfiles setup (used by both macOS and Linux platform scripts)
setup_dotfiles() {
    print_header "Dotfiles Setup"

    local manifest="$SCRIPT_DIR/config/dotfiles/manifest.txt"

    if [[ ! -f "$manifest" ]]; then
        log_warn "Dotfiles manifest not found: $manifest"
        return 0
    fi

    log_step "Processing dotfiles manifest"
    process_manifest "$manifest"

    log_step "Dotfiles status"
    check_manifest "$manifest" || true

    create_local_overrides
    setup_gh_auth

    if [[ "$(detect_os)" == "linux" ]]; then
        setup_docker_ghcr_auth
    fi

    log_success "Dotfiles setup complete"
}
