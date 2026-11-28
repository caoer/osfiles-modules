#!/usr/bin/env bash
# modules/ucc-singbox/test-hot-reload.sh — automated verification suite for
# sing-box-ucc-ucc SIGHUP hot-reload classification, targeted per-profile reap
# hooks, restart fallback, rollback, and Claude 0-diff invariants.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
CLASSIFY_JQ="$SCRIPT_DIR/hot-reload-classify.jq"
MODULE_NIX="$SCRIPT_DIR/ucc-singbox.nixos.nix"

SCRATCH_ROOT="${SCRATCH_DIR:-${XDG_RUNTIME_DIR:-${HOME}/.cache}/ucc-singbox-hot-reload-test-$$}"
mkdir -p "$SCRATCH_ROOT"
WORK_DIR="$(mktemp -d "${SCRATCH_ROOT%/}/run.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

PASS_COUNT=0
pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS [%02d]: %s\n' "$PASS_COUNT" "$1"
}
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
assert_eq() {
  local got="$1" want="$2" label="$3"
  if [ "$got" != "$want" ]; then
    fail "$label: got='$got' want='$want'"
  fi
}
assert_contains() {
  local hay="$1" needle="$2" label="$3"
  case "$hay" in
    *"$needle"*) ;;
    *) fail "$label: expected substring '$needle' in '$hay'" ;;
  esac
}

# ── G1: Static Nix parse + module wiring assertions ──────────────────────────
if command -v nix-instantiate >/dev/null 2>&1; then
  nix-instantiate --parse "$MODULE_NIX" >/dev/null || fail "G1: nix-instantiate --parse failed"
  pass "G1a: nix-instantiate --parse ucc-singbox.nixos.nix clean"
fi

MODULE_SRC="$(cat "$MODULE_NIX")"
assert_contains "$MODULE_SRC" 'ExecReload = [' "G1b: ExecReload configured"
assert_contains "$MODULE_SRC" 'kill -HUP $MAINPID' "G1b: SIGHUP in ExecReload"
assert_contains "$MODULE_SRC" 'hot-reload-classify.jq' "G1b: classifier referenced"
assert_contains "$MODULE_SRC" 'onProfileRouteChange = lib.mkOption' "G1b: onProfileRouteChange option"
assert_contains "$MODULE_SRC" 'ExecStopPost = "+${tunCleanup}";' "G1b: ExecStopPost intact"
assert_contains "$MODULE_SRC" 'systemctl reload ${serviceName}.service' "G1b: systemctl reload wired"
pass "G1b: ucc-singbox.nixos.nix static wiring assertions passed"

