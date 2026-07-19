#!/usr/bin/env bash
# telegram-notify.sh - send a message to Telegram.
#
# Usage: telegram-notify.sh "<message>"
#
# Env:
#   TELEGRAM_TOKEN  Bot token (if unset: silent no-op)
#   TELEGRAM_CHAT   Primary chat ID (if unset: silent no-op)
#
# Always sends to BOTH the primary chat AND the agent group -1003669787601
# (matches the Jenkins tg() function for the "Mecha Unlimited" builder group).
#
# Never fails the pipeline - Telegram is best-effort notification only.
set -uo pipefail

msg="$1"
agent_chat="-1003669787601"

if [ -z "${TELEGRAM_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT:-}" ]; then
  exit 0
fi

send_one() {
  local chat="$1"
  curl -s -o /dev/null \
    -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    -d chat_id="$chat" \
    --data-urlencode text="$msg" \
    -d parse_mode=HTML \
    -d disable_web_page_preview=true \
    || true
}

send_one "$TELEGRAM_CHAT"
send_one "$agent_chat"
