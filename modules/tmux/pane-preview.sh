#!/bin/bash
# Preview a tmux pane/session for fzf.
# Strips OSC 8 hyperlinks and trailing blank lines.
# Usage: pane-preview.sh <target> [--tail]
#   --tail: show bottom of pane (for session picker)
#   without: show full pane (for window/pane picker)
# Falls back to sesh preview for non-tmux entries.

target="$1"
mode="$2"

out=$(tmux capture-pane -ep -t "$target" 2>/dev/null \
  | perl -pe 's/\e\]8;;[^\e]*\e\\//g')

if [ -z "$(echo "$out" | tr -d '[:space:]')" ]; then
  sesh preview "$target" 2>/dev/null
  exit 0
fi

if [ "$mode" = "--tail" ]; then
  echo "$out" | tail -n "${FZF_PREVIEW_LINES:-50}"
else
  echo "$out" | awk '{buf[NR]=$0} /[^ \t]/{last=NR} END{for(i=1;i<=last;i++) print buf[i]}'
fi