# ── Base fixture modeled on live devstation-lax-2 config.json ────────────────
cat > "$WORK_DIR/base.json" <<'EOF'
{
  "log": { "level": "info", "timestamp": true },
  "dns": { "servers": [{ "type": "local", "tag": "local" }] },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "auto_route": true,
      "auto_redirect": false,
      "strict_route": false,
      "include_uid": [1000],
      "route_exclude_address": ["10.0.0.0/8", "127.0.0.0/8"]
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "shadowsocks", "tag": "relay-us", "server": "198.51.100.1", "server_port": 443 },
    { "type": "shadowsocks", "tag": "ucc-claude-1", "server": "203.0.113.10", "server_port": 23050 },
    { "type": "shadowsocks", "tag": "ucc-agy-exit-caoer116", "server": "203.0.113.116", "server_port": 23050 },
    { "type": "shadowsocks", "tag": "ucc-agy-exit-acct6", "server": "35.243.201.53", "server_port": 23050 },
    { "type": "shadowsocks", "tag": "ucc-agy-exit-izume", "server": "203.0.113.200", "server_port": 23050, "detour": "relay-us" }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": "local",
    "final": "direct",
    "find_process": true,
    "rules": [
      { "action": "sniff" },
      { "action": "hijack-dns", "protocol": "dns" },
      { "action": "reject", "ip_cidr": ["127.0.0.0/8", "::1/128"] },
      {
        "action": "reject",
        "process_path_regex": ["/\\.local/share/ucc/profiles/[^/]+/libexec/(antigravity|agy)$"],
        "domain_suffix": ["oauth2.googleapis.com"]
      },
      {
        "action": "route",
        "outbound": "ucc-claude-1",
        "process_path_regex": ["\\.local/share/ucc/profiles/crusted_standby_0n/"]
      },
      {
        "action": "route",
        "outbound": "ucc-agy-exit-caoer116",
        "process_path_regex": ["\\.local/share/ucc/profiles/agy-caoer116/"]
      },
      {
        "action": "route",
        "outbound": "ucc-agy-exit-acct6",
        "process_path_regex": ["\\.local/share/ucc/profiles/agy-caoer118/"]
      },
      {
        "action": "route",
        "outbound": "ucc-agy-exit-acct6",
        "process_path_regex": ["\\.local/share/ucc/profiles/agy-cosztm/"]
      },
      {
        "action": "route",
        "outbound": "ucc-agy-exit-izume",
        "process_path_regex": ["\\.local/share/ucc/profiles/agy-izume/"]
      },
      {
        "type": "logical",
        "mode": "and",
        "rules": [
          { "process_path_regex": [".*"], "invert": true },
          { "domain_suffix": ["cloudcode-pa.googleapis.com", "oauth2.googleapis.com"] }
        ],
        "action": "reject"
      },
      {
        "action": "reject",
        "process_path_regex": ["/\\.local/share/ucc/profiles/", "/\\.t3/tools/antigravity", "/antigravity$", "/agy$"],
        "domain_suffix": ["cloudcode-pa.googleapis.com", "oauth2.googleapis.com"]
      },
      {
        "action": "reject",
        "process_path_regex": [".*"],
        "domain_suffix": ["cloudcode-pa.googleapis.com"]
      },
      {
        "action": "route",
        "outbound": "direct",
        "process_path_regex": [".*"]
      }
    ]
  },
  "experimental": {
    "cache_file": { "enabled": true },
    "clash_api": { "external_controller": "127.0.0.1:9090" }
  }
}
EOF

classify() {
  jq -nc --slurpfile prev "$1" --slurpfile next "$2" -f "$CLASSIFY_JQ"
}

# ── T1: Add new Antigravity route + outbound → reload, reap=[] ───────────────
jq '
  .outbounds += [{ "type": "shadowsocks", "tag": "ucc-agy-exit-test", "server": "35.243.201.53", "server_port": 23051 }]
  | .route.rules = .route.rules[0:9]
    + [{ "action": "route", "outbound": "ucc-agy-exit-test", "process_path_regex": ["\\.local/share/ucc/profiles/agy-hotreload-test/"] }]
    + .route.rules[9:]
' "$WORK_DIR/base.json" > "$WORK_DIR/add.json"

OUT="$(classify "$WORK_DIR/base.json" "$WORK_DIR/add.json")"
assert_eq "$(jq -r '.action' <<< "$OUT")" "reload" "T1 action"
assert_eq "$(jq -c '.reasons' <<< "$OUT")" "[]" "T1 reasons"
assert_eq "$(jq -c '.reap_profiles' <<< "$OUT")" "[]" "T1 reap_profiles"
pass "T1: add brand-new Antigravity route + outbound -> reload with reap_profiles=[]"

# ── T2: Remove Antigravity route + outbound → reload, reap=[removed only] ────
OUT="$(classify "$WORK_DIR/add.json" "$WORK_DIR/base.json")"
assert_eq "$(jq -r '.action' <<< "$OUT")" "reload" "T2 action"
assert_eq "$(jq -c '.reap_profiles' <<< "$OUT")" '["agy-hotreload-test"]' "T2 reap_profiles"
pass "T2: remove Antigravity route + outbound -> reload with reap_profiles=[agy-hotreload-test]"

