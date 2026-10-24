# Seat egress fails closed (ZT tg:13176, 13188): an account reaches Anthropic
# and OpenAI only through its own exit. sing-box routes each UCC profile by
# process_path_regex, one registry row per account. Right after the last of
# those rows, three rules catch what no row claimed:
#
# 1. A flow whose process lookup misses ("router: failed to search process")
#    or finds an owner with no path, on its way to Anthropic or OpenAI:
#    refused. A flow whose process was found goes on exactly as before,
#    through every later rule.
# 2. The ChatGPT account's OpenAI traffic from ucc-codex. ucc-codex runs on
#    UCC's shared node binary, which every UCC node script runs on too, so no
#    registry row can name it alone: sing-box matches the executable, not the
#    command line. Its OpenAI names take the outbound of the registry row for
#    the native codex binaries (`~/.codex/…`, the same account); with no such
#    row they are refused. The node's other traffic is unchanged.
# 3. A process in a UCC profile dir whose profile has no registry row, on its
#    way to Anthropic or OpenAI: refused, never sent through route.final.
#
# Destinations: Anthropic's domains and the prefixes AS399358 announces;
# OpenAI's domains chatgpt.com and openai.com (Codex: chatgpt.com,
# ab.chatgpt.com, auth.openai.com, releases.openai.com), matched by the name
# the sniff rule reads, since OpenAI sits behind Cloudflare with no prefix of
# its own. A config with no profile rule is left as it is. Re-running the
# program replaces its own three rules.
#
# The same program runs in osfiles modules/ucc-singbox/anthropic-failclosed.jq
# (the darwin and Foreign renders); keep the two identical.
{
  domain_suffix: ["anthropic.com", "claude.ai", "claude.com", "chatgpt.com", "openai.com"],
  ip_cidr: ["160.79.104.0/23", "2607:6bc0::/48", "2607:6bc0:11::/48"]
} as $ai
| { type: "logical", mode: "and", rules: [{ process_path_regex: [".*"], invert: true }, $ai], action: "reject" } as $failclosed
| ["/\\.local/share/ucc/shared/node/bin/node$"] as $node
| ["/\\.local/share/ucc/profiles/"] as $profiles
| [(.route.rules // [])[]
    | select(. != $failclosed and .process_path_regex != $node and .process_path_regex != $profiles)] as $base
| ([$base | to_entries[] | select(.value.process_path_regex) | .key] | max) as $last
| (first($base[] | select(any(.process_path_regex[]?; endswith("\\.codex/"))) | .outbound) // null) as $codex
| if $last == null then .
  else .route.rules = $base[0:$last + 1]
    + [
        $failclosed,
        ({ process_path_regex: $node, domain_suffix: ["chatgpt.com", "openai.com"] }
          + if $codex then { action: "route", outbound: $codex } else { action: "reject" } end),
        ({ process_path_regex: $profiles } + $ai + { action: "reject" })
      ]
    + $base[$last + 1:]
  end
