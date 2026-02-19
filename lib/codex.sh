#!/usr/bin/env bash
# lib/codex.sh - OpenAI Codex CLI installation
#
# Installs the OpenAI Codex CLI via npm global install.
# Works on both macOS and Linux. Requires Node.js to be installed.

install_codex() {
    log_step "Installing OpenAI Codex CLI"

    if [[ "${PROFILE_CODEX:-false}" != "true" ]]; then
        log_info "Skipping Codex CLI (disabled in profile)"
        return 0
    fi

    if ! command_exists npm; then
        log_warn "npm not found; skipping Codex CLI installation"
        return 0
    fi

    if command_exists codex; then
        log_info "Codex CLI already installed: $(codex --version 2>/dev/null || echo 'unknown')"
        return 0
    fi

    local npm_prefix
    npm_prefix="$(npm prefix -g 2>/dev/null)"

    if is_dry_run; then
        if [[ -w "$npm_prefix" ]]; then
            log_dry "npm install -g @openai/codex"
        else
            log_dry "sudo npm install -g @openai/codex"
        fi
        return 0
    fi

    if [[ -w "$npm_prefix" ]]; then
        npm install -g @openai/codex
    else
        sudo npm install -g @openai/codex
    fi

    if command_exists codex; then
        log_success "Codex CLI installed: $(codex --version 2>/dev/null || echo 'installed')"
    else
        log_error "Codex CLI installation failed"
    fi
}