# ── T3: Rebind existing profile to different outbound tag ────────────────────
jq '
  (.route.rules[] | select((.process_path_regex // []) | index("\\.local/share/ucc/profiles/agy-caoer118/"))).outbound = "ucc-agy-exit-caoer116"
' "$WORK_DIR/base.json" > "$WORK_DIR/rebind.json"

OUT="$(classify "$WORK_DIR/base.json" "$WORK_DIR/rebind.json")"
assert_eq "$(jq -r '.action' <<< "$OUT")" "reload" "T3 action"
assert_eq "$(jq -c '.reap_profiles' <<< "$OUT")" '["agy-caoer118"]' "T3 reap_profiles"
pass "T3: rebind agy-caoer118 outbound tag -> reload with reap_profiles=[agy-caoer118]"

# ── T4: Mutate outbound server/port under same tag ───────────────────────────
jq '
  (.outbounds[] | select(.tag == "ucc-agy-exit-acct6")).server = "35.243.201.99"
' "$WORK_DIR/base.json" > "$WORK_DIR/outbound-mutate.json"

OUT="$(classify "$WORK_DIR/base.json" "$WORK_DIR/outbound-mutate.json")"
assert_eq "$(jq -r '.action' <<< "$OUT")" "reload" "T4 action"
assert_eq "$(jq -c '.reap_profiles' <<< "$OUT")" '["agy-caoer118","agy-cosztm"]' "T4 reap_profiles"
pass "T4: mutate shared outbound definition -> reload with reap_profiles=[agy-caoer118,agy-cosztm]"

# ── T5: Mutate detour relay outbound referenced by agy-izume ─────────────────
jq '
  (.outbounds[] | select(.tag == "relay-us")).server_port = 8443
' "$WORK_DIR/base.json" > "$WORK_DIR/detour-mutate.json"

OUT="$(classify "$WORK_DIR/base.json" "$WORK_DIR/detour-mutate.json")"
assert_eq "$(jq -r '.action' <<< "$OUT")" "reload" "T5 action"
assert_eq "$(jq -c '.reap_profiles' <<< "$OUT")" '["agy-izume"]' "T5 reap_profiles"
pass "T5: mutate detour relay -> reload with reap_profiles=[agy-izume]"

# ── T6: Toggle per-profile logical v6guard rule ──────────────────────────────
jq '
  .route.rules = [
    {
      "type": "logical",
      "mode": "and",
      "rules": [
        { "process_path_regex": ["\\.local/share/ucc/profiles/agy-izume/"] },
        { "ip_is_private": true, "invert": true },
        { "port": [53], "invert": true },
        { "ip_version": 6 }
      ],
      "action": "reject"
    }
  ] + .route.rules
' "$WORK_DIR/base.json" > "$WORK_DIR/v6guard.json"

OUT="$(classify "$WORK_DIR/base.json" "$WORK_DIR/v6guard.json")"
assert_eq "$(jq -r '.action' <<< "$OUT")" "reload" "T6 action"
assert_eq "$(jq -c '.reap_profiles' <<< "$OUT")" '["agy-izume"]' "T6 reap_profiles"
pass "T6: add v6guard for agy-izume -> reload with reap_profiles=[agy-izume]"

# ── T7-T12: Structural changes MUST force full restart ───────────────────────
jq '.inbounds[0].include_uid = [1000, 1001]' "$WORK_DIR/base.json" > "$WORK_DIR/inbounds.json"
OUT="$(classify "$WORK_DIR/base.json" "$WORK_DIR/inbounds.json")"
assert_eq "$(jq -r '.action' <<< "$OUT")" "restart" "T7 action"
assert_eq "$(jq -c '.reasons' <<< "$OUT")" '["inbounds"]' "T7 reasons"
assert_eq "$(jq -c '.reap_profiles' <<< "$OUT")" '[]' "T7 reap_profiles"

jq '.dns.servers += [{ "type": "https", "tag": "cf", "server": "1.1.1.1" }]' "$WORK_DIR/base.json" > "$WORK_DIR/dns.json"
OUT="$(classify "$WORK_DIR/base.json" "$WORK_DIR/dns.json")"
assert_eq "$(jq -r '.action' <<< "$OUT")" "restart" "T8 action"
assert_eq "$(jq -c '.reasons' <<< "$OUT")" '["dns"]' "T8 reasons"

jq '.experimental.clash_api.external_controller = "127.0.0.1:9091"' "$WORK_DIR/base.json" > "$WORK_DIR/exp.json"
OUT="$(classify "$WORK_DIR/base.json" "$WORK_DIR/exp.json")"
assert_eq "$(jq -r '.action' <<< "$OUT")" "restart" "T9 action"
assert_eq "$(jq -c '.reasons' <<< "$OUT")" '["experimental"]' "T9 reasons"

jq '.log.level = "debug"' "$WORK_DIR/base.json" > "$WORK_DIR/log.json"
OUT="$(classify "$WORK_DIR/base.json" "$WORK_DIR/log.json")"
assert_eq "$(jq -r '.action' <<< "$OUT")" "restart" "T10 action"
assert_eq "$(jq -c '.reasons' <<< "$OUT")" '["log"]' "T10 reasons"

jq '.route.final = "lan-proxy"' "$WORK_DIR/base.json" > "$WORK_DIR/route-final.json"
OUT="$(classify "$WORK_DIR/base.json" "$WORK_DIR/route-final.json")"
assert_eq "$(jq -r '.action' <<< "$OUT")" "restart" "T11 action"
assert_eq "$(jq -c '.reasons' <<< "$OUT")" '["route.final"]' "T11 reasons"

jq '.ntp = { "enabled": true, "server": "time.apple.com" }' "$WORK_DIR/base.json" > "$WORK_DIR/ntp.json"
OUT="$(classify "$WORK_DIR/base.json" "$WORK_DIR/ntp.json")"
assert_eq "$(jq -r '.action' <<< "$OUT")" "restart" "T12 action"
assert_eq "$(jq -c '.reasons' <<< "$OUT")" '["ntp"]' "T12 reasons"
pass "T7-T12: structural changes (inbounds/dns/experimental/log/route.final/ntp) force restart"

# ── T13: Regex safety + Claude 0-diff invariant ──────────────────────────────
CLAUDE_BEFORE="$(jq -c '[.route.rules[] | select((.process_path_regex // []) | any(contains("crusted_standby_0n")))]' "$WORK_DIR/base.json")"
CLAUDE_AFTER="$(jq -c '[.route.rules[] | select((.process_path_regex // []) | any(contains("crusted_standby_0n")))]' "$WORK_DIR/add.json")"
assert_eq "$CLAUDE_BEFORE" "$CLAUDE_AFTER" "T13 Claude route 0-diff"
OUT_REMOVE="$(classify "$WORK_DIR/add.json" "$WORK_DIR/base.json")"
case "$OUT_REMOVE" in
  *crusted_standby_0n*|*"[^"*) fail "T13: bogus or Claude slug leaked into reap_profiles: $OUT_REMOVE" ;;
esac
pass "T13: regex safety (oauth_hard_lock wildcard ignored) and Claude 0-diff verified"

# ── S1-S6: End-to-end configScript update harness with stubbed systemd/curl ──
HARNESS="$WORK_DIR/run-update.sh"
cat > "$HARNESS" <<EOF_HARNESS
#!/usr/bin/env bash
set -eu
mode="update"
result="\$1"
state="\$TEST_STATE"
stamp="renderer-v1"
say() { echo "sing-box-ucc-ucc: \$*" >&2; }
report() { if [ -n "\$result" ]; then printf '%s\n' "\$*" > "\$result"; fi; }
fail() { say "\$*"; report "failed \$*"; exit 1; }

mkdir -p -m 0700 "\$state"
work="\$(mktemp -d "\$state/.next.XXXXXX")"
trap 'rm -rf "\$work"' EXIT

fetch() { cp "\$TEST_NEXT_RAW" "\$work/raw.json"; }
render() { cp "\$TEST_NEXT_CFG" "\$work/config.json"; }
install_candidate() {
  printf '%s\n' "\$stamp" > "\$work/render.id"
  mv -f "\$work/config.json" "\$state/config.json"
  mv -f "\$work/raw.json" "\$state/raw.json"
  mv -f "\$work/render.id" "\$state/render.id"
}
same_renderer() { [ "\$(cat "\$state/render.id" 2>/dev/null || true)" = "\$stamp" ]; }
egress() {
  "\$TEST_EGRESS_BIN"
}
worse() {
  set -- \$1 \$2
  w=""
  if [ "\${1:-}" = active ] && [ "\${4:-}" != active ]; then w="router \${4:-?}"; fi
  if [ "\${2:-}" = 204 ] && [ "\${5:-}" != 204 ]; then w="\${w:+\$w, }google \${5:-?}"; fi
  if [ "\${3:-}" = 000 ] && [ "\${6:-}" != 000 ]; then w="\${w:+\$w, }anthropic reached (\${6:-?})"; fi
  printf '%s' "\$w"
}

fetch || fail "fetch failed"
if [ -s "\$state/config.json" ] && same_renderer && cmp -s "\$work/raw.json" "\$state/raw.json"; then
  report unchanged
  exit 0
fi
candidate="\$({ sha256sum < "\$work/raw.json"; printf '%s\n' "\$stamp"; } | sha256sum | cut -c1-64)"
if [ "\$(cat "\$state/rejected" 2>/dev/null || true)" = "\$candidate" ]; then
  fail "already rejected"
fi
render || fail "render failed"
before="\$(egress)"
mkdir "\$work/prev"
for f in config.json raw.json render.id; do
  if [ -e "\$state/\$f" ]; then cp -p "\$state/\$f" "\$work/prev/\$f"; fi
done

apply_mode="restart"
apply_reason="no previous config or router not active"
reap_profiles=""
if [ -s "\$work/prev/config.json" ] && "\$TEST_SYSTEMCTL" is-active --quiet sing-box-ucc-ucc.service; then
  if jq -n --slurpfile prev "\$work/prev/config.json" --slurpfile next "\$work/config.json" -f "$CLASSIFY_JQ" > "\$work/classify.json"; then
    apply_mode="\$(jq -r '.action // "restart"' "\$work/classify.json")"
    apply_reason="\$(jq -r '(.reasons // []) | join(",")' "\$work/classify.json")"
    reap_profiles="\$(jq -r '(.reap_profiles // [])[]' "\$work/classify.json")"
  else
    apply_mode="restart"
    apply_reason="classifier-error"
  fi
fi

install_candidate

check_egress() {
  why="" after=""
  for i in 1 2 3 4; do
    after="\$(egress)"
    why="\$(worse "\$before" "\$after")"
    case "\$why" in "" | *anthropic*) break ;; esac
  done
}

used_reload=0
if [ "\$apply_mode" = "reload" ]; then
  if "\$TEST_SYSTEMCTL" reload sing-box-ucc-ucc.service; then
    used_reload=1
    check_egress
  else
    apply_mode="restart"
    apply_reason="reload-failed"
  fi
fi

if [ "\$apply_mode" != "reload" ]; then
  if "\$TEST_SYSTEMCTL" restart sing-box-ucc-ucc.service; then
    check_egress
  else
    after="restart failed"
    why="sing-box-ucc-ucc failed to restart"
  fi
fi

if [ -z "\$why" ]; then
  if [ "\$used_reload" = 1 ] && [ -n "\$reap_profiles" ]; then
    while IFS= read -r slug; do
      [ -n "\$slug" ] || continue
      "\$TEST_REAP_HOOK" "\$slug" || true
    done <<EOF_REAP
\$reap_profiles
EOF_REAP
  fi
  rm -f "\$state/rejected" "\$state/rejected.why"
  report applied
  exit 0
fi

mv -f "\$work/prev/config.json" "\$state/config.json"
if [ -e "\$work/prev/raw.json" ]; then mv -f "\$work/prev/raw.json" "\$state/raw.json"; fi
printf '%s\n' "\$stamp" > "\$state/render.id"
printf '%s\n' "\$candidate" > "\$state/rejected"
printf '%s\n' "\$why" > "\$state/rejected.why"
"\$TEST_SYSTEMCTL" restart sing-box-ucc-ucc.service || fail "rollback restart failed"
fail "\$why — rolled back"
EOF_HARNESS
chmod +x "$HARNESS"

setup_case() {
  local name="$1" prev_cfg="$2" next_cfg="$3" is_active="$4" reload_rc="$5" egress_after="$6"
  local dir="$WORK_DIR/case-$name"
  mkdir -p "$dir/state"
  cp "$prev_cfg" "$dir/state/config.json"
  printf 'raw-prev-%s\n' "$name" > "$dir/state/raw.json"
  printf 'renderer-v1\n' > "$dir/state/render.id"
  printf 'raw-next-%s\n' "$name" > "$dir/next.raw"
  cp "$next_cfg" "$dir/next.cfg"
  : > "$dir/systemctl.log"
  : > "$dir/reap.log"
  printf '0\n' > "$dir/egress.count"

  cat > "$dir/systemctl" <<EOF_SC
#!/usr/bin/env bash
echo "\$*" >> "$dir/systemctl.log"
case "\$1" in
  is-active) exit $is_active ;;
  reload) exit $reload_rc ;;
  restart) exit 0 ;;
