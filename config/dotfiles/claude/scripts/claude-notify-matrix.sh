#!/usr/bin/env bash
# claude-notify-matrix.sh — Send Claude Code notifications to Matrix via n8n
# Called by Claude Code hooks with notification type as $1
# Stdin: hook JSON payload from Claude Code

set -euo pipefail

TYPE="${1:-unknown}"
WEBHOOK_URL="https://n8n.example.com/webhook/claude-code"

# Read hook JSON from stdin, extract project name from cwd
INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
PROJECT=$(basename "${CWD:-unknown}")

# Map notification type to human-readable message
case "$TYPE" in
  permission)  MSG="Permission needed" ;;
  idle)        MSG="Waiting for your input" ;;
  elicitation) MSG="MCP tool needs input" ;;
  stopped)     MSG="Task completed" ;;
  *)           MSG="Notification: $TYPE" ;;
esac

# Format and send (backgrounded, non-blocking)
PAYLOAD=$(jq -n --arg msg "Claude Code [$PROJECT]: $MSG" '{message: $msg}')
curl -sk --max-time 5 \
  --resolve "n8n.example.com:443:127.0.0.1" \
  -X POST "$WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  >/dev/null 2>&1 &

exit 0
