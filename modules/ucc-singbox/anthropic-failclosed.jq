# Seat egress fails closed (ZT tg:13176, 13188): an account reaches Anthropic
# and OpenAI only through its own exit. sing-box routes each UCC profile by
# process_path_regex, one registry row per account. Right after the last of
# those rows, these rules catch what no row claimed:
#
# 1. A flow whose process lookup misses ("router: failed to search process")
#    or finds an owner with no path, on its way to Anthropic or OpenAI:
#    refused. A flow whose process was found goes on exactly as before,
#    through every later rule.
# 2. The ChatGPT account's OpenAI traffic from ucc-codex. ucc-codex runs on
#    UCC's shared node binary, which every UCC node script runs on too, so no
#    registry row can name it alone: sing-box matches the executable, not the
#    command line. The shared node under the home of the registry row for the
#    native codex binaries (`<home>/.codex/…`, the same account) takes that
#    row's outbound for OpenAI names; the shared node under any other home, or
#    with no such row, is refused for them. The node's other traffic is
#    unchanged.
# 3. A process in a UCC profile dir whose profile has no registry row, on its
#    way to Anthropic or OpenAI: refused, never sent through route.final.
# 4. A profile whose exit shares its IPv6 /64 with another account of the same
#    provider leaves on IPv4 alone: its IPv6 flows are refused right before its
#    own rule, so no provider sees two of its accounts on one /64.
#    briny_baron_16: ucc-soils29_eggcup's 2600:1901:8130:156::/64 also carries
#    mules_fated_7c, both Claude accounts.
#    blusher-83savvy: ucc-blusher-83savvy's 2600:1900:4090:30b::/64 is the
#    us-east4 exits' common /64; it also carries does_bannock_6u on the same
#    exit and the Claude accounts of the other us-east4 exits.
#
# Destinations: Anthropic's domains and the prefixes AS399358 announces;
# OpenAI's domains chatgpt.com and openai.com (Codex: chatgpt.com,
# ab.chatgpt.com, auth.openai.com, releases.openai.com), matched by the name
# the sniff rule reads, since OpenAI sits behind Cloudflare with no prefix of
# its own. A config with no profile rule is left as it is. Re-running the
# program replaces its own rules.
#
# The same program runs in osfiles modules/ucc-singbox/anthropic-failclosed.jq
# (the darwin and Foreign renders); keep the two identical.
{
  domain_suffix: ["anthropic.com", "claude.ai", "claude.com", "chatgpt.com", "openai.com"],
  ip_cidr: ["160.79.104.0/23", "2607:6bc0::/48", "2607:6bc0:11::/48"]
} as $ai
| { type: "logical", mode: "and", rules: [{ process_path_regex: [".*"], invert: true }, $ai], action: "reject" } as $failclosed
| "\\.local/share/ucc/shared/node/bin/node$" as $nodeTail
| { domain_suffix: ["chatgpt.com", "openai.com"] } as $openai
| ["/\\.local/share/ucc/profiles/"] as $profiles
| ["briny_baron_16", "blusher-83savvy"] as $v6only
| def ours: . == $failclosed
    or (.type == "logical" and (
      (.rules[0].process_path_regex == $profiles)
      or any(.rules[0].process_path_regex[]?; endswith($nodeTail))
      or (.rules[1] == { ip_version: 6 } and .action == "reject")));
  def v6only: .process_path_regex as $re
    | (.type | not) and $re != null
      and any($re[]; . as $r | any($v6only[]; . as $p | $r | contains("/ucc/profiles/" + $p + "/")));
  [(.route.rules // [])[] | select(ours | not)
   | if v6only
     then { type: "logical", mode: "and",
            rules: [{ process_path_regex: .process_path_regex }, { ip_version: 6 }],
            action: "reject" }, .
     else . end] as $base
| ([$base | to_entries[] | select(.value.process_path_regex) | .key] | max) as $last
| (first($base[] | select(any(.process_path_regex[]?; endswith("\\.codex/")))) // null) as $codex
| if $last == null then .
  else .route.rules = $base[0:$last + 1]
    + [$failclosed]
    + (if $codex then
        [{ type: "logical", mode: "and",
           rules: [{ process_path_regex: [first($codex.process_path_regex[] | select(endswith("\\.codex/")))
                                          | rtrimstr("\\.codex/") + $nodeTail] }, $openai],
           action: "route", outbound: $codex.outbound }]
      else [] end)
    + [
        { type: "logical", mode: "and", rules: [{ process_path_regex: ["/" + $nodeTail] }, $openai], action: "reject" },
        { type: "logical", mode: "and", rules: [{ process_path_regex: $profiles }, $ai], action: "reject" }
      ]
    + $base[$last + 1:]
  end
