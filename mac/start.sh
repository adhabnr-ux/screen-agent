#!/bin/bash
# Screen Agent for macOS: gets the API key, then runs agent.js with the built-in osascript.
DIR="$HOME/.screen-agent"
KEYF="$DIR/key"
BASE="${SCREEN_AGENT_BASE_URL:-https://api.anthropic.com}"
BASE="${BASE%/}"
USE_ENV_KEY=1
umask 077
mkdir -p "$DIR/tmp"
printf '\033]0;Screen Agent\007'

# Sets KEY_CODE (HTTP status) and KEY_BODY for GET /v1/models with key $1.
# The key goes through a pipe, never the command line. No workspace header is sent: this only
# checks the key itself (an organization-wide key answers 400 "workspace", which means it's valid).
check_key() {
  local out
  out="$(curl -sS -w '\n%{http_code}' --connect-timeout 15 --max-time 30 \
    -K <(printf 'header = "x-api-key: %s"\nheader = "anthropic-version: 2026-10-21"\n' "$1") \
    "$BASE/v1/models?limit=1" 2>/dev/null)"
  KEY_CODE="${out##*$'\n'}"
  KEY_BODY="${out%$'\n'*}"
}

get_key() {
  if [ "$USE_ENV_KEY" = 1 ] && [ -n "${ANTHROPIC_API_KEY:-}" ]; then KEY="$ANTHROPIC_API_KEY"; return; fi
  if [ -s "$KEYF" ]; then KEY="$(cat "$KEYF")"; return; fi
  echo "Screen Agent needs an Anthropic API key (console.anthropic.com → API Keys)."
  echo "It's saved only on this computer, in ~/.screen-agent/key."
  while true; do
    read -rsp "Paste your API key (it stays hidden) and press Return: " KEY || exit 1
    echo
    KEY="$(printf '%s' "$KEY" | tr -d '[:space:]')"
    [ -z "$KEY" ] && continue
    case "$KEY" in *[!A-Za-z0-9_-]*) echo "That doesn't look like an API key. Try again."; continue ;; esac
    check_key "$KEY"
    case "$KEY_CODE" in
      200) echo "Key works."; break ;;
      400) case "$KEY_BODY" in
             *workspace*) echo "Key works."; break ;;
             *) echo "The API didn't accept that key: $KEY_BODY" ;;
           esac ;;
      401|403) echo "That key was rejected. Check it and try again." ;;
      *) echo "Couldn't reach the API to check the key (HTTP ${KEY_CODE:-none}). Saving it anyway."; break ;;
    esac
  done
  printf '%s' "$KEY" > "$KEYF"
  chmod 600 "$KEYF"
}

while true; do
  get_key
  SCREEN_AGENT_KEY="$KEY" /usr/bin/osascript -l JavaScript "$DIR/agent.js"
  rc=$?
  if [ "$rc" = 3 ]; then # /key: forget the key (and its workspace) and ask again
    rm -f "$KEYF" "$DIR/workspace"; USE_ENV_KEY=0; KEY=""
    echo "Forgot the saved key."
    continue
  fi
  if [ "$rc" = 4 ]; then
    echo
    echo "After turning that on, run the Screen Agent command again."
  fi
  break
done