esac
EOF_SC
  chmod +x "$dir/systemctl"

  cat > "$dir/egress" <<EOF_EG
#!/usr/bin/env bash
c="\$(cat "$dir/egress.count")"
c=\$((c + 1))
printf '%s\n' "\$c" > "$dir/egress.count"
if [ "\$c" -eq 1 ]; then
  echo "active 204 000"
else
  echo "$egress_after"
fi
EOF_EG
  chmod +x "$dir/egress"

  cat > "$dir/reap" <<EOF_RP
#!/usr/bin/env bash
echo "\$1" >> "$dir/reap.log"
EOF_RP
  chmod +x "$dir/reap"

  TEST_STATE="$dir/state" \
  TEST_NEXT_RAW="$dir/next.raw" \
  TEST_NEXT_CFG="$dir/next.cfg" \
  TEST_SYSTEMCTL="$dir/systemctl" \
  TEST_EGRESS_BIN="$dir/egress" \
  TEST_REAP_HOOK="$dir/reap" \
  "$HARNESS" "$dir/result" 2>"$dir/stderr.log" || true
}

# S1: Route add -> reload, 0 restarts, 0 reaps
setup_case s1 "$WORK_DIR/base.json" "$WORK_DIR/add.json" 0 0 "active 204 000"
assert_eq "$(cat "$WORK_DIR/case-s1/result")" "applied" "S1 result"
assert_contains "$(cat "$WORK_DIR/case-s1/systemctl.log")" "reload sing-box-ucc-ucc.service" "S1 reload"
if grep -q "restart" "$WORK_DIR/case-s1/systemctl.log"; then fail "S1 unexpectedly restarted"; fi
assert_eq "$(wc -l < "$WORK_DIR/case-s1/reap.log" | tr -d ' ')" "0" "S1 reap count"
pass "S1: route add -> systemctl reload, 0 restarts, 0 reaps"

