# Seat egress fails closed (ZT tg:13176, 13188): an account reaches Anthropic
# and OpenAI only through its own exit. sing-box routes each UCC profile by
# process_path_regex; a flow whose process lookup misses ("router: failed to
# search process") or finds an owner with no path matches no profile rule and
# falls through to the rules below and route.final — on tun-us that is the
# host's own address. Right after the last profile rule, such a flow to
# Anthropic or OpenAI is refused. A flow whose process was found goes on exactly as
# before, through every later rule. Destinations: Anthropic's domains and the
# prefixes AS399358 announces; OpenAI's domains chatgpt.com and openai.com
# (Codex: chatgpt.com, ab.chatgpt.com, auth.openai.com, releases.openai.com),
# matched by the name the sniff rule reads, since OpenAI sits behind Cloudflare
# with no prefix of its own. A config with no profile rule is left as it is.
#
# The same program runs in osfiles modules/ucc-singbox/anthropic-failclosed.jq
# (the darwin and Foreign renders); keep the two identical.
{
  type: "logical",
  mode: "and",
  rules: [
    { process_path_regex: [".*"], invert: true },
    {
      domain_suffix: ["anthropic.com", "claude.ai", "claude.com", "chatgpt.com", "openai.com"],
      ip_cidr: ["160.79.104.0/23", "2607:6bc0::/48", "2607:6bc0:11::/48"]
    }
  ],
  action: "reject"
} as $failclosed
| ([(.route.rules // []) | to_entries[] | select(.value.process_path_regex) | .key] | max) as $last
| if $last == null or any(.route.rules[]; . == $failclosed) then .
  else .route.rules |= .[0:$last + 1] + [$failclosed] + .[$last + 1:]
  end
