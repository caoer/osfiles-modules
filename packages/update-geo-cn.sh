#!/usr/bin/env bash
# update-geo-cn.sh — bump (or --check) the pinned geo-cn rule-set hash from
# rules.sui.pics (our geo-rules CDN).
#
# LOUD FAILURE CONTRACT: any error (R2 unreachable, bad JSON, not a sing-box
# source rule-set) aborts non-zero and leaves the pin UNCHANGED. There is
# deliberately no fallback to previous/vendored content — a stale pin must be a
# visible failure, not a silent success.
#
# USAGE:
#   update-geo-cn.sh            bump the pin to the current live content
#   update-geo-cn.sh --check    exit non-zero if the pin is STALE (no edit) —
#                               for CI/cron so geo drift is LOUD, not silent.
#
# SHIP CHAIN (committing the pin here ships NOTHING to the fleet on its own):
#   1. commit + push osfiles-modules
#   2. bump osf-modules in BOTH consumers:
#        osfiles:            nix flake update osf-modules && commit
#        coscene-nix-nixos:  nix flake update osf-modules && commit
#   3. deploy the gateways (canary macross-dev → gateway-cq → volcengine gz/sh
#      via scripts/enable-sing-box-tun.sh → gateway-cd LAST)
set -euo pipefail

check_only=0
[[ "${1:-}" == "--check" ]] && check_only=1

url="https://rules.sui.pics/singbox/rule-sets/cn.json"
pin_file="$(cd "$(dirname "$0")" && pwd)/geo-cn-ruleset.nix"

# Exactly one pinned hash must exist, else the sed rewrite below is ambiguous.
hash_count=$(grep -cE 'sha256-[A-Za-z0-9+/=]+' "$pin_file" || true)
[[ "$hash_count" -eq 1 ]] \
  || { echo "ERROR: expected exactly one sha256 pin in $pin_file, found $hash_count" >&2; exit 1; }
old_hash=$(grep -oE 'sha256-[A-Za-z0-9+/=]+' "$pin_file" | head -1)

echo "prefetching $url ..."
prefetch_json=$(nix store prefetch-file --json "$url")
hash=$(echo "$prefetch_json" | jq -er .hash)
store_path=$(echo "$prefetch_json" | jq -er .storePath)

# Validate: sing-box source-format rule-set (version + rules present).
jq -e '.version >= 1 and (.rules | type == "array") and (.rules | length > 0)' "$store_path" > /dev/null \
  || { echo "ERROR: $url is not a valid sing-box source rule-set" >&2; exit 1; }

if [[ "$old_hash" == "$hash" ]]; then
  echo "pin already current: $hash"
  exit 0
fi

if [[ "$check_only" -eq 1 ]]; then
  echo "STALE: pin=$old_hash live=$hash" >&2
  echo "run update-geo-cn.sh (no --check) to bump, then follow the SHIP CHAIN in the header." >&2
  exit 2
fi

sed -i.bak "s|$old_hash|$hash|" "$pin_file"
rm -f "$pin_file.bak"
grep -qF "$hash" "$pin_file" \
  || { echo "ERROR: pin rewrite failed — $hash not present in $pin_file" >&2; exit 1; }
echo "bumped: $old_hash -> $hash"
echo "rules: $(jq '.rules | length' "$store_path"), size: $(wc -c < "$store_path") bytes"
echo "NOT SHIPPED YET — follow the SHIP CHAIN in this script's header."
