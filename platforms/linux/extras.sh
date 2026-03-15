#!/usr/bin/env bash
# platforms/linux/extras.sh - Install tools not available in standard apt repos
#
# These tools match the macOS shell.txt but require special installation on Linux:
# - starship: Cross-shell prompt
# - eza: Modern ls replacement
# - git-delta: Better git diff viewer
# - zoxide: Smarter cd command

# Install all extra tools
setup_extras() {
    print_header "Extra Tools Installation"

    if [[ "${PROFILE_EXTRAS:-false}" != "true" ]]; then
        log_info "Skipping extras (disabled in profile)"
        return 0
    fi

    require_supported_linux_apt || return 1

    install_starship
    install_eza
    install_delta
    install_zoxide
    set_default_shell_zsh

    log_success "Extra tools installation complete"
}

# Install Starship prompt
install_starship() {
    log_step "Installing Starship"

    if command_exists starship; then
        log_info "Starship already installed: $(starship --version | head -1)"
        return 0
    fi

    if is_dry_run; then
        log_dry "curl -sS https://starship.rs/install.sh | sh -s -- -y"
        return 0
    fi

    curl -sS https://starship.rs/install.sh | sh -s -- -y

    if command_exists starship; then
        log_success "Starship installed: $(starship --version | head -1)"
    else
        log_error "Starship installation failed"
    fi
}

# Install eza (modern ls replacement)
install_eza() {
    log_step "Installing eza"

    if command_exists eza; then
        log_info "eza already installed: $(eza --version | head -1)"
        return 0
    fi

    if is_dry_run; then
        log_dry "Add eza community repository"
        log_dry "apt-get install eza"
        return 0
    fi

    # eza is available via the eza community repository
    # https://github.com/eza-community/eza/blob/main/INSTALL.md

    # Install prerequisites
    sudo apt-get install -y gpg

    # Create keyrings directory if needed
    sudo mkdir -p /etc/apt/keyrings

    # Download and install GPG key
    wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc | sudo gpg --dearmor -o /etc/apt/keyrings/gierens.gpg

    # Add repository
    echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" | sudo tee /etc/apt/sources.list.d/gierens.list

    # Set permissions
    sudo chmod 644 /etc/apt/keyrings/gierens.gpg /etc/apt/sources.list.d/gierens.list

    # Update and install
    sudo apt-get update
    sudo apt-get install -y eza

    if command_exists eza; then
        log_success "eza installed: $(eza --version | head -1)"
    else
        log_error "eza installation failed"
    fi
}

# Install git-delta (better diff viewer)
install_delta() {
    log_step "Installing git-delta"

    if command_exists delta; then
        log_info "git-delta already installed: $(delta --version)"
        return 0
    fi

    if is_dry_run; then
        log_dry "Download git-delta .deb from GitHub releases"
        log_dry "dpkg -i git-delta_<version>_amd64.deb"
        return 0
    fi

    # Get latest release version from GitHub API
    local version
    version=$(curl -sS https://api.github.com/repos/dandavison/delta/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')

    if [[ -z "$version" ]]; then
        log_error "Failed to get git-delta version from GitHub"
        return 1
    fi

    # Detect architecture
    local arch
    case "$(uname -m)" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *)
            log_error "Unsupported architecture for git-delta: $(uname -m)"
            return 1
            ;;
    esac

    local deb_file="git-delta_${version}_${arch}.deb"
    local download_url="https://github.com/dandavison/delta/releases/download/${version}/${deb_file}"
    local tmp_file="/tmp/${deb_file}"

    log_substep "Downloading git-delta ${version}..."
    if ! curl -fsSL -o "$tmp_file" "$download_url"; then
        log_error "Failed to download git-delta from $download_url"
        return 1
    fi

    log_substep "Installing git-delta..."
    sudo dpkg -i "$tmp_file"
    rm -f "$tmp_file"

    if command_exists delta; then
        log_success "git-delta installed: $(delta --version)"
    else
        log_error "git-delta installation failed"
    fi
}

# Install zoxide (smarter cd)
install_zoxide() {
    log_step "Installing zoxide"

    if command_exists zoxide; then
        log_info "zoxide already installed: $(zoxide --version)"
        return 0
    fi

    if is_dry_run; then
        log_dry "curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh"
        return 0
    fi

    curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh

    if command_exists zoxide; then
        log_success "zoxide installed: $(zoxide --version)"
    else
        # zoxide installs to ~/.local/bin, which might not be in PATH yet
        if [[ -x "$HOME/.local/bin/zoxide" ]]; then
            log_success "zoxide installed to ~/.local/bin (will be in PATH after shell restart)"
        else
            log_error "zoxide installation failed"
        fi
    fi
}

# Set zsh as the default login shell
set_default_shell_zsh() {
    log_step "Setting zsh as default shell"

    local zsh_path
    zsh_path="$(command -v zsh 2>/dev/null)"

    if [[ -z "$zsh_path" ]]; then
        log_warn "zsh not found, skipping default shell change"
        return 0
    fi

    # Check if already using zsh
    local current_shell
    current_shell="$(getent passwd "$USER" | cut -d: -f7)"

    if [[ "$current_shell" == "$zsh_path" ]]; then
        log_info "zsh is already the default shell"
        return 0
    fi

    if is_dry_run; then
        log_dry "chsh -s $zsh_path"
        return 0
    fi

    # Use sudo to avoid password prompt
    if sudo chsh -s "$zsh_path" "$USER"; then
        log_success "Default shell changed to zsh (takes effect on next login)"
    else
        log_error "Failed to change default shell"
    fi
}
