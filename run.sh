#!/usr/bin/env bash
# Screen Agent launcher for macOS and Linux. Nothing is installed: it downloads three small text
# files into ~/.screen-agent and runs them with tools the OS already has.
#
#   curl -fsSL https://raw.githubusercontent.com/adhabnr-ux/screen-agent/main/run.sh | bash
#
# Run in this window instead of opening a new one:
#   curl -fsSL https://raw.githubusercontent.com/adhabnr-ux/screen-agent/main/run.sh | bash -s -- --here
set -u

RAW="${SCREEN_AGENT_REPO_RAW:-https://raw.githubusercontent.com/adhabnr-ux/screen-agent/main}"
DIR="$HOME/.screen-agent"
HERE=0
for arg in "$@"; do [ "$arg" = "--here" ] && HERE=1; done

say() { printf '%s\n' "$*"; }
die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

umask 077
mkdir -p "$DIR/tmp" || die "Couldn't create $DIR."
chmod 700 "$DIR"

fetch() { # fetch <repo path> <local name>
  curl -fsSL --retry 3 --connect-timeout 20 "$RAW/$1" -o "$DIR/$2.part" && mv -f "$DIR/$2.part" "$DIR/$2" \
    || die "Couldn't download $1. Check the internet connection (or whether raw.githubusercontent.com is blocked here)."
}

# New terminal windows don't inherit this shell's environment, so pass SCREEN_AGENT_* settings
# through a file the new window reads. (The API key is never written here.)
: > "$DIR/env"
for v in $(compgen -e | grep '^SCREEN_AGENT_'); do printf 'export %s=%q\n' "$v" "${!v}" >> "$DIR/env"; done

run_here() { # run the agent in this terminal, reading the keyboard even when this script came from a pipe
  if [ -t 0 ]; then exec "$@"; fi
  if [ -r /dev/tty ]; then exec "$@" </dev/tty; fi
  die "No keyboard attached to this terminal. Open a terminal window and run the command there."
}

case "$(uname -s)" in
  Darwin)
    fetch mac/agent.js agent.js
    fetch mac/start.sh start.sh
    chmod 700 "$DIR/start.sh"
    if [ "$HERE" = 1 ]; then run_here /bin/bash "$DIR/start.sh"; fi
    printf '#!/bin/bash\n. "$HOME/.screen-agent/env" 2>/dev/null\nexec /bin/bash "$HOME/.screen-agent/start.sh"\n' > "$DIR/Screen Agent.command"
    chmod 700 "$DIR/Screen Agent.command"
    if open -a Terminal "$DIR/Screen Agent.command" 2>/dev/null; then
      say "Screen Agent opened in a new Terminal window."
    else
      say "Couldn't open a new window; starting here."
      run_here /bin/bash "$DIR/start.sh"
    fi
    ;;
  Linux)
    PY=$(command -v python3 || true)
    [ -n "$PY" ] || die "Screen Agent needs python3, which this Linux system doesn't have."
    fetch linux/agent.py agent.py
    if [ "$HERE" = 1 ] || [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then run_here "$PY" "$DIR/agent.py"; fi
    INNER=". \"\$HOME/.screen-agent/env\" 2>/dev/null; \"$PY\" \"\$HOME/.screen-agent/agent.py\"; echo; read -rp 'Press Return to close this window.' _"
    opened=0
    for t in x-terminal-emulator gnome-terminal konsole xfce4-terminal mate-terminal lxterminal tilix kitty alacritty xterm; do
      command -v "$t" >/dev/null 2>&1 || continue
      case "$t" in
        gnome-terminal|tilix) "$t" -- bash -c "$INNER" >/dev/null 2>&1 && opened=1 ;;
        xfce4-terminal|mate-terminal) "$t" -x bash -c "$INNER" >/dev/null 2>&1 & opened=1 ;;
        kitty) "$t" bash -c "$INNER" >/dev/null 2>&1 & opened=1 ;;
        *) "$t" -e bash -c "$INNER" >/dev/null 2>&1 & opened=1 ;;
      esac
      [ "$opened" = 1 ] && break
    done
    if [ "$opened" = 1 ]; then
      say "Screen Agent opened in a new terminal window."
    else
      say "Couldn't find a terminal app to open; starting here."
      run_here "$PY" "$DIR/agent.py"
    fi
    ;;
  MINGW*|MSYS*|CYGWIN*)
    say "On Windows, open PowerShell (not Git Bash) and run:"
    say "  irm $RAW/windows/run.ps1 | iex"
    ;;
  *)
    die "Screen Agent runs on macOS, Linux and Windows. This system is $(uname -s)."
    ;;
esac
