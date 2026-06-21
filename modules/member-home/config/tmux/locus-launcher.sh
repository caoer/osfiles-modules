#!/usr/bin/env bash
# locus-launcher.sh — tmux session launcher popup + create-or-switch helper.
# Bound to Ctrl+F in tmux-base.conf.
#
# Modes:
#   locus-launcher.sh            open the fzf picker (lists tmux + configured
#                                sessions, no zoxide; Enter switches, ^f creates)
#   locus-launcher.sh new NAME   create-or-switch a session named NAME, rooted
#                                in the shared projects dir (Mac) or $HOME (servers),
#                                with yazi started in a shell (sent as keys so
#                                quitting yazi drops to the shell — matches the
#                                sesh.toml `startup_command = "yazi"` convention)
#   locus-launcher.sh cycle DIR  internal: cycle display mode (DIR = next|prev),
#                                emit fzf actions to reload+reprompt. Bound to
#                                up/down arrows inside the picker.
#
# Display modes (tabs) — tab/btab cycle through them, up/down move the cursor:
#   sessions  tmux + configured sessions (default)
#   zoxide    zoxide frecency directories
#   all       everything sesh knows about
#
# Root + label resolve together: the shared projects dir when present
# ("projects"), else $HOME labelled with the short hostname — so the picker is
# host-aware.

set -uo pipefail

projects="/Users/Shared/projects"
if [ -d "$projects" ]; then
  root="$projects"
  label="projects"
else
  root="$HOME"
  label="$(hostname -s 2>/dev/null || hostname)"
fi

# new_session NAME [startup]
#   startup = yazi (default, ^f path) → launch yazi in the new session's shell
#   startup = shell                   → leave a bare shell (enter path)
new_session() {
  local name="${1:-}" startup="${2:-yazi}"
  # tmux forbids '.' and ':' in session names — fold them to '-'
  name="${name//./-}"
  name="${name//:/-}"
  # trim surrounding whitespace
  name="${name#"${name%%[![:space:]]*}"}"
  name="${name%"${name##*[![:space:]]}"}"
  [ -z "$name" ] && return 0

  if tmux has-session -t "=${name}" 2>/dev/null; then
    tmux switch-client -t "=${name}"
    return 0
  fi
  tmux new-session -d -s "$name" -c "$root"
  # send as keys (not the session command) so quitting yazi drops to the shell
  [ "$startup" = "yazi" ] && tmux send-keys -t "$name" yazi Enter
  tmux switch-client -t "$name"
}

# --- Display modes -----------------------------------------------------------
# Ordered list of tabs. Each name maps to a list command + prompt glyph below.
modes=(sessions zoxide all)

# Each list is sorted alphabetically by name (field 2, after the icon glyph),
# case-insensitive — this is the resting order with an empty query. fzf then
# re-ranks by match score as you type (see absence of --no-sort below).
mode_list_cmd() {
  local sort='sort -f -k2'
  case "$1" in
    sessions) printf 'sesh list --icons --tmux --config | %s' "$sort" ;;
    zoxide)   printf 'sesh list -z --icons | %s' "$sort" ;;
    all)      printf 'sesh list --icons | %s' "$sort" ;;
  esac
}

mode_prompt() {
  case "$1" in
    sessions) printf '📁  ' ;;
    zoxide)   printf '🗂  ' ;;
    all)      printf '🌐  ' ;;
  esac
}

# State file keyed by the popup's tmux pane so concurrent launchers don't clash.
mode_state_file() {
  local key="${TMUX_PANE:-default}"
  printf '%s/locus-launcher-mode-%s' "${TMPDIR:-/tmp}" "${key//[^a-zA-Z0-9]/_}"
}

# cycle: advance the mode index (next|prev), persist it, and emit the fzf
# actions that swap the list + prompt + border label. Output is consumed by
# fzf's `transform` binding (bound to tab/btab).
cycle_mode() {
  local dir="${1:-next}"
  local state n cur mode list prompt
  state="$(mode_state_file)"
  n=${#modes[@]}
  cur="$(cat "$state" 2>/dev/null || echo 0)"
  case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
  if [ "$dir" = "prev" ]; then
    cur=$(( (cur - 1 + n) % n ))
  else
    cur=$(( (cur + 1) % n ))
  fi
  printf '%s' "$cur" >"$state"
  mode="${modes[$cur]}"
  list="$(mode_list_cmd "$mode")"
  prompt="$(mode_prompt "$mode")"
  printf 'change-prompt(%s)+change-border-label(%s)+reload(%s)' \
    "$prompt" \
    "$(printf '\033[35m %s · %s \033[0m' "$label" "$mode")" \
    "$list"
}

# new (^f): create-or-switch with yazi · newshell (enter): bare shell.
# Name is everything after the keyword, so queries with spaces survive.
if [ "${1:-}" = "new" ]; then
  shift
  new_session "$*" yazi
  exit 0
fi

if [ "${1:-}" = "newshell" ]; then
  shift
  new_session "$*" shell
  exit 0
fi

if [ "${1:-}" = "cycle" ]; then
  cycle_mode "${2:-next}"
  exit 0
fi

self="$HOME/.config/tmux/locus-launcher.sh"

# enter: decide what the Enter key does. With matches, accept the selection
# (printed to stdout → sesh connect). With zero matches, create a session from
# the typed query. Bound via `transform`, reading fzf's FZF_* env vars.
if [ "${1:-}" = "enter" ]; then
  if [ "${FZF_MATCH_COUNT:-0}" -eq 0 ] && [ -n "${FZF_QUERY:-}" ]; then
    printf 'become(%s newshell %s)' "$self" "$FZF_QUERY"
  else
    printf 'accept'
  fi
  exit 0
fi

# Default: the picker popup. Start on mode 0 (sessions).
printf '0' >"$(mode_state_file)"

eval "$(mode_list_cmd sessions)" | fzf \
  --height=100% \
  --ansi \
  --border-label "$(printf '\033[35m %s · sessions \033[0m' "$label")" \
  --prompt '📁  ' \
  --header "  tab/⇧tab → switch mode · ↑↓ → move · enter → open (or create if no match) · ^d kill · esc" \
  --bind "tab:transform:$self cycle next" \
  --bind "btab:transform:$self cycle prev" \
  --bind "enter:transform:$self enter" \
  --bind "ctrl-f:execute($self new {q})+abort" \
  --bind 'ctrl-d:execute-silent(tmux kill-session -t {2..})+change-prompt(🪟  )+reload(sesh list -t --icons)' \
  --preview-window 'right:70%:nowrap' \
  --preview '~/.config/tmux/pane-preview.sh {2..} --tail' |
  xargs -I {} sesh connect '{}'
