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
[ -n "$context_remaining" ] && status="$status | context:${context_remaining}%"

echo -e "$status"
