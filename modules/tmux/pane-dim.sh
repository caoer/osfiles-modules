#!/usr/bin/env bash
# pane-dim.sh — highlight ONLY the panes actually squished by the f/g maximize.
#
# A pane is highlighted iff it (a) shares the maximized axis with the active pane
# AND (b) is actually shrunk to minimal size in that axis. The size gate is what
# keeps large panes that merely share a row/column (e.g. the pane you're reading)
# from being marked. Each apply clears every pane first, so nothing goes stale.
#
#   pane-dim.sh y   <active_pane_id>   # f: same column + short  -> highlight
#   pane-dim.sh x   <active_pane_id>   # g: same row    + narrow -> highlight
#   pane-dim.sh off <active_pane_id>   # clear highlight on every pane in the window
#
# ── WHERE THIS IS WIRED ──────────────────────────────────────────────────────
# Called from the prefix-f / prefix-g "maximize" bindings in tmux-base.conf
# (search "pane-maximize"). Those bindings: save layout -> resize-pane -y/-x 9999
# -> run this script -> set @vmax/@hmax. The restore branch calls `off`.
# Cmd+- / Cmd+= in WezTerm (config/wezterm/common.lua) send prefix f / g.
#
# ── GOTCHAS LEARNED THE HARD WAY (read before iterating) ─────────────────────
#  1. bg MUST differ from the terminal background (Tokyo Night #1a1b26). Setting
#     bg to the same color renders as nothing — looks like "the bg doesn't work".
#  2. window-style only recolors DEFAULT-fg/bg cells. A pane running a colorful
#     TUI or prompt keeps its own colors; you cannot fully desaturate content.
#  3. window-style is settable per-pane with `set -p` / unset with `set -up`.
#     (Window/global `set -w window-style` would dim EVERY inactive pane,
#     including a full-size side pane — which is the bug this script avoids.)
#  4. Do NOT match by axis-overlap alone. resize-pane -y/-x does not shrink every
#     same-axis pane to minimal; large neighbors can survive. Overlap WITHOUT the
#     size gate wrongly marks them. Keep both conditions.
#  5. This is a snapshot taken at maximize time — there is NO layout-change hook.
#     If you split/resize while maximized the marks can drift; a toggle off/on
#     (or `off`) refreshes. Add a `window-layout-changed` hook if drift matters.
#  6. set-option / select-layout do NOT format-expand args (only run-shell does) —
#     relevant in tmux-base.conf, not here, but the same trap bites layout save.
#
# ── TUNING ───────────────────────────────────────────────────────────────────
#  DIM   : the highlight style. fg/bg are tmux style strings (hex or named).
#  MIN_H : a vertically-squished pane is this short or less (raise if too few hit).
#  MIN_W : a horizontally-squished pane is this narrow or less.
set -euo pipefail

# muted yellow highlighter: dark text on softened yellow bg (bg must differ from terminal bg #1a1b26)
DIM='fg=#15161e,bg=#cbb45f'
MIN_H=3   # a vertically-squished pane is this short or less
MIN_W=8   # a horizontally-squished pane is this narrow or less

mode="$1"
active="${2:-}"

clear_all() {
  for id in $(tmux list-panes -t "$1" -F '#{pane_id}'); do
    tmux set -up -t "$id" window-style 2>/dev/null || true
  done
}

if [ "$mode" = "off" ]; then
  clear_all "$active"
  exit 0
fi

# active pane edges
read -r AL AR AT AB <<EOF
$(tmux display -p -t "$active" '#{pane_left} #{pane_right} #{pane_top} #{pane_bottom}')
EOF

clear_all "$active"   # wipe any stale marks before re-marking

tmux list-panes -t "$active" \
  -F '#{pane_id} #{pane_left} #{pane_right} #{pane_top} #{pane_bottom} #{pane_width} #{pane_height}' |
while read -r id l r t b w h; do
  [ "$id" = "$active" ] && continue
  case "$mode" in
    y) # same column (x overlap) AND short
       if [ "$l" -le "$AR" ] && [ "$r" -ge "$AL" ] && [ "$h" -le "$MIN_H" ]; then
         tmux set -p -t "$id" window-style "$DIM"
       fi ;;
    x) # same row (y overlap) AND narrow
       if [ "$t" -le "$AB" ] && [ "$b" -ge "$AT" ] && [ "$w" -le "$MIN_W" ]; then
         tmux set -p -t "$id" window-style "$DIM"
       fi ;;
  esac
done
