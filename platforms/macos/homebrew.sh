#!/usr/bin/env bash
# platforms/macos/homebrew.sh - Homebrew installation and package management

# Homebrew installation URL
HOMEBREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

# Setup Homebrew
setup_homebrew() {
    print_header "Homebrew Setup"

    # Install Homebrew if not present
    install_homebrew

    # Update Homebrew
    update_homebrew

    # Install packages
    install_formulae
    install_casks

    # Install MAS apps if enabled
    if [[ "$SKIP_MAS" != "true" ]] && [[ "${PROFILE_MAS:-true}" == "true" ]]; then
        install_mas_apps
    else
        log_info "Skipping Mac App Store apps"
    fi

    # Cleanup
    cleanup_homebrew
}

# Install Homebrew
install_homebrew() {
    log_step "Checking Homebrew installation"

    if command_exists brew; then
        log_success "Homebrew already installed"
        eval_brew_shellenv
        return 0
    fi

    log_info "Installing Homebrew..."

    if is_dry_run; then
        log_dry "curl -fsSL $HOMEBREW_INSTALL_URL | bash"
        return 0
    fi

    # Install Homebrew (non-interactive)
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL $HOMEBREW_INSTALL_URL)"

    eval_brew_shellenv
    log_success "Homebrew installed"
}

# Evaluate brew shellenv for PATH setup
eval_brew_shellenv() {
    if is_apple_silicon; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    else
        eval "$(/usr/local/bin/brew shellenv)"
    fi
}

# Update Homebrew
update_homebrew() {
    log_step "Updating Homebrew"

    if is_dry_run; then
        log_dry "brew update"
        return 0
    fi

    brew update
    log_success "Homebrew updated"
}

# Install Homebrew packages (generic helper)
# Usage: install_brew_packages packages_dir category_prefix [--cask]
install_brew_packages() {
    local packages_dir="$1"
    local category_prefix="$2"
    local is_cask="${3:-}"
    local packages=()

    # Collect all enabled packages
    for file in "$packages_dir"/*.txt; do
        [[ -f "$file" ]] || continue

        local category
        category="$(basename "$file" .txt)"
        local category_var
        category_var="$(get_category_var "$category_prefix" "$category")"

        # Check if category is enabled (default to true if not set)
        if [[ "${!category_var:-true}" == "true" ]]; then
            log_substep "Including category: $category"
            while IFS= read -r package; do
                packages+=("$package")
            done < <(parse_package_list "$file")
        else
            log_substep "Skipping category: $category"
        fi
    done

    if [[ ${#packages[@]} -eq 0 ]]; then
        log_warn "No packages to install"
        return 0
    fi

    log_info "Installing ${#packages[@]} packages..."

    local install_cmd="brew install"
    local list_cmd="brew list --formula"
    if [[ "$is_cask" == "--cask" ]]; then
        install_cmd="brew install --cask"
        list_cmd="brew list --cask"
    fi

    if is_dry_run; then
        for pkg in "${packages[@]}"; do
            log_dry "$install_cmd $pkg"
        done
        return 0
    fi

    # Install packages (continue on error)
    for pkg in "${packages[@]}"; do
        if $list_cmd "$pkg" &>/dev/null; then
            log_substep "Already installed: $pkg"
        else
            log_substep "Installing: $pkg"
            $install_cmd "$pkg" || log_warn "Failed to install: $pkg"
        fi
    done
}

# Install Homebrew formulae
install_formulae() {
    log_step "Installing Homebrew formulae"
    install_brew_packages "$SCRIPT_DIR/config/packages/macos/formulae" "FORMULAE"
    log_success "Formulae installation complete"
}

# Install Homebrew casks
install_casks() {
    log_step "Installing Homebrew casks"
    install_brew_packages "$SCRIPT_DIR/config/packages/macos/casks" "CASKS" "--cask"
    log_success "Cask installation complete"
}

# Install Mac App Store apps
install_mas_apps() {
    log_step "Installing Mac App Store apps"

    # Install mas CLI if not present
    if ! command_exists mas; then
        log_info "Installing mas CLI..."
        if is_dry_run; then
            log_dry "brew install mas"
        else
            brew install mas
        fi
    fi

    local mas_file="$SCRIPT_DIR/config/packages/macos/mas/apps.txt"

    if [[ ! -f "$mas_file" ]]; then
        log_warn "MAS apps file not found: $mas_file"
        return 0
    fi

    # Note: mas account is deprecated in macOS 12+, so we skip the sign-in check
    # and rely on mas install failing gracefully if not signed in

    # Suppress Spotlight indexing warnings from mas
    export MAS_NO_AUTO_INDEX=1

    # Install apps
    while IFS=$'\t' read -r id name; do
        [[ -z "$id" ]] && continue

        if is_dry_run; then
            log_dry "mas install $id  # $name"
        else
            local mas_output
            if mas_output=$(mas install "$id" 2>&1); then
                if echo "$mas_output" | grep -q "already installed"; then
                    log_substep "Already installed: $name"
                else
                    log_substep "Installed: $name"
                fi
            else
                log_warn "Failed to install: $name"
            fi
        fi
    done < <(parse_mas_list "$mas_file")

    log_success "MAS app installation complete"
}

# Cleanup Homebrew
cleanup_homebrew() {
    log_step "Cleaning up Homebrew"

    if is_dry_run; then
        log_dry "brew cleanup"
        return 0
    fi

    brew cleanup
    log_success "Homebrew cleanup complete"
}

# ============================================================================
# Package status listing (used by `setup.sh homebrew ls` etc.)
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
