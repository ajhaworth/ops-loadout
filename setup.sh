#!/usr/bin/env bash
#
# setup.sh - Cross-platform workstation setup entry point
#
# Usage:
#   ./setup.sh [command] [subcommand] [options]
#
# Commands:
#   (none)              Run full setup (default)
#   dotfiles            Install/link dotfiles
#   dotfiles ls         List dotfiles and status
#
#   macOS only:
#   homebrew            Install Homebrew packages (formulae + casks)
#   homebrew ls         List Homebrew packages and status
#   formulae            Install Homebrew formulae only
#   formulae ls         List Homebrew formulae
#   casks               Install Homebrew casks only
#   casks ls            List Homebrew casks
#   mas                 Install Mac App Store apps
#   mas ls              List Mac App Store apps
#   defaults            Apply system preferences
#
#   Linux only:
#   packages            Install system packages (apt/dnf/etc)
#   packages ls         List system packages and status
#
#   All platforms:
#   claude-code         Install Claude Code (native installer)
#   codex               Install OpenAI Codex CLI (npm)
#   shell-title         Configure shell to set terminal title (for tmux hostname)
#
# Options:
#   --profile <name>    Use specified profile (personal, work)
#   --dry-run           Show what would be done without making changes
#   --force             Skip confirmation prompts
#   --help              Show this help message
#

set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source libraries
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/detect.sh"
source "$SCRIPT_DIR/lib/prompt.sh"
source "$SCRIPT_DIR/lib/symlink.sh"
source "$SCRIPT_DIR/lib/packages.sh"
source "$SCRIPT_DIR/lib/dotfiles.sh"
source "$SCRIPT_DIR/lib/claude-code.sh"
source "$SCRIPT_DIR/lib/codex.sh"
source "$SCRIPT_DIR/lib/claude-plugins.sh"

# Default options
PROFILE=""
DRY_RUN="false"
FORCE="false"

# Export for subshells and sourced scripts
export DRY_RUN FORCE

