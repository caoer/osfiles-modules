# The fail-closed a renderer-hold host renders (osf.uccSingbox.failClosed
# off: the seat desks), in place of ./anthropic-failclosed.jq's rules apart
# from its IPv6 guards. It is the shape devstation-lax-1 ran under seat load
# and kept on 10-24, and the program of the /run drop-in it replaces
# (sing-box-ucc-ucc.service.d/50-anthropic-failclosed.conf → patch.sh v3).
# Right after the last per-profile process rule:
#
# 1. UCC's shared node binary under the routed user's home, to chatgpt.com
#    and openai.com: through "🛸 ucc-hoots_scarabs29", the ChatGPT account
#    ucc-codex runs as (SA ruling, 10-24). ucc-codex runs on that binary,
#    which every UCC node script runs on too, so no registry row can name it.
#    Rendered only when the config has that outbound; never adds one.
# 2. Anthropic's domains and prefixes: refused. A process no registry row
#    claimed and a process lookup miss reach Anthropic only as a refusal,
#    never from the host's own address.
# 3. Any process sing-box found: direct.
#
# A config with no profile rule is left as it is. Re-running the program
# replaces its own rules wherever they sit, so the /run patch.sh v3 run on
# top of this render rewrites it to the same bytes.
#
# --arg home: the routed user's home (osf.uccSingbox.user).
"🛸 ucc-hoots_scarabs29" as $hoots
| ($ARGS.named.home | gsub("(?<c>[.^$*+?()\\[\\]{}|\\\\])"; "\\\(.c)"))
  + "/\\.local/share/ucc/shared/node/bin/node$" as $node
| { action: "route", process_path_regex: [$node],
    domain_suffix: ["chatgpt.com", "openai.com"], outbound: $hoots } as $codex
| { action: "reject", domain_suffix: ["anthropic.com", "claude.ai", "claude.com"],
    ip_cidr: ["160.79.104.0/24", "2607:6bc0::/48"] } as $anthropic
| { action: "route", process_path_regex: [".*"], outbound: "direct" } as $found
| any(.outbounds[]?; .tag == $hoots) as $haveHoots
| [(.route.rules // [])[] | select(. != $codex and . != $anthropic and . != $found)] as $base
| ([$base | to_entries[] | select(.value.process_path_regex) | .key] | max) as $last
| if $last == null then .
  else .route.rules = $base[0:$last + 1]
    + (if $haveHoots then [$codex] else [] end)
    + [$anthropic, $found]
    + $base[$last + 1:]
  end
