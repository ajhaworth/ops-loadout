#!/usr/bin/env bash
# linux/setup.sh - Linux setup
#
# This script coordinates Linux setup including dotfiles and package management.

linux_setup() {
    print_header "Linux Setup"

    # Source Linux-specific modules
    source "$SCRIPT_DIR/platforms/linux/dotfiles.sh"
    source "$SCRIPT_DIR/platforms/linux/packages.sh"
    source "$SCRIPT_DIR/platforms/linux/repositories.sh"
    source "$SCRIPT_DIR/platforms/linux/extras.sh"

    # 1. External repositories (NodeSource for Node.js)
    setup_repositories

    # 2. Go installation (from tarball)
    install_go

    # 3. Packages (apt packages)
    if [[ "${PROFILE_PACKAGES:-false}" == "true" ]]; then
        setup_packages
    else
        log_info "Skipping packages (disabled in profile)"
    fi

    # 4. Extra tools (starship, eza, delta, zoxide)
    setup_extras

    # 5. Claude Code
    install_claude_code

    # 6. OpenAI Codex CLI
    install_codex

    # 7. Dotfiles
    if [[ "${PROFILE_DOTFILES:-true}" == "true" ]]; then
        setup_dotfiles
    else
        log_info "Skipping dotfiles (disabled in profile)"
    fi

    log_success "Linux setup complete"
}
