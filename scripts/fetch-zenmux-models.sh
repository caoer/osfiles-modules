#!/usr/bin/env bash
# fetch-zenmux-models.sh — fetch the current ZenMux model catalog and emit a
# normalized, machine-readable list we can regenerate anytime.
#
# ZenMux (https://zenmux.ai) is a multi-provider model router. It exposes an
# OpenAI-style, UNAUTHENTICATED models endpoint at /api/v1/models — no API key
# needed for the catalog. This script fetches it and normalizes each entry to
# { id, label, context_length, owned_by, reasoning }, sorted by id for stable
# diffs.
#
# LOUD FAILURE CONTRACT: any error (endpoint unreachable, non-JSON body, empty
# catalog) aborts non-zero and prints nothing usable to stdout. A stale/empty
# catalog must be a visible failure, not a silent success — there is no fallback
# to vendored content.
#
# USAGE:
#   fetch-zenmux-models.sh            normalized JSON array [{id,label,...}] to stdout
#   fetch-zenmux-models.sh --raw      the untransformed ZenMux API payload
#
# ENV:
#   ZENMUX_MODELS_URL   override the endpoint (default below)
#
# DEPS: bash, curl, jq (all present in the nix devshell / system profile).
set -euo pipefail

url="${ZENMUX_MODELS_URL:-https://zenmux.ai/api/v1/models}"

raw=0
[[ "${1:-}" == "--raw" ]] && raw=1

body=$(curl -fsS -m 30 "$url") \
  || { echo "ERROR: failed to fetch $url" >&2; exit 1; }

# Validate: OpenAI-style { data: [ ... ] } with a non-empty catalog.
echo "$body" | jq -e '(.data | type == "array") and (.data | length > 0)' > /dev/null \
  || { echo "ERROR: $url did not return a non-empty OpenAI-style {data:[...]} catalog" >&2; exit 1; }

if [[ "$raw" -eq 1 ]]; then
  echo "$body" | jq .
  exit 0
fi

echo "$body" | jq '[
  .data[] | {
    id,
    label: .display_name,
    context_length,
    owned_by,
    reasoning: (.capabilities.reasoning // false)
  }
] | sort_by(.id)'
