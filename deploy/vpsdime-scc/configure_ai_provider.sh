#!/usr/bin/env bash
# Configure server-only AI credentials from the authorized VPS root console.
# This script makes no outbound network calls and incurs no API usage.
set -Eeuo pipefail
umask 077
if [ "$(id -u)" -ne 0 ]; then
  echo "Authorized VPS root console required." >&2
  exit 1
fi
TARGET=/opt/scc-production
[ -d "$TARGET" ] || { echo "Production directory missing." >&2; exit 1; }
[ "$(stat -c %U "$TARGET")" = root ] ||
  { echo "Production directory must be root-owned." >&2; exit 1; }

echo "Configure your own billed provider; no API call is made here."
echo "Supported provider route: OpenAI Chat Completions over HTTPS."
read -r -p "AI model identifier from your account: " model
if ! [[ "$model" =~ ^[A-Za-z0-9._/:-]{2,100}$ ]]; then
  echo "Invalid model identifier." >&2
  exit 1
fi
read -r -p "Daily requests per normal user [8]: " daily
if [ -z "$daily" ]; then daily=8; fi
if ! [[ "$daily" =~ ^[0-9]{1,3}$ ]] || [ "$daily" -lt 1 ] || [ "$daily" -gt 100 ]; then
  echo "Daily limit must be from 1 to 100." >&2
  exit 1
fi
read -r -s -p "Provider API key (hidden): " key
echo
len=$(printf '%s' "$key" | wc -c)
if [ "$len" -lt 20 ] || [ "$len" -gt 1000 ]; then
  unset key
  echo "Invalid API key length." >&2
  exit 1
fi

candidate=$(mktemp "$TARGET/.scc-ai-env.XXXXXX")
trap 'rm -f "$candidate"; unset key' EXIT
{
  printf 'SCC_AI_API_URL=%s\n' 'https://api.openai.com/v1/chat/completions'
  printf 'SCC_AI_MODEL=%s\n' "$model"
  printf 'SCC_AI_DAILY_LIMIT=%s\n' "$daily"
  printf 'SCC_AI_API_KEY=%s\n' "$key"
} > "$candidate"
chmod 0600 "$candidate"
chown root:root "$candidate"
unset key
mv -f "$candidate" "$TARGET/ai.env"
trap - EXIT
echo "Server-only credentials stored with root-only permissions."
echo "Never share or upload ai.env."
