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
#   plugins             Deploy Claude Code plugin configs
#   plugins save        Save current plugin state back to repo
#   plugins ls          List installed plugins and status
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
PROFILE_LOADED="false"

# Export for subshells and sourced scripts
export DRY_RUN FORCE PROFILE_LOADED

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
    plugins             Deploy Claude Code plugin configs
    plugins save        Save current plugin state back to repo
    plugins ls          List installed plugins and status
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

    if [[ "${PROFILE_LOADED:-false}" == "true" ]] && [[ "${PROFILE_NAME:-}" == "$profile_name" ]]; then
        validate_profile_platform
        return 0
    fi

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
    export PROFILE_LOADED="true"

    validate_profile_platform
}

validate_profile_platform() {
    local current_os profile_os
    current_os="$(detect_os)"
    profile_os="${PROFILE_OS:-}"

    if [[ -n "$profile_os" ]] && [[ "$profile_os" != "$current_os" ]]; then
        log_error "Profile '$PROFILE_NAME' targets $profile_os, but the current OS is $current_os"
        exit 1
    fi
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
                    source "$SCRIPT_DIR/platforms/macos/homebrew.sh"
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
                    source "$SCRIPT_DIR/platforms/macos/homebrew.sh"
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
                    source "$SCRIPT_DIR/platforms/macos/homebrew.sh"
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
                    source "$SCRIPT_DIR/platforms/macos/homebrew.sh"
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
        plugins)
            case "$subcmd" in
                save)
                    save_claude_plugins
                    ;;
                ls|list)
                    cmd_plugins_ls
                    ;;
                ""|install)
                    setup_claude_plugins
                    ;;
                *)
                    log_error "Unknown subcommand: plugins $subcmd"
                    log_info "Available: ls, save, install (default)"
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

    if [[ "${PROFILE_NAME:-}" != "$PROFILE" ]]; then
        load_profile "$PROFILE"
    else
        validate_profile_platform
    fi

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
    export DRY_RUN FORCE PROFILE_LOADED

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
