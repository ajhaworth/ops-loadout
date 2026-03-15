#!/usr/bin/env bash
# symlink.sh - Symlink utilities for dotfiles management

# Default backup directory
BACKUP_DIR="${BACKUP_DIR:-$HOME/.dotfiles_backup/$(date +%Y%m%d_%H%M%S)}"

# Shorten a path for display (replace $HOME with ~)
shorten_path() {
    local path="$1"
    echo "${path/#$HOME/~}"
}

normalize_path() {
    local path="$1"

    if [[ -d "$path" ]]; then
        (cd "$path" 2>/dev/null && pwd -P) || echo "$path"
        return
    fi

    local dir base
    dir="$(dirname "$path")"
    base="$(basename "$path")"

    if [[ -d "$dir" ]]; then
        (cd "$dir" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$base") || echo "$path"
    else
        echo "$path"
    fi
}

resolve_symlink_target() {
    local link_path="$1"
    local target
    target="$(readlink "$link_path")"

    if [[ "$target" != /* ]]; then
        target="$(dirname "$link_path")/$target"
    fi

    normalize_path "$target"
}

# Create a symlink with backup
# Usage: create_symlink source destination
create_symlink() {
    local source="$1"
    local destination="$2"

    # Expand ~ in paths
    source="${source/#\~/$HOME}"
    destination="${destination/#\~/$HOME}"

    # Check if source exists
    if [[ ! -e "$source" ]]; then
        log_error "Source does not exist: $source"
        return 1
    fi

    # Get absolute path of source
    source="$(normalize_path "$source")"

    # Prepare shortened path for display
    local short_dest
    short_dest="$(shorten_path "$destination")"

    # Create parent directory if needed
    local dest_dir
    dest_dir="$(dirname "$destination")"
    if [[ ! -d "$dest_dir" ]]; then
        log_substep "Creating directory: $(shorten_path "$dest_dir")"
        if ! is_dry_run; then
            mkdir -p "$dest_dir"
        fi
    fi

    # Handle existing file/symlink at destination
    local backed_up=false
    if [[ -e "$destination" ]] || [[ -L "$destination" ]]; then
        # Check if already correctly linked
        if [[ -L "$destination" ]]; then
            local current_target
            current_target="$(resolve_symlink_target "$destination")"
            if [[ "$current_target" == "$source" ]]; then
                echo -e "  ${GREEN}✓${RESET} ${short_dest}"
                return 0
            fi
        fi

        # Backup existing file
        if backup_file "$destination" "$source"; then
            backed_up=true
        fi
    fi

    # Create the symlink
    if ! is_dry_run; then
        ln -sf "$source" "$destination"
    fi

    # Display result
    if $backed_up; then
        echo -e "  ${CYAN}↻${RESET} ${short_dest} ${DIM}(backed up)${RESET}"
    else
        echo -e "  ${CYAN}+${RESET} ${short_dest}"
    fi
}

# Backup a file before replacing
# Usage: backup_file filepath managed_source
# Returns: 0 if backed up, 1 if was old symlink (removed)
backup_file() {
    local filepath="$1"
    local managed_source="$2"
    local repo_root
    repo_root="$(normalize_path "$(get_repo_root)")"

    # Don't backup if it's already a symlink to our dotfiles
    if [[ -L "$filepath" ]]; then
        local target
        target="$(resolve_symlink_target "$filepath")"
        if [[ "$target" == "$managed_source" ]]; then
            if ! is_dry_run; then
                rm "$filepath"
            fi
            return 1
        fi

        if [[ "$target" == "$repo_root"/* ]]; then
            if ! is_dry_run; then
                rm "$filepath"
            fi
            return 1  # Signal that this was just an old symlink removal
        fi
    fi

    # Create backup directory
    if [[ ! -d "$BACKUP_DIR" ]] && ! is_dry_run; then
        mkdir -p "$BACKUP_DIR"
        log_info "Backups saved to: $(shorten_path "$BACKUP_DIR")"
    fi

    # Create backup
    if ! is_dry_run; then
        mv "$filepath" "$BACKUP_DIR/"
    fi
    return 0  # Signal that we backed up a real file
}

# Process a manifest file
# Format: source|destination|backup|condition
#   - backup is optional, defaults to yes
#   - condition is optional, a profile variable name that must be "true"
# Usage: process_manifest manifest_file
process_manifest() {
    local manifest="$1"
    local repo_root
    repo_root="$(get_repo_root)"

    if [[ ! -f "$manifest" ]]; then
        log_error "Manifest not found: $manifest"
        return 1
    fi

    while IFS='|' read -r source destination backup condition || [[ -n "$source" ]]; do
        # Skip empty lines and comments
        [[ -z "$source" ]] && continue
        [[ "$source" =~ ^[[:space:]]*# ]] && continue

        # Trim whitespace
        source="$(echo "$source" | xargs)"
        destination="$(echo "$destination" | xargs)"
        backup="$(echo "${backup:-}" | xargs)"
        condition="$(echo "${condition:-}" | xargs)"

        # The manifest backup column is reserved for future behavior and is ignored today.
        : "$backup"

        # Check condition if specified
        if [[ -n "$condition" ]]; then
            local condition_value="${!condition:-true}"
            if [[ "$condition_value" != "true" ]]; then
                continue
            fi
        fi

        # Make source path absolute (relative to repo root)
        if [[ "$source" != /* ]]; then
            source="$repo_root/$source"
        fi
        source="$(normalize_path "$source")"

        # Create symlink
        create_symlink "$source" "$destination"
    done < "$manifest"
}

# Check all symlinks from manifest
# Usage: check_manifest manifest_file
check_manifest() {
    local manifest="$1"
    local repo_root
    repo_root="$(get_repo_root)"
    local all_ok=true

    if [[ ! -f "$manifest" ]]; then
        log_error "Manifest not found: $manifest"
        return 1
    fi

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
        if [[ "$source" != /* ]]; then
            source="$repo_root/$source"
        fi
        source="$(normalize_path "$source")"
        destination="${destination/#\~/$HOME}"
        local short_dest
        short_dest="$(shorten_path "$destination")"

        # Check symlink status
        if [[ -L "$destination" ]]; then
            local target
            target="$(resolve_symlink_target "$destination")"
            if [[ "$target" == "$source" ]]; then
                echo -e "  ${GREEN}✓${RESET} ${short_dest}"
            else
                echo -e "  ${YELLOW}~${RESET} ${short_dest} ${DIM}(wrong target)${RESET}"
                all_ok=false
            fi
        elif [[ -e "$destination" ]]; then
            echo -e "  ${RED}✗${RESET} ${short_dest} ${DIM}(not a symlink)${RESET}"
            all_ok=false
        else
            echo -e "  ${RED}✗${RESET} ${short_dest} ${DIM}(missing)${RESET}"
            all_ok=false
        fi
    done < "$manifest"

    $all_ok
}