# S2: Route remove -> reload, targeted reap only
setup_case s2 "$WORK_DIR/add.json" "$WORK_DIR/base.json" 0 0 "active 204 000"
assert_eq "$(cat "$WORK_DIR/case-s2/result")" "applied" "S2 result"
assert_contains "$(cat "$WORK_DIR/case-s2/systemctl.log")" "reload sing-box-ucc-ucc.service" "S2 reload"
if grep -q "restart" "$WORK_DIR/case-s2/systemctl.log"; then fail "S2 unexpectedly restarted"; fi
assert_eq "$(cat "$WORK_DIR/case-s2/reap.log")" "agy-hotreload-test" "S2 reap target"
pass "S2: route remove -> systemctl reload + targeted reap of agy-hotreload-test only"

# S3: Inbound change -> full restart
setup_case s3 "$WORK_DIR/base.json" "$WORK_DIR/inbounds.json" 0 0 "active 204 000"
assert_eq "$(cat "$WORK_DIR/case-s3/result")" "applied" "S3 result"
assert_contains "$(cat "$WORK_DIR/case-s3/systemctl.log")" "restart sing-box-ucc-ucc.service" "S3 restart"
if grep -q "reload" "$WORK_DIR/case-s3/systemctl.log"; then fail "S3 unexpectedly reloaded"; fi
pass "S3: inbound change -> full systemctl restart"