# Show help
show_help() {
    cat << EOF
Usage: ./setup.sh [command] [subcommand] [options]

Cross-platform workstation setup script.

Commands:
    (none)              Run full setup (default)
    dotfiles            Install/link dotfiles
    dotfiles ls         List dotfiles and status

  macOS only:
    homebrew            Install Homebrew packages (formulae + casks)
    homebrew ls         List Homebrew packages and status
    formulae            Install Homebrew formulae only
    formulae ls         List Homebrew formulae
    casks               Install Homebrew casks only
    casks ls            List Homebrew casks
    mas                 Install Mac App Store apps
    mas ls              List Mac App Store apps
    defaults            Apply system preferences

  Linux only:
    packages            Install system packages (apt/dnf/etc)
    packages ls         List system packages and status

  All platforms:
    claude-code         Install Claude Code (native installer)
    codex               Install OpenAI Codex CLI (npm)
    shell-title         Configure shell to set terminal title (for tmux hostname)

Options:
    --profile <name>    Use specified profile (personal, work)
    --dry-run           Show what would be done without making changes
    --force             Skip confirmation prompts
    --help              Show this help message

Examples:
    ./setup.sh                          # Full setup (interactive)
    ./setup.sh --profile personal       # Full setup with profile
    ./setup.sh dotfiles                 # Install just dotfiles
    ./setup.sh dotfiles ls              # List dotfiles status
    ./setup.sh homebrew                 # Install Homebrew packages (macOS)
    ./setup.sh homebrew ls              # List Homebrew packages (macOS)
    ./setup.sh defaults                 # Apply system preferences (macOS)
    ./setup.sh packages                 # Install system packages (Linux)
    ./setup.sh packages ls              # List system packages (Linux)
    ./setup.sh claude-code              # Install Claude Code
    ./setup.sh codex                    # Install OpenAI Codex CLI
    ./setup.sh shell-title              # Configure terminal title for tmux

Available profiles:
EOF
    local current_os
    current_os="$(detect_os)"
    for conf in "$SCRIPT_DIR/config/profiles"/*.conf; do
        if [[ -f "$conf" ]]; then
            local name profile_os
            name="$(basename "$conf" .conf)"
            profile_os=$(grep -E "^PROFILE_OS=" "$conf" 2>/dev/null | cut -d'"' -f2)
            # Show if no OS restriction or matches current OS
            if [[ -z "$profile_os" ]] || [[ "$profile_os" == "$current_os" ]]; then
                echo "    - $name"
            fi
        fi
    done
}

# ============================================================================
# Subcommand: dotfiles
# ============================================================================

# Override get_repo_root for subcommands
get_repo_root() {
    echo "$SCRIPT_DIR"
}

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
        local abs_dest="${destination/#\~/$HOME}"

        # Shorten paths for display
        local display_source="${source#config/dotfiles/}"
        local display_dest="${destination/#\~\//~/}"

        # Check symlink status
        local status status_color
        if [[ -L "$abs_dest" ]]; then
            local target
            target="$(readlink "$abs_dest")"
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

cmd_dotfiles_install() {
    print_banner
    log_step "Installing dotfiles"

    if is_dry_run; then
        log_warn "DRY-RUN MODE - No changes will be made"
        echo ""
    fi

    # Process manifest
    local manifest="$SCRIPT_DIR/config/dotfiles/manifest.txt"
    process_manifest "$manifest"

    # Show status
    echo ""
    log_step "Dotfiles status"
    check_manifest "$manifest"

    # Create local override files
    echo ""
    create_local_overrides

    # Check GitHub CLI authentication
    echo ""
    setup_gh_auth

    # Configure Docker for GitHub Container Registry
    echo ""
    setup_docker_ghcr_auth

    echo ""
    log_success "Dotfiles installation complete"
}

# ============================================================================
# Subcommand: shell-title (configure terminal title for tmux)
# ============================================================================

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

# ============================================================================
# Subcommand: packages (Linux)
# ============================================================================

cmd_packages_ls() {
    print_banner
    log_step "Linux packages status"
    echo ""
    check_packages
    echo ""
}

cmd_packages_install() {
    print_banner
    log_step "Installing Linux packages"

    if is_dry_run; then
        log_warn "DRY-RUN MODE - No changes will be made"
        echo ""
    fi

    setup_packages

    echo ""
    log_success "Package installation complete"
}

# ============================================================================
# Subcommand: homebrew/formulae/casks/mas
# ============================================================================

# Package directories
FORMULAE_DIR="$SCRIPT_DIR/config/packages/macos/formulae"
CASKS_DIR="$SCRIPT_DIR/config/packages/macos/casks"
MAS_DIR="$SCRIPT_DIR/config/packages/macos/mas"

# Cache for installed packages
INSTALLED_FORMULAE=""
INSTALLED_CASKS=""
INSTALLED_MAS=""

# Get list of installed formulae (cached)
get_installed_formulae() {
    if [[ -z "$INSTALLED_FORMULAE" ]]; then
        if command -v brew &>/dev/null; then
            INSTALLED_FORMULAE=$(brew list --formula 2>/dev/null || echo "")
        fi
    fi
    echo "$INSTALLED_FORMULAE"
}

# Get list of installed casks (cached)
get_installed_casks() {
    if [[ -z "$INSTALLED_CASKS" ]]; then
        if command -v brew &>/dev/null; then
            INSTALLED_CASKS=$(brew list --cask 2>/dev/null || echo "")
        fi
    fi
    echo "$INSTALLED_CASKS"
}

# Get list of installed MAS apps (cached)
get_installed_mas() {
    if [[ -z "$INSTALLED_MAS" ]]; then
        if command -v mas &>/dev/null; then
            INSTALLED_MAS=$(mas list 2>/dev/null | awk '{print $1}' || echo "")
        fi
    fi
    echo "$INSTALLED_MAS"
}

# Check if a formula is installed (handles versioned packages like python@3.14)
is_formula_installed() {
    local formula="$1"
    get_installed_formulae | grep -qE "^${formula}(@|$)"
}

# Check if a cask is installed
is_cask_installed() {
    local cask="$1"
    get_installed_casks | grep -qE "^${cask}$"
}

# Check if a MAS app is installed
is_mas_installed() {
    local app_id="$1"
    get_installed_mas | grep -qE "^${app_id}$"
}

# Generic helper to list brew package status
# Usage: list_brew_package_status packages_dir title is_check_func
list_brew_package_status() {
    local packages_dir="$1"
    local title="$2"
    local is_check_func="$3"

    echo ""
    log_step "$title"
    echo ""

    if [[ ! -d "$packages_dir" ]]; then
        log_warn "Directory not found: $packages_dir"
        return 1
    fi

    local total_count=0
    local installed_count=0
    local missing_count=0

    for file in "$packages_dir"/*.txt; do
        [[ -f "$file" ]] || continue

        local category
        category="$(basename "$file" .txt)"

        echo -e "  ${BOLD}${category}${RESET}"

        while IFS= read -r package || [[ -n "$package" ]]; do
            package="$(echo "$package" | xargs)"
            [[ -z "$package" ]] && continue
            [[ "$package" =~ ^# ]] && continue
            package="${package%%#*}"
            package="$(echo "$package" | xargs)"
            [[ -z "$package" ]] && continue

            ((total_count++))

            local status status_color
            if $is_check_func "$package"; then
                status="installed"
                status_color="${GREEN}"
                ((installed_count++))
            else
                status="missing"
                status_color="${RED}"
                ((missing_count++))
            fi

            printf "    %-35s ${status_color}%s${RESET}\n" "$package" "$status"
        done < "$file"

        echo ""
    done

    printf "  ${DIM}%s${RESET}\n" "$(printf '─%.0s' {1..50})"
    echo -e "  ${BOLD}Summary:${RESET} ${GREEN}$installed_count installed${RESET}, ${RED}$missing_count missing${RESET} (of $total_count total)"
    echo ""
}

cmd_formulae_ls() {
    list_brew_package_status "$FORMULAE_DIR" "Homebrew Formulae" is_formula_installed
}

cmd_casks_ls() {
    list_brew_package_status "$CASKS_DIR" "Homebrew Casks" is_cask_installed
}

cmd_mas_ls() {
    echo ""
    log_step "Mac App Store Apps"
    echo ""

    local mas_file="$MAS_DIR/apps.txt"

    if [[ ! -f "$mas_file" ]]; then
        log_warn "MAS apps file not found: $mas_file"
        return 1
    fi

    printf "  ${BOLD}%-12s  %-35s  %s${RESET}\n" "APP ID" "NAME" "STATUS"
    printf "  ${DIM}%-12s  %-35s  %s${RESET}\n" "$(printf '─%.0s' {1..12})" "$(printf '─%.0s' {1..35})" "$(printf '─%.0s' {1..12})"

    local total_count=0
    local installed_count=0
    local missing_count=0

    while IFS='|' read -r id name || [[ -n "$id" ]]; do
        id="$(echo "$id" | xargs)"
        name="$(echo "$name" | xargs)"

        [[ -z "$id" ]] && continue
        [[ "$id" =~ ^# ]] && continue
        [[ "$id" =~ ^[0-9]+$ ]] || continue

        ((total_count++))

        local status status_color
        if is_mas_installed "$id"; then
            status="installed"
            status_color="${GREEN}"
            ((installed_count++))
        else
            status="missing"
            status_color="${RED}"
            ((missing_count++))
        fi

        printf "  %-12s  %-35s  ${status_color}%s${RESET}\n" "$id" "$name" "$status"
    done < "$mas_file"

    echo ""
    printf "  ${DIM}%-12s  %-35s  %s${RESET}\n" "$(printf '─%.0s' {1..12})" "$(printf '─%.0s' {1..35})" "$(printf '─%.0s' {1..12})"
    echo -e "  ${BOLD}Summary:${RESET} ${GREEN}$installed_count installed${RESET}, ${RED}$missing_count missing${RESET} (of $total_count total)"
    echo ""
}

cmd_homebrew_ls() {
    cmd_formulae_ls
    cmd_casks_ls
}

# ============================================================================
# Install commands (run actual installation)
# ============================================================================

cmd_homebrew_install() {
    print_banner

    if is_dry_run; then
        log_warn "DRY-RUN MODE - No changes will be made"
        echo ""
    fi

    # Load profile if specified
    if [[ -n "$PROFILE" ]]; then
        load_profile "$PROFILE"
    fi

    source "$SCRIPT_DIR/platforms/macos/homebrew.sh"
    setup_homebrew

    echo ""
    log_success "Homebrew setup complete"
}

cmd_formulae_install() {
    print_banner

    if is_dry_run; then
        log_warn "DRY-RUN MODE - No changes will be made"
        echo ""
    fi

    # Load profile if specified
    if [[ -n "$PROFILE" ]]; then
        load_profile "$PROFILE"
    fi

    source "$SCRIPT_DIR/platforms/macos/homebrew.sh"
    install_homebrew
    update_homebrew
    install_formulae
    cleanup_homebrew

    echo ""
    log_success "Formulae installation complete"
}

cmd_casks_install() {
    print_banner

    if is_dry_run; then
        log_warn "DRY-RUN MODE - No changes will be made"
        echo ""
    fi

    # Load profile if specified
    if [[ -n "$PROFILE" ]]; then
        load_profile "$PROFILE"
    fi

    source "$SCRIPT_DIR/platforms/macos/homebrew.sh"
    install_homebrew
    update_homebrew
    install_casks
    cleanup_homebrew

    echo ""
    log_success "Casks installation complete"
}

cmd_mas_install() {
    print_banner

    if is_dry_run; then
        log_warn "DRY-RUN MODE - No changes will be made"
        echo ""
    fi

    source "$SCRIPT_DIR/platforms/macos/homebrew.sh"
    install_homebrew
    install_mas_apps

    echo ""
    log_success "Mac App Store apps installation complete"
}

cmd_defaults_apply() {
    print_banner

    if is_dry_run; then
        log_warn "DRY-RUN MODE - No changes will be made"
        echo ""
    fi

    # Load profile if specified
    if [[ -n "$PROFILE" ]]; then
        load_profile "$PROFILE"
    fi

    source "$SCRIPT_DIR/platforms/macos/defaults.sh"
    setup_defaults

    echo ""
    log_success "System preferences applied"
}

# ============================================================================
# Argument parsing
# ============================================================================

# Load profile configuration
load_profile() {
    local profile_name="$1"
    local profile_file="$SCRIPT_DIR/config/profiles/${profile_name}.conf"

    if [[ ! -f "$profile_file" ]]; then
        log_error "Profile not found: $profile_name"
        log_info "Available profiles:"
        for conf in "$SCRIPT_DIR/config/profiles"/*.conf; do
            if [[ -f "$conf" ]]; then
                echo "  - $(basename "$conf" .conf)"
            fi
        done
        exit 1
    fi

    log_info "Loading profile: $profile_name"

    # Source the profile
    # shellcheck source=/dev/null
    source "$profile_file"

    # Export profile variables
    export PROFILE_NAME="$profile_name"
}

# Handle subcommands
handle_subcommand() {
    local cmd="${1:-}"
    local subcmd="${2:-}"

    case "$cmd" in
        dotfiles)
            case "$subcmd" in
                ls|list)
                    cmd_dotfiles_ls
                    ;;
                ""|install)
                    cmd_dotfiles_install
                    ;;
                *)
                    log_error "Unknown subcommand: dotfiles $subcmd"
                    log_info "Available: ls, install (default)"
                    exit 1
                    ;;
            esac
            exit 0
            ;;
        packages)
            # Linux package management
            if [[ "$(detect_os)" != "linux" ]]; then
                log_error "packages command is only available on Linux"
                log_info "On macOS, use: homebrew, formulae, casks, or mas"
                exit 1
            fi
            source "$SCRIPT_DIR/platforms/linux/packages.sh"
            case "$subcmd" in
                ls|list)
                    cmd_packages_ls
                    ;;
                ""|install)
                    cmd_packages_install
                    ;;
                *)
                    log_error "Unknown subcommand: packages $subcmd"
                    log_info "Available: ls, install (default)"
                    exit 1
                    ;;
            esac
            exit 0
            ;;
        homebrew|brew)
            case "$subcmd" in
                ls|list)
                    cmd_homebrew_ls
                    ;;
                ""|install)
                    cmd_homebrew_install
                    ;;
                *)
                    log_error "Unknown subcommand: homebrew $subcmd"
                    log_info "Available: ls, install (default)"
                    exit 1
                    ;;
            esac
            exit 0
            ;;
        formulae|formula)
            case "$subcmd" in
                ls|list)
                    cmd_formulae_ls
                    ;;
                ""|install)
                    cmd_formulae_install
                    ;;
                *)
                    log_error "Unknown subcommand: formulae $subcmd"
                    log_info "Available: ls, install (default)"
                    exit 1
                    ;;
            esac
            exit 0
            ;;
        casks|cask)
            case "$subcmd" in
                ls|list)
                    cmd_casks_ls
                    ;;
                ""|install)
                    cmd_casks_install
                    ;;
                *)
                    log_error "Unknown subcommand: casks $subcmd"
                    log_info "Available: ls, install (default)"
                    exit 1
                    ;;
            esac
            exit 0
            ;;
        mas)
            case "$subcmd" in
                ls|list)
                    cmd_mas_ls
                    ;;
                ""|install)
                    cmd_mas_install
                    ;;
                *)
                    log_error "Unknown subcommand: mas $subcmd"
                    log_info "Available: ls, install (default)"
                    exit 1
                    ;;
            esac
            exit 0
            ;;
        defaults)
            case "$subcmd" in
                ""|apply)
                    cmd_defaults_apply
                    ;;
                *)
                    log_error "Unknown subcommand: defaults $subcmd"
                    log_info "Available: apply (default)"
                    exit 1
                    ;;
            esac
            exit 0
            ;;
        claude-code)
            PROFILE_CLAUDE_CODE="true"
            install_claude_code
            exit 0
            ;;
        codex)
            PROFILE_CODEX="true"
            install_codex
            exit 0
            ;;
        shell-title)
            cmd_shell_title
            exit 0
            ;;
    esac

    # Not a recognized subcommand
    return 1
}

# Full setup logic
run_full_setup() {
    # Show banner
    print_banner

    # Detect OS
    local os
    os="$(detect_os)"
    print_system_info

    # Validate OS
    if [[ "$os" == "unknown" ]]; then
        log_error "Unsupported operating system"
        exit 1
    fi

    # Prompt for profile if not specified
    if [[ -z "$PROFILE" ]]; then
        select_profile "$os"
        PROFILE="$REPLY"
    fi

    # Load profile
    load_profile "$PROFILE"

    # Show dry-run notice
    if is_dry_run; then
        echo ""
        log_warn "DRY-RUN MODE - No changes will be made"
        echo ""
    fi

    # Show what will be done
    echo ""
    log_step "Setup configuration"
    echo "  Profile:      $PROFILE"

    # Check if any Homebrew packages are enabled
    local homebrew_enabled="false"
    for var in FORMULAE_CORE FORMULAE_SHELL FORMULAE_SOFTWARE_DEV FORMULAE_DEVOPS FORMULAE_MEDIA \
               CASKS_PRODUCTIVITY CASKS_DEVELOPMENT CASKS_UTILITIES CASKS_POWER_USER CASKS_BROWSERS CASKS_CREATIVE CASKS_MEDIA; do
        if [[ "${!var:-false}" == "true" ]]; then
            homebrew_enabled="true"
            break
        fi
    done

    if [[ "$os" == "macos" ]]; then
        echo "  Homebrew:     $(if [[ "$homebrew_enabled" == "true" ]]; then echo "install"; else echo "skip (profile)"; fi)"
        echo "  Claude Code:  $(if [[ "${PROFILE_CLAUDE_CODE:-false}" == "true" ]]; then echo "install"; else echo "skip (profile)"; fi)"
        echo "  Dotfiles:     $(if [[ "${PROFILE_DOTFILES:-true}" == "false" ]]; then echo "skip (profile)"; else echo "install"; fi)"
        echo "  Defaults:     $(if [[ "${PROFILE_APPLY_DEFAULTS:-true}" == "false" ]]; then echo "skip (profile)"; else echo "apply"; fi)"
        echo "  MAS Apps:     $(if [[ "${PROFILE_MAS:-true}" == "false" ]]; then echo "skip (profile)"; else echo "install"; fi)"
    elif [[ "$os" == "linux" ]]; then
        echo "  Claude Code:  $(if [[ "${PROFILE_CLAUDE_CODE:-false}" == "true" ]]; then echo "install"; else echo "skip (profile)"; fi)"
        echo "  Dotfiles:     $(if [[ "${PROFILE_DOTFILES:-true}" == "false" ]]; then echo "skip (profile)"; else echo "install"; fi)"
    fi
    echo ""

    # Confirm before proceeding
    if ! is_dry_run && [[ "$FORCE" != "true" ]]; then
        if ! yes_no "Proceed with setup?"; then
            log_info "Setup cancelled"
            exit 0
        fi
    fi

    # Dispatch to OS-specific setup
    case "$os" in
        macos)
            if [[ -f "$SCRIPT_DIR/platforms/macos/setup.sh" ]]; then
                # Set variables for full setup (no skipping)
                export SKIP_HOMEBREW="false"
                export SKIP_DOTFILES="false"
                export SKIP_DEFAULTS="false"
                export SKIP_MAS="false"

                source "$SCRIPT_DIR/platforms/macos/setup.sh"
                macos_setup
            else
                log_error "macOS setup script not found"
                exit 1
            fi
            ;;
        linux)
            if [[ -f "$SCRIPT_DIR/platforms/linux/setup.sh" ]]; then
                source "$SCRIPT_DIR/platforms/linux/setup.sh"
                linux_setup
            else
                log_warn "Linux setup not yet implemented"
                exit 1
            fi
            ;;
        windows)
            log_warn "Windows setup not yet implemented"
            log_info "Please run setup.ps1 in PowerShell instead"
            exit 1
            ;;
    esac

    # Done
    echo ""
    print_header "Setup Complete"
    log_success "Workstation setup finished successfully!"

    if is_dry_run; then
        echo ""
        log_info "This was a dry run. Run without --dry-run to apply changes."
    else
        echo ""
        log_info "You may need to restart your terminal or log out/in for all changes to take effect."
    fi
}

# Check that script is not run as root
check_not_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "Do not run this script as root/sudo"
        log_error "Homebrew requires non-root execution"
        log_info "Run: ./setup.sh (without sudo)"
        exit 1
    fi
}

# Main entry point
main() {
    # Prevent running as root (Homebrew requirement)
    check_not_root

    local args=()
    local cmd=""
    local subcmd=""

    # First pass: extract options and collect non-option args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile)
                PROFILE="$2"
                shift 2
                ;;
            --profile=*)
                PROFILE="${1#*=}"
                shift
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            --force|-f)
                FORCE="true"
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    # Export options
    export DRY_RUN FORCE

    # Load profile if specified (needed for subcommands)
    if [[ -n "${PROFILE:-}" ]]; then
        load_profile "$PROFILE"
    fi

    # Check for subcommands
    if [[ ${#args[@]} -gt 0 ]]; then
        cmd="${args[0]}"
        subcmd="${args[1]:-}"

        # Try to handle as subcommand
        if handle_subcommand "$cmd" "$subcmd"; then
            exit 0
        fi

        # If we get here, it wasn't a valid subcommand
        log_error "Unknown command: $cmd"
        show_help
        exit 1
    fi

    # No subcommand - run full setup
    run_full_setup
}

# Run main
main "$@"
