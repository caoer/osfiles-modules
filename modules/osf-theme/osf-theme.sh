#!/usr/bin/env bash
# osf-theme — single light/dark variant oracle for themed CLI tools.
# Shipped by modules/osf-theme/osf-theme.nix (writeShellScriptBin); the header
# comment there carries the design story. Verbs:
#   variant (default)  pure read: darwin defaults → $OSF_APPEARANCE → cache → dark
#   login              fresh-session resolve (OSC 11 query on linux) + cache + apply
#   sync               forced re-query, ignores env/cache; fails loud if unanswered
#   apply              re-apply consumers (btop active.theme) from current variant
set -u

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/osf-theme"
CACHE="$STATE_DIR/variant"

valid() { [ "${1:-}" = dark ] || [ "${1:-}" = light ]; }

darwin_variant() {
  [ "$(uname)" = Darwin ] || return 1
  command -v defaults >/dev/null 2>&1 || return 1
  if [ "$(defaults read -g AppleInterfaceStyle 2>/dev/null)" = Dark ]; then
    echo dark
  else
    echo light
  fi
}

env_variant() { valid "${OSF_APPEARANCE:-}" && echo "$OSF_APPEARANCE"; }

cache_variant() {
  local v
  v=$(cat "$CACHE" 2>/dev/null) || return 1
  valid "$v" && echo "$v"
}

# COLORFGBG is "fg;bg" (sometimes "fg;default;bg"); bg 7/15 = light.
colorfgbg_variant() {
  case "${COLORFGBG:-}" in
  *\;*)
    case "${COLORFGBG##*;}" in
    7 | 15) echo light ;;
    [0-9] | 1[0-4]) echo dark ;;
    *) return 1 ;;
    esac
    ;;
  *) return 1 ;;
  esac
}

# Ask the terminal for its background color (OSC 11) and classify by
# luminance. Reads /dev/tty raw with a bounded stty timeout — never hangs.
# Works through SSH; tmux ≥3.3 answers for its client terminal.
osc11_variant() {
  local oldstty resp rgb r g b lum
  { exec 3<>/dev/tty; } 2>/dev/null || return 1
  oldstty=$(stty -g <&3 2>/dev/null) || {
    exec 3>&-
    return 1
  }
  if ! stty raw -echo min 0 time 3 <&3 2>/dev/null; then
    exec 3>&-
    return 1
  fi
  printf '\033]11;?\033\\' >&3
  # min 0 time 3 → each read returns on the first byte or after 0.3 s; the
  # second read scoops a reply that split across reads.
  resp=$(dd bs=64 count=1 <&3 2>/dev/null)
  case "$resp" in
  *rgb:*) : ;;
  *) resp="$resp$(dd bs=64 count=1 <&3 2>/dev/null)" ;;
  esac
  stty "$oldstty" <&3 2>/dev/null
  exec 3>&-
  rgb=$(printf '%s' "$resp" | LC_ALL=C grep -ao 'rgb:[0-9a-fA-F]*/[0-9a-fA-F]*/[0-9a-fA-F]*' | head -n1)
  [ -n "$rgb" ] || return 1
  rgb=${rgb#rgb:}
  # Channels are 2- or 4-hex-digit; take the high byte of each.
  # shellcheck disable=SC2086
  set -- ${rgb//\// }
  [ $# -eq 3 ] || return 1
  r=$(printf '%s' "$1" | cut -c1-2)
  g=$(printf '%s' "$2" | cut -c1-2)
  b=$(printf '%s' "$3" | cut -c1-2)
  lum=$(((2126 * 16#$r + 7152 * 16#$g + 722 * 16#$b) / 10000))
  if [ "$lum" -ge 128 ]; then echo light; else echo dark; fi
}

save() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '%s\n' "$1" >"$CACHE".tmp 2>/dev/null && mv -f "$CACHE".tmp "$CACHE" 2>/dev/null
}

# Consumers that need a concrete theme file, applied from the variant.
# Darwin's btop is owned by tmux-theme.sh sync_btop (family-aware, fired by
# the wezterm appearance hook) — hands off here. Linux has no family picker,
# so the variant maps to the default family pair, the same fallback pair
# tmux-theme.sh uses (dark → tokyo-night, light → flat-remix-light).
apply_consumers() {
  [ "$(uname)" = Darwin ] && return 0
  local variant="$1" bt src dir
  command -v btop >/dev/null 2>&1 || return 0
  if [ "$variant" = light ]; then bt=flat-remix-light; else bt=tokyo-night; fi
  src=$(readlink -f "$(command -v btop)" 2>/dev/null) || return 0
  dir="$(dirname "$src")/../share/btop/themes"
  [ -f "$dir/$bt.theme" ] || return 0
  mkdir -p "$HOME/.config/btop/themes"
  cp -f "$dir/$bt.theme" "$HOME/.config/btop/themes/active.theme" 2>/dev/null || true
}

read_variant() {
  darwin_variant || env_variant || cache_variant || echo dark
}

resolve_variant() {
  darwin_variant || osc11_variant || env_variant || colorfgbg_variant || cache_variant || echo dark
}

case "${1:-variant}" in
variant)
  read_variant
  ;;
login)
  v=$(resolve_variant)
  save "$v"
  apply_consumers "$v"
  echo "$v"
  ;;
sync)
  if ! v=$(darwin_variant || osc11_variant || colorfgbg_variant); then
    echo "osf-theme: terminal did not answer the background query; keeping $(read_variant)" >&2
    exit 1
  fi
  save "$v"
  apply_consumers "$v"
  echo "$v"
  ;;
apply)
  apply_consumers "$(read_variant)"
  ;;
*)
  echo "usage: osf-theme [variant|login|sync|apply]" >&2
  exit 2
  ;;
esac
