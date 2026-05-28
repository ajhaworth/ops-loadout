#!/bin/bash
# Colors matching Starship/Vesper palette
BLUE="\033[38;2;97;175;239m"    # #61AFEF - directory
GREEN="\033[38;2;78;201;148m"   # #4EC994 - git branch
YELLOW="\033[38;2;212;166;86m"  # #D4A656 - model/misc
DIM="\033[38;2;107;107;107m"    # #6B6B6B - separators
RED="\033[38;2;224;108;117m"    # #E06C75 - deletions/errors
RESET="\033[0m"
BOLD="\033[1m"

input=$(cat)
model=$(echo "$input" | jq -r '.model.display_name')
cwd=$(echo "$input" | jq -r '.workspace.current_dir')
context_remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')

# Rate limits: find the most constrained window (highest used_percentage)
rate_limit_pct=$(echo "$input" | jq -r '
  [.rate_limits // [] | .[] | .used_percentage // 0] | max // empty
')
rate_limit_resets=$(echo "$input" | jq -r '
  [.rate_limits // [] | .[] | {used_percentage: (.used_percentage // 0), resets_at}]
  | sort_by(-.used_percentage) | first | .resets_at // empty
')

# Truncate directory: show up to last 3 components, replace home with ~
dir_display="${cwd/#$HOME/~}"
# Use awk for portable truncation (macOS ships bash 3.2, no negative indexing)
dir_display=$(echo "$dir_display" | awk -F'/' '{
    n = 0; for (i=1; i<=NF; i++) if ($i != "") n++
    if (n <= 3) { print; next }
    # grab last 3 non-empty components
    j = 0
    for (i=NF; i>=1; i--) {
        if ($i != "") { c[++j] = $i; if (j==3) break }
    }
    printf "…/%s/%s/%s\n", c[3], c[2], c[1]
}')

cd "$cwd" 2>/dev/null
git_branch=$(GIT_OPTIONAL_LOCKS=0 git branch --show-current 2>/dev/null)

git_diff=""
if [ -n "$git_branch" ]; then
    diff_stats=$(GIT_OPTIONAL_LOCKS=0 git diff --numstat HEAD 2>/dev/null | awk '{add+=$1; del+=$2} END {if(add>0 || del>0) print add, del}')
    if [ -n "$diff_stats" ]; then
        additions=$(echo "$diff_stats" | cut -d' ' -f1)
        deletions=$(echo "$diff_stats" | cut -d' ' -f2)
        git_diff=" ${GREEN}+${additions}${RESET} ${RED}-${deletions}${RESET}"
    fi
fi

sep="${DIM} | ${RESET}"

# Build status line
status="${YELLOW}${model}${RESET}"
status="${status}${sep}${BOLD}${BLUE}${dir_display}${RESET}"

if [ -n "$git_branch" ]; then
    status="${status}${sep}${GREEN} ${git_branch}${RESET}${git_diff}"
fi

if [ -n "$context_remaining" ]; then
    bar_width=10
    filled=$((context_remaining * bar_width / 100))
    empty=$((bar_width - filled))

    if [ "$context_remaining" -ge 50 ]; then
        bar_color="${GREEN}"
    elif [ "$context_remaining" -ge 20 ]; then
        bar_color="${YELLOW}"
    else
        bar_color="${RED}"
    fi

    filled_bar=""
    [ "$filled" -gt 0 ] && filled_bar=$(printf '%0.s█' $(seq 1 "$filled"))
    empty_bar=""
    [ "$empty" -gt 0 ] && empty_bar=$(printf '%0.s░' $(seq 1 "$empty"))

    status="${status}${sep}${bar_color}${filled_bar}${DIM}${empty_bar}${RESET} ${context_remaining}%"
fi

if [ -n "$rate_limit_pct" ]; then
    rate_pct_int="${rate_limit_pct%.*}"
    if [ "$rate_pct_int" -ge 80 ]; then
        rate_color="${RED}"
    elif [ "$rate_pct_int" -ge 50 ]; then
        rate_color="${YELLOW}"
    else
        rate_color="${GREEN}"
    fi

    rate_display="${rate_color}⚡${rate_pct_int}%${RESET}"

    # Show time until reset if usage is notable
    if [ "$rate_pct_int" -ge 50 ] && [ -n "$rate_limit_resets" ]; then
        now=$(date +%s)
        resets_epoch=$(date -jf "%Y-%m-%dT%H:%M:%S" "${rate_limit_resets%%.*}" +%s 2>/dev/null \
            || date -d "${rate_limit_resets}" +%s 2>/dev/null)
        if [ -n "$resets_epoch" ]; then
            remaining_secs=$((resets_epoch - now))
            if [ "$remaining_secs" -gt 0 ]; then
                remaining_mins=$((remaining_secs / 60))
                if [ "$remaining_mins" -ge 60 ]; then
                    remaining_hrs=$((remaining_mins / 60))
                    rate_display="${rate_display}${DIM} ${remaining_hrs}h${RESET}"
                else
                    rate_display="${rate_display}${DIM} ${remaining_mins}m${RESET}"
                fi
            fi
        fi
    fi

    status="${status}${sep}${rate_display}"
fi

printf "%b\n" "$status"
