#!/usr/bin/env bash
# platforms/linux/packages.sh - Linux package management (Debian/Ubuntu via apt)

# Debian/Ubuntu are the only supported Linux distributions for package installs.
require_supported_linux_apt() {
    local distro
    distro="$(get_linux_distro)"

    case "$distro" in
        ubuntu|debian)
            ;;
        *)
            log_error "Linux support is currently limited to Debian/Ubuntu. Detected: ${distro:-unknown}"
            return 1
            ;;
    esac

    if ! command_exists apt-get; then
        log_error "apt-get is required on supported Linux systems"
        return 1
    fi
}

enabled_linux_package_files() {
    local packages_dir="$1"

    for category_file in "$packages_dir"/*.txt; do
        [[ -f "$category_file" ]] || continue

        local category
        category="$(basename "$category_file" .txt)"

        local var_name
        var_name="$(get_category_var PACKAGES "$category")"

        if [[ "${!var_name:-true}" != "true" ]]; then
            log_substep "Skipping $category (disabled in profile)"
            continue
        fi

        echo "$category_file"
    done
}

# Setup packages
setup_packages() {
    print_header "Package Installation"

    require_supported_linux_apt || return 1

    log_info "Package manager: apt"

    # Update package lists
    update_packages

    # Install packages
    install_packages

    log_success "Package installation complete"
}

# Update package lists
update_packages() {
    log_step "Updating package lists"

    if is_dry_run; then
        log_dry "sudo apt-get update -qq"
        return 0
    fi

    sudo apt-get update -qq

    log_success "Package lists updated"
}

# Install packages from category files
install_packages() {
    local packages_dir="$SCRIPT_DIR/config/packages/linux/apt"

    if [[ ! -d "$packages_dir" ]]; then
        log_warn "No package lists found in $packages_dir"
        return 0
    fi

    log_step "Installing packages"

    # Collect all packages to install
    local packages=()

    local category_file
    while IFS= read -r category_file; do
        [[ -n "$category_file" ]] || continue

        local category
        category="$(basename "$category_file" .txt)"

        log_substep "Reading $category packages"

        while IFS= read -r pkg; do
            packages+=("$pkg")
        done < <(parse_package_list "$category_file")
    done < <(enabled_linux_package_files "$packages_dir")

    if [[ ${#packages[@]} -eq 0 ]]; then
        log_info "No packages to install"
        return 0
    fi

    log_info "Installing ${#packages[@]} packages..."

    if is_dry_run; then
        for pkg in "${packages[@]}"; do
            log_dry "install $pkg"
        done
        return 0
    fi

    local installed=0
    local skipped=0
    local failed=0
    local pkg

    for pkg in "${packages[@]}"; do
        if is_package_installed "$pkg"; then
            log_substep "Already installed: $pkg"
            ((skipped++))
            continue
        fi

        log_substep "Installing: $pkg"
        if sudo apt-get install -y "$pkg"; then
            ((installed++))
        else
            log_warn "Failed to install: $pkg"
            ((failed++))
        fi
    done

    echo ""
    echo -e "  ${GREEN}$installed installed${RESET}"
    if [[ $skipped -gt 0 ]]; then
        echo -e "  ${DIM}$skipped already installed${RESET}"
    fi
    if [[ $failed -gt 0 ]]; then
        echo -e "  ${RED}$failed failed${RESET}"
    fi
}

# Check package status
check_packages() {
    require_supported_linux_apt || return 1

    local packages_dir="$SCRIPT_DIR/config/packages/linux/apt"

    if [[ ! -d "$packages_dir" ]]; then
        log_warn "No package lists found in $packages_dir"
        return 0
    fi

    local installed=0
    local missing=0

    local category_file
    while IFS= read -r category_file; do
        [[ -n "$category_file" ]] || continue

        local pkg
        while IFS= read -r pkg; do
            [[ -n "$pkg" ]] || continue

            if is_package_installed "$pkg"; then
                echo -e "  ${GREEN}✓${RESET} $pkg"
                ((installed++))
            else
                echo -e "  ${RED}✗${RESET} $pkg"
                ((missing++))
            fi
        done < <(parse_package_list "$category_file")
    done < <(enabled_linux_package_files "$packages_dir")

    echo ""
    echo -e "  ${GREEN}$installed installed${RESET}"
    if [[ $missing -gt 0 ]]; then
        echo -e "  ${RED}$missing missing${RESET}"
    fi
}

# Check if a package is installed
is_package_installed() {
    dpkg -l "$1" 2>/dev/null | grep -q "^ii"
}
