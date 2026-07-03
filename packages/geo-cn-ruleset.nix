# geo-cn-ruleset — CN geo rule-set (sing-box source format) from our geo-rules
# R2 cache, pinned at BUILD time so the data rides the closure.
#
# WHY build-time, not a remote rule_set: sing-box's remote type hard-fails
# startup whenever cache.db lacks the tag (first boot, cache wipe, corruption
# after an unclean kill) — a gateway's LAN DNS must come up unconditionally,
# with zero network dependency at sing-box-tproxy start. Proven live 2026-07-03
# (gateway-cq crash loop → :53 outage).
#
# The URL is mutable (every geo-rules deploy changes content) — bump the pin
# with packages/update-geo-cn.sh, which fails loud when R2 is unreachable.
{ fetchurl }:

fetchurl {
  name = "geo-cn.json";
  url = "https://rules.sui.pics/singbox/rule-sets/cn.json";
  hash = "sha256-7SBdx1kHxLfv/8tkCoGTPzCpmP972E3wpG61o4tL+SA=";
}
