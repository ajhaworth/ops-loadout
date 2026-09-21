#!/usr/bin/env bash
# common.sh - Colors, logging, and utility functions

# Colors (only if terminal supports them)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    MAGENTA=''
    CYAN=''
    BOLD=''
    DIM=''
    RESET=''
fi

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${RESET} $*"
}

log_success() {
    echo -e "${GREEN}[OK]${RESET} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${RESET} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${RESET} $*" >&2
}

log_step() {
    echo -e "${BOLD}${CYAN}==>${RESET} ${BOLD}$*${RESET}"
}

log_substep() {
    echo -e "  ${CYAN}->${RESET} $*"
}

log_dry() {
    echo -e "${MAGENTA}[DRY-RUN]${RESET} $*"
}

# Check if running in dry-run mode
is_dry_run() {
    [[ "${DRY_RUN:-false}" == "true" ]]
}

# Execute command or print if dry-run
run_cmd() {
    if is_dry_run; then
        log_dry "$*"
        return 0
    else
        "$@"
    fi
}

# Check if a command exists
command_exists() {
    command -v "$1" &>/dev/null
}

# Convert category name to profile variable name
# Usage: get_category_var "FORMULAE" "software-dev" -> "FORMULAE_SOFTWARE_DEV"
get_category_var() {
    local prefix="$1"
    local category="$2"
    echo "${prefix}_$(echo "$category" | tr '[:lower:]-' '[:upper:]_')"
}

# Print a section header
print_header() {
    local title="$1"
    local width=60
    local padding=$(( (width - ${#title} - 2) / 2 ))

    echo ""
    echo -e "${BOLD}${BLUE}$(printf '=%.0s' $(seq 1 $width))${RESET}"
    echo -e "${BOLD}${BLUE}$(printf ' %.0s' $(seq 1 $padding)) $title${RESET}"
    echo -e "${BOLD}${BLUE}$(printf '=%.0s' $(seq 1 $width))${RESET}"
    echo ""
}

# Print script banner
print_banner() {
    # Extended colors for gradient effect
    local C1 C2 C3 C4 C5 C6
    if [[ -t 1 ]]; then
        C1='\033[38;5;198m'  # Hot pink
        C2='\033[38;5;199m'  # Pink
        C3='\033[38;5;165m'  # Magenta
        C4='\033[38;5;129m'  # Purple
        C5='\033[38;5;93m'   # Blue-purple
        C6='\033[38;5;63m'   # Blue
    else
        C1='' C2='' C3='' C4='' C5='' C6=''
    fi

    echo ""
    echo -e "${BOLD}${C1}   ██████╗ ███████╗██╗   ██╗██████╗  ██████╗ ██╗  ██╗${RESET}"
    echo -e "${BOLD}${C2}   ██╔══██╗██╔════╝██║   ██║██╔══██╗██╔═══██╗╚██╗██╔╝${RESET}"
    echo -e "${BOLD}${C3}   ██║  ██║█████╗  ██║   ██║██████╔╝██║   ██║ ╚███╔╝ ${RESET}"
    echo -e "${BOLD}${C4}   ██║  ██║██╔══╝  ╚██╗ ██╔╝██╔══██╗██║   ██║ ██╔██╗ ${RESET}"
    echo -e "${BOLD}${C5}   ██████╔╝███████╗ ╚████╔╝ ██████╔╝╚██████╔╝██╔╝ ██╗${RESET}"
    echo -e "${BOLD}${C6}   ╚═════╝ ╚══════╝  ╚═══╝  ╚═════╝  ╚═════╝ ╚═╝  ╚═╝${RESET}"
    echo ""
    echo -e "   ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "   ${C3}${BOLD}Cross-platform workstation setup${RESET}"
    echo ""
}

# Get the repository root directory
get_repo_root() {
    cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

