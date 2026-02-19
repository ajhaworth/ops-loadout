#!/bin/bash
input=$(cat)
model=$(echo "$input" | jq -r '.model.display_name')
cwd=$(echo "$input" | jq -r '.workspace.current_dir')
context_remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')

cd "$cwd" 2>/dev/null
git_branch=$(git branch --show-current 2>/dev/null)

status="$model"
dir_display="${cwd/#$HOME/~}"
status="$status | $dir_display"
[ -n "$git_branch" ] && status="$status | git:$git_branch"
if [ -n "$context_remaining" ]; then
    bar_width=10
    filled=$((context_remaining * bar_width / 100))
    empty=$((bar_width - filled))

    if [ "$context_remaining" -ge 50 ]; then
        color="\033[32m"  # green
    elif [ "$context_remaining" -ge 20 ]; then
        color="\033[33m"  # yellow
    else
        color="\033[31m"  # red
    fi

    filled_bar=$(printf '%0.s█' $(seq 1 $((filled > 0 ? filled : 1))))
    [ "$filled" -eq 0 ] && filled_bar=""
    empty_bar=$(printf '%0.s░' $(seq 1 $((empty > 0 ? empty : 1))))
    [ "$empty" -eq 0 ] && empty_bar=""

    status="$status | ${color}${filled_bar}\033[90m${empty_bar}\033[0m ${context_remaining}%"
fi

echo -e "$status"
