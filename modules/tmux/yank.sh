#!/usr/bin/env bash

set -eu

# Check if we're on macOS
is_macos() {
  [[ "$OSTYPE" == "darwin"* ]]
}

# Check if we're in an SSH session
is_ssh() {
  [[ -n "${SSH_CONNECTION:-}" ]]
}

# Main clipboard command
if is_macos && ! is_ssh; then
  # On macOS, use pbcopy
  pbcopy
elif command -v xclip > /dev/null 2>&1; then
  # On Linux with xclip
  xclip -selection clipboard
elif command -v xsel > /dev/null 2>&1; then
  # On Linux with xsel
  xsel --clipboard --input
else
  # Fallback: use OSC 52 sequence for terminal clipboard
  # This works over SSH and in many modern terminals
  buf=$(cat "$@")
  if [[ -n "$buf" ]]; then
    encoded=$(printf "%s" "$buf" | base64 | tr -d '\n')
    printf "\033]52;c;%s\a" "$encoded"
  fi
fi