# modules/ucc-singbox/hot-reload-classify.jq — classify a sing-box config.json
# transition (`$prev[0]` -> `$next[0]`) as either in-place `SIGHUP` reload or
# full `systemctl restart`, and identify any existing profile routes removed or
# rebound to a different exit/outbound definition so callers can reap ONLY
# those affected profiles without touching unrelated live seats.
#
# Invocation:
#   jq -n --slurpfile prev prev.json --slurpfile next next.json \
#      -f hot-reload-classify.jq
#
# Output JSON:
#   {
#     "action": "reload" | "restart",
#     "reasons": [ ... ],          # non-empty iff action == "restart"
#     "reap_profiles": [ ... ]     # sorted unique profile slugs to reap on reload
#   }

($prev[0] // null) as $p
| ($next[0] // null) as $n
| if ($p | type) != "object" or ($n | type) != "object" then
    { action: "restart", reasons: ["invalid-config"], reap_profiles: [] }
  else
    def structural:
      del(.outbounds, .endpoints)
      | if (.route | type) == "object" then .route |= del(.rules) else . end;

    def structural_diff_reasons($a; $b):
      ($a | structural) as $sa
      | ($b | structural) as $sb
      | [
          (($sa | keys) + ($sb | keys) | unique)[] as $k
          | if $k == "route" and ($sa.route | type) == "object" and ($sb.route | type) == "object" then
              (($sa.route | keys) + ($sb.route | keys) | unique)[] as $rk
              | select($sa.route[$rk] != $sb.route[$rk])
              | "route." + $rk
            else
              select($sa[$k] != $sb[$k])
              | $k
            end
        ];

    def outbound_index:
      [
        ((.outbounds // [])[] | select(type == "object" and (.tag | type) == "string") | { key: .tag, value: . }),
        ((.endpoints // [])[] | select(type == "object" and (.tag | type) == "string") | { key: .tag, value: . })
      ]
      | from_entries;

    def resolve_chain($idx; $tag; $seen):
      if ($tag | type) != "string" then
        null
      elif ($seen | index($tag)) != null then
        { cycle: $tag }
      else
        ($idx[$tag] // null) as $obj
        | if $obj == null then
            { missing: $tag }
          else
            (
              [
                (if ($obj.detour | type) == "string" then $obj.detour else empty end),
                (($obj.outbounds // [])[] | select(type == "string"))
              ]
              | unique
            ) as $refs
            | {
                obj: $obj,
                refs: [ $refs[] | resolve_chain($idx; .; $seen + [$tag]) ]
              }
          end
      end;

    def is_profile_route:
      (.type | not)
      and ((.process_path_regex | type) == "array")
      and (.action == null or .action == "route")
      and (.domain_suffix == null)
      and (.process_path_regex != [".*"]);

    # Strict concrete profile slug extractor: excludes wildcard regex patterns
    # such as `/\.local/share/ucc/profiles/[^/]+/libexec/(antigravity|agy)$`
    # and generic `/\.local/share/ucc/profiles/` catch-alls.
    def regex_profile_slugs:
      [
        .[]
        | select(type == "string")
        | scan("/ucc/profiles/([A-Za-z0-9][A-Za-z0-9._-]*)/")
        | .[0]
      ]
      | unique;

    def rule_profile_slugs:
      if is_profile_route then
        (.process_path_regex | regex_profile_slugs)
      elif .type == "logical" and (.rules | type) == "array" then
        [ .rules[] | select((.process_path_regex | type) == "array") | .process_path_regex | regex_profile_slugs[] ]
        | unique
      else
        []
      end;

    def profile_bindings:
      outbound_index as $idx
      | (.route.rules // []) as $rules
      | (
          [
            $rules[]
            | select(is_profile_route)
            | . as $r
            | ($r.process_path_regex | regex_profile_slugs)[] as $slug
            | {
                slug: $slug,
                binding: {
                  outbound: ($r.outbound // null),
                  chain: resolve_chain($idx; ($r.outbound // null); []),
                  process_path_regex: ($r.process_path_regex | sort)
                }
              }
          ]
          | group_by(.slug)
          | map({ key: .[0].slug, value: (map(.binding) | sort) })
          | from_entries
        ) as $routes
      | (
          [
            $rules[]
            | select((is_profile_route | not) and .type == "logical")
            | . as $r
            | ($r | rule_profile_slugs)[] as $slug
            | { slug: $slug, guard: $r }
          ]
          | group_by(.slug)
          | map({ key: .[0].slug, value: (map(.guard) | sort) })
          | from_entries
        ) as $guards
      | $routes
      | with_entries(.value = { routes: .value, guards: ($guards[.key] // []) });

    structural_diff_reasons($p; $n) as $reasons
    | if ($reasons | length) > 0 then
        {
          action: "restart",
          reasons: $reasons,
          reap_profiles: []
        }
      else
        ($p | profile_bindings) as $pb
        | ($n | profile_bindings) as $nb
        | [
            $pb | to_entries[]
            | select(($nb[.key] == null) or ($nb[.key] != .value))
            | .key
          ]
        | unique
        | sort as $reap
        | {
            action: "reload",
            reasons: [],
            reap_profiles: $reap
          }
      end
  end
