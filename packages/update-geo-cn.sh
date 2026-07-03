#!/usr/bin/env bash
# update-geo-cn.sh — bump the pinned geo-cn rule-set hash from the R2 cache.
#
# LOUD FAILURE CONTRACT: any error (R2 unreachable, bad JSON, not a sing-box
# source rule-set) aborts with a non-zero exit and leaves the pin UNCHANGED.
# There is deliberately no fallback to the previous/vendored content — a stale
# pin must be a visible failure, not a silent success.
set -euo pipefail

url="https://rules.sui.pics/singbox/rule-sets/cn.json"
pin_file="$(cd "$(dirname "$0")" && pwd)/geo-cn-ruleset.nix"

echo "prefetching $url ..."
prefetch_json=$(nix store prefetch-file --json "$url")
hash=$(echo "$prefetch_json" | jq -er .hash)
store_path=$(echo "$prefetch_json" | jq -er .storePath)

# Validate: sing-box source-format rule-set (version + rules present).
jq -e '.version >= 1 and (.rules | length > 0)' "$store_path" > /dev/null \
  || { echo "ERROR: $url is not a valid sing-box source rule-set" >&2; exit 1; }

old_hash=$(grep -o 'sha256-[A-Za-z0-9+/=]*' "$pin_file")
if [[ "$old_hash" == "$hash" ]]; then
  echo "pin already current: $hash"
  exit 0
fi

sed -i.bak "s|$old_hash|$hash|" "$pin_file"
rm -f "$pin_file.bak"
echo "bumped: $old_hash -> $hash"
echo "rules: $(jq '.rules | length' "$store_path"), size: $(wc -c < "$store_path") bytes"
echo "commit $pin_file to ship the new pin."
