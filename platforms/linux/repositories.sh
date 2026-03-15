#!/usr/bin/env bash
# platforms/linux/repositories.sh - External repository setup for Linux
#
# Handles setting up external package repositories and installing
# software that requires special installation procedures.

# Setup all external repositories
setup_repositories() {
    print_header "External Repositories"

    if [[ "${PROFILE_REPOSITORIES:-false}" != "true" ]]; then
        log_info "Skipping repositories (disabled in profile)"
        return 0
    fi

    require_supported_linux_apt || return 1

    setup_nodejs_repo

    log_success "Repository setup complete"
}

# Setup NodeSource repository for Node.js 22
setup_nodejs_repo() {
    log_step "Setting up NodeSource repository for Node.js 22"

    if is_dry_run; then
        log_dry "curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -"
        return 0
    fi

    # Check if NodeSource is already configured
    if [[ -f /etc/apt/sources.list.d/nodesource.list ]]; then
        log_info "NodeSource repository already configured"
        return 0
    fi

    # Download and run NodeSource setup script
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -

    log_success "NodeSource repository configured"
}

# Install Go from official tarball
install_go() {
    print_header "Go Installation"

    if [[ "${PROFILE_GO:-false}" != "true" ]]; then
        log_info "Skipping Go installation (disabled in profile)"
        return 0
    fi

    log_step "Installing Go"

    # Target Go version
    local go_version="1.24.0"
    local go_install_dir="/usr/local/go"

    # Check if Go is already installed at the correct version
    if [[ -x "$go_install_dir/bin/go" ]]; then
        local installed_version
        installed_version=$("$go_install_dir/bin/go" version 2>/dev/null | awk '{print $3}' | sed 's/go//')
        if [[ "$installed_version" == "$go_version" ]]; then
            log_info "Go $go_version already installed"
            return 0
        else
            log_info "Go $installed_version installed, upgrading to $go_version"
        fi
    fi

    # Detect architecture
    local arch
    case "$(uname -m)" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv6l" ;;
        *)
            log_error "Unsupported architecture: $(uname -m)"
            return 1
            ;;
    esac

    if is_dry_run; then
        log_dry "Download go${go_version}.linux-${arch}.tar.gz"
        log_dry "sudo rm -rf $go_install_dir"
        log_dry "sudo tar -C /usr/local -xzf go${go_version}.linux-${arch}.tar.gz"
        return 0
    fi

    local go_tarball="go${go_version}.linux-${arch}.tar.gz"
    local go_url="https://go.dev/dl/${go_tarball}"
    local tmp_file="/tmp/${go_tarball}"

    # Download Go tarball
    log_substep "Downloading Go ${go_version} for ${arch}..."
    if ! curl -fsSL -o "$tmp_file" "$go_url"; then
        log_error "Failed to download Go from $go_url"
        return 1
    fi

    # Remove existing Go installation
    if [[ -d "$go_install_dir" ]]; then
        log_substep "Removing existing Go installation..."
        sudo rm -rf "$go_install_dir"
    fi

    # Extract to /usr/local
    log_substep "Extracting Go to /usr/local..."
    sudo tar -C /usr/local -xzf "$tmp_file"

    # Clean up
    rm -f "$tmp_file"

    # Verify installation
    if [[ -x "$go_install_dir/bin/go" ]]; then
        local version
        version=$("$go_install_dir/bin/go" version)
        log_success "Go installed: $version"
    else
        log_error "Go installation failed"
        return 1
    fi
}