# S4: Reload fails -> fallback to full restart
setup_case s4 "$WORK_DIR/base.json" "$WORK_DIR/add.json" 0 1 "active 204 000"
assert_eq "$(cat "$WORK_DIR/case-s4/result")" "applied" "S4 result"
assert_contains "$(cat "$WORK_DIR/case-s4/systemctl.log")" "reload sing-box-ucc-ucc.service" "S4 attempted reload"
assert_contains "$(cat "$WORK_DIR/case-s4/systemctl.log")" "restart sing-box-ucc-ucc.service" "S4 fallback restart"
pass "S4: systemctl reload failure -> falls back to full systemctl restart"

# S5: Egress degrades after reload -> rollback + full restart + rejected stamp
setup_case s5 "$WORK_DIR/base.json" "$WORK_DIR/add.json" 0 0 "active 000 000"
assert_contains "$(cat "$WORK_DIR/case-s5/result")" "rolled back" "S5 rollback result"
assert_contains "$(cat "$WORK_DIR/case-s5/systemctl.log")" "reload sing-box-ucc-ucc.service" "S5 reload first"
assert_contains "$(cat "$WORK_DIR/case-s5/systemctl.log")" "restart sing-box-ucc-ucc.service" "S5 rollback restart"
cmp -s "$WORK_DIR/base.json" "$WORK_DIR/case-s5/state/config.json" || fail "S5 config not restored"
[ -s "$WORK_DIR/case-s5/state/rejected" ] || fail "S5 rejected stamp missing"
assert_eq "$(wc -l < "$WORK_DIR/case-s5/reap.log" | tr -d ' ')" "0" "S5 no targeted reap on rollback"
pass "S5: post-reload egress degradation -> restores prev config + full restart + rejected"

