# geo-cn-ruleset — CN geo rule-set (sing-box source format) from our geo-rules
# R2/CDN cache (rules.sui.pics), pinned at BUILD time so the data rides the
# closure.
#
# WHY build-time, not a remote rule_set: sing-box's remote type hard-fails
# startup whenever cache.db lacks the tag (first boot, cache wipe, corruption
# after an unclean kill) — a gateway's LAN DNS must come up unconditionally,
# with zero network dependency at sing-box-tproxy start. Proven live 2026-07-03
# (gateway-cq crash loop → :53 outage).
#
# WHY vendored: the CDN object is MUTABLE (every geo-rules deploy rewrites it in
# place), so a fetch of it under a fixed hash fails on any rebuild after the
# next publish. The pinned bytes live in this repo as geo-cn-raw.json.xz and
# build offline. `raw` is a fixed-output derivation with the name and hash a
# fetch of the same bytes would have, so its store path — and every path built
# from it — depends only on the bytes, not on where they come from.
#
# WHY validated at build: this wrapper rejects a well-formed-hash but
# structurally-wrong payload (empty rules, HTML error page, wrong schema) AT
# BUILD — so a bad publish can never reach sing-box and crash-loop :53.
#
# Bump the pin with packages/update-geo-cn.sh: it fetches the live object,
# validates it, re-vendors it and rewrites the hash (fails loud when R2 is
# unreachable; `--check` reports drift without editing).
{
  runCommand,
  jq,
  xz,
}:

let
  raw =
    runCommand "geo-cn-raw.json"
      {
        nativeBuildInputs = [ xz ];
        outputHashMode = "flat";
        outputHashAlgo = "sha256";
        outputHash = "sha256-OWQjGuJVTpMfqkG7YOAGow95rNvXbTNpV81E1uDiAzU=";
      }
      ''
        xz -dc ${./geo-cn-raw.json.xz} > "$out"
      '';
in
runCommand "geo-cn.json" { nativeBuildInputs = [ jq ]; } ''
  # Validate the fetched bytes are a real sing-box source rule-set (schema
  # version + a non-empty rules array). A structurally-wrong payload fails
  # HERE, at build, instead of crash-looping sing-box's :53 DNS at startup.
  jq -e '.version >= 1 and (.rules | type == "array") and (.rules | length > 0)' ${raw} > /dev/null \
    || { echo "geo-cn-ruleset: ${raw} is not a valid sing-box source rule-set" >&2; exit 1; }
  cp ${raw} "$out"
''
