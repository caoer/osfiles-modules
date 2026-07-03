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
# WHY validated at build: the pinned bytes come from a MUTABLE URL (every
# geo-rules deploy rewrites the object in place). A hash mismatch already fails
# the build loudly; this wrapper additionally rejects a well-formed-hash but
# structurally-wrong payload (empty rules, HTML error page, wrong schema) AT
# BUILD — so a bad publish can never reach sing-box and crash-loop :53. Moving
# the loud-failure contract from runtime (script-only) into the build closure.
#
# Bump the pin with packages/update-geo-cn.sh (fails loud when R2 is
# unreachable; `--check` reports drift without editing).
{
  fetchurl,
  runCommand,
  jq,
}:

let
  raw = fetchurl {
    name = "geo-cn-raw.json";
    url = "https://rules.sui.pics/singbox/rule-sets/cn.json";
    hash = "sha256-7SBdx1kHxLfv/8tkCoGTPzCpmP972E3wpG61o4tL+SA=";
  };
in
runCommand "geo-cn.json" { nativeBuildInputs = [ jq ]; } ''
  # Validate the fetched bytes are a real sing-box source rule-set (schema
  # version + a non-empty rules array). A structurally-wrong payload fails
  # HERE, at build, instead of crash-looping sing-box's :53 DNS at startup.
  jq -e '.version >= 1 and (.rules | type == "array") and (.rules | length > 0)' ${raw} > /dev/null \
    || { echo "geo-cn-ruleset: ${raw} is not a valid sing-box source rule-set" >&2; exit 1; }
  cp ${raw} "$out"
''