# S6: Service inactive -> direct full restart
setup_case s6 "$WORK_DIR/base.json" "$WORK_DIR/add.json" 3 0 "active 204 000"
assert_eq "$(cat "$WORK_DIR/case-s6/result")" "applied" "S6 result"
assert_contains "$(cat "$WORK_DIR/case-s6/systemctl.log")" "restart sing-box-ucc-ucc.service" "S6 restart"
if grep -q "reload" "$WORK_DIR/case-s6/systemctl.log"; then fail "S6 unexpectedly reloaded while inactive"; fi
pass "S6: inactive service -> direct full systemctl restart"

# ── G4: Claude 0-diff repo check ─────────────────────────────────────────────
if git -C "$REPO_ROOT" rev-parse --verify origin/main >/dev/null 2>&1; then
  CLAUDE_DIFF="$(
    git -C "$REPO_ROOT" diff origin/main...HEAD -- modules/ucc-singbox/anthropic-failclosed.jq modules/ucc-singbox/failclosed-hold.jq
    git -C "$REPO_ROOT" diff -- modules/ucc-singbox/anthropic-failclosed.jq modules/ucc-singbox/failclosed-hold.jq
    git -C "$REPO_ROOT" diff --cached -- modules/ucc-singbox/anthropic-failclosed.jq modules/ucc-singbox/failclosed-hold.jq
  )"
  [ -z "$CLAUDE_DIFF" ] || fail "G4: unexpected diff in anthropic-failclosed.jq / failclosed-hold.jq"
  pass "G4: zero diffs on anthropic-failclosed.jq and failclosed-hold.jq"
fi

printf '\nALL HOT-RELOAD CHECKS PASSED (%d checks)\n' "$PASS_COUNT"
