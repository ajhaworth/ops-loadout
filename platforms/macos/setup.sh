#!/usr/bin/env bash
# platforms/macos/setup.sh - macOS orchestrator
#
# This script coordinates the macOS setup process.
# It is sourced by the main setup.sh script.

# Ensure we're running on macOS
if [[ "$(detect_os)" != "macos" ]]; then
    log_error "This script is for macOS only"
    exit 1
fi

# Source macOS-specific scripts
MACOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Main macOS setup function
macos_setup() {
    print_header "macOS Setup"

    # Check macOS version
    local macos_version
    macos_version="$(get_macos_major_version)"
    if [[ "$macos_version" -lt 12 ]]; then
        log_warn "This script is designed for macOS 12 (Monterey) or later"
        log_warn "You are running macOS $(get_macos_version)"
        if ! yes_no "Continue anyway?"; then
            exit 1
        fi
    fi

    # Ensure Xcode Command Line Tools are installed
    ensure_xcode_clt

    # 1. Homebrew installation and packages
    if [[ "$SKIP_HOMEBREW" != "true" ]]; then
        source "$MACOS_DIR/homebrew.sh"
        setup_homebrew
    else
        log_info "Skipping Homebrew setup"
    fi

    # 2. Claude Code
    install_claude_code

    # 3. OpenAI Codex CLI
    install_codex

    # 4. Dotfiles symlinking
    if [[ "$SKIP_DOTFILES" != "true" ]] && [[ "${PROFILE_DOTFILES:-true}" == "true" ]]; then
        source "$MACOS_DIR/dotfiles.sh"
        setup_dotfiles
    else
        log_info "Skipping dotfiles setup"
    fi

    # 5. System preferences
    if [[ "$SKIP_DEFAULTS" != "true" ]] && [[ "${PROFILE_APPLY_DEFAULTS:-true}" == "true" ]]; then
        source "$MACOS_DIR/defaults.sh"
        setup_defaults
    else
        log_info "Skipping system preferences"
    fi

    log_success "macOS setup complete"
}

# Ensure Xcode Command Line Tools are installed
ensure_xcode_clt() {
    log_step "Checking Xcode Command Line Tools"

    if xcode-select -p &>/dev/null; then
        log_success "Xcode Command Line Tools already installed"
        return 0
    fi

    log_info "Installing Xcode Command Line Tools..."

    if is_dry_run; then
        log_dry "xcode-select --install"
        return 0
    fi

    # Trigger the install prompt
    xcode-select --install &>/dev/null || true

    # Wait for installation
    log_info "Please complete the Xcode Command Line Tools installation in the popup"
    log_info "Waiting for installation to complete..."

    until xcode-select -p &>/dev/null; do
        sleep 5
    done

    log_success "Xcode Command Line Tools installed"
}
