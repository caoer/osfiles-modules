#!/usr/bin/env bash
# modules/ucc-singbox/test-hot-reload.sh — automated verification suite for
# sing-box-ucc-ucc SIGHUP hot-reload classification, decoupled startScript /
# updateScript + zero-kill switch directives, real updateScript execution
# (flock 9 ordering, pre+post reap ordering, journald SIGHUP confirmation,
# restart fallback, rollback), and Claude 0-diff invariants.

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
assert_not_contains() {
  local hay="$1" needle="$2" label="$3"
  case "$hay" in
    *"$needle"*) fail "$label: unexpected substring '$needle'" ;;
    *) ;;
  esac
}
assert_line_order() {
  local file="$1" first="$2" second="$3" label="$4"
  local l1 l2
  l1="$(grep -n -F "$first" "$file" | head -n 1 | cut -d: -f1 || true)"
  l2="$(grep -n -F "$second" "$file" | head -n 1 | cut -d: -f1 || true)"
  [ -n "$l1" ] || fail "$label: missing first event '$first' in $file"
  [ -n "$l2" ] || fail "$label: missing second event '$second' in $file"
  [ "$l1" -lt "$l2" ] || fail "$label: expected '$first' (line $l1) before '$second' (line $l2) in $file"
}

# ── G1: Static Nix parse + decoupled script & zero-kill switch assertions ────
if command -v nix-instantiate >/dev/null 2>&1; then
  nix-instantiate --parse "$MODULE_NIX" >/dev/null || fail "G1: nix-instantiate --parse failed"
  pass "G1a: nix-instantiate --parse ucc-singbox.nixos.nix clean"
fi

MODULE_SRC="$(cat "$MODULE_NIX")"
assert_contains "$MODULE_SRC" 'restartIfChanged = false;' "G1b: restartIfChanged = false (P1-1)"
assert_contains "$MODULE_SRC" 'stopIfChanged = false;' "G1b: stopIfChanged = false (P1-1)"
assert_contains "$MODULE_SRC" 'startScript = pkgs.writeShellScript "${serviceName}-start"' "G1b: decoupled startScript"
assert_contains "$MODULE_SRC" 'updateScript = pkgs.writeShellScript "${serviceName}-update"' "G1b: decoupled updateScript"
assert_contains "$MODULE_SRC" '"${startScript}"' "G1b: ExecStartPre uses startScript"
assert_contains "$MODULE_SRC" 'ExecStart = "${updateScript}";' "G1b: -update service uses updateScript"
assert_contains "$MODULE_SRC" '${updateScript} "$res"' "G1b: fleetClient uses updateScript"
assert_contains "$MODULE_SRC" 'ExecReload = [' "G1b: ExecReload configured"
assert_contains "$MODULE_SRC" 'kill -HUP $MAINPID' "G1b: SIGHUP in ExecReload"
assert_contains "$MODULE_SRC" 'hot-reload-classify.jq' "G1b: classifier referenced"
assert_contains "$MODULE_SRC" 'onProfileRouteChange = lib.mkOption' "G1b: onProfileRouteChange option"
assert_contains "$MODULE_SRC" 'ExecStopPost = "+${tunCleanup}";' "G1b: ExecStopPost intact"
assert_contains "$MODULE_SRC" 'confirm_reload' "G1b: journald reload confirmation present (P2-3)"

# Verify startScript block itself NEVER references hot-reload-classify.jq or onProfileRouteChange.
START_BLOCK="$(awk '/startScript = pkgs\.writeShellScript/,/updateScript = pkgs\.writeShellScript/' "$MODULE_NIX")"
assert_not_contains "$START_BLOCK" 'hot-reload-classify.jq' "G1b: startScript must not reference hot-reload-classify.jq"
assert_not_contains "$START_BLOCK" 'onProfileRouteChange' "G1b: startScript must not reference onProfileRouteChange"
assert_not_contains "$START_BLOCK" 'systemctl' "G1b: startScript must not reference systemctl"
pass "G1b: decoupled startScript/updateScript + restartIfChanged=false/stopIfChanged=false assertions passed"

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
      "route_exclude_address": ["10.0.0.0/8", "127.0.0.0/8"],
      "exclude_interface": ["docker0"]
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
        "type": "logical",
        "mode": "and",
        "rules": [
          { "process_path_regex": ["/\\.local/share/ucc/profiles/agy-[^/]+/"] },
          { "ip_is_private": true, "invert": true }
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

jq '.inbounds[0].mtu = 1400' "$WORK_DIR/base.json" > "$WORK_DIR/inbounds-mtu.json"
OUT="$(classify "$WORK_DIR/base.json" "$WORK_DIR/inbounds-mtu.json")"
assert_eq "$(jq -r '.action' <<< "$OUT")" "restart" "T7b mtu action"
assert_eq "$(jq -c '.reasons' <<< "$OUT")" '["inbounds"]' "T7b mtu reasons"

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
pass "T7-T12: structural changes (inbounds/mtu/dns/experimental/log/route.final/ntp) force restart"

# ── T13: Regex safety + Claude 0-diff invariant ──────────────────────────────
CLAUDE_BEFORE="$(jq -c '[.route.rules[] | select((.process_path_regex // []) | any(contains("crusted_standby_0n")))]' "$WORK_DIR/base.json")"
CLAUDE_AFTER="$(jq -c '[.route.rules[] | select((.process_path_regex // []) | any(contains("crusted_standby_0n")))]' "$WORK_DIR/add.json")"
assert_eq "$CLAUDE_BEFORE" "$CLAUDE_AFTER" "T13 Claude route 0-diff"
OUT_REMOVE="$(classify "$WORK_DIR/add.json" "$WORK_DIR/base.json")"
case "$OUT_REMOVE" in
  *crusted_standby_0n*|*"[^"*) fail "T13: bogus or Claude slug leaked into reap_profiles: $OUT_REMOVE" ;;
esac
pass "T13: regex safety (oauth_hard_lock & unrouted_agy_egress wildcards ignored) and Claude 0-diff verified"

# ── T14 (P2-1): Escaped-dot profile slugs matched & unescaped; wildcards rejected ─
jq '
  .route.rules = .route.rules[0:9]
    + [{ "action": "route", "outbound": "ucc-agy-exit-acct6", "process_path_regex": ["\\.local/share/ucc/profiles/agy-user\\.1/"] }]
    + .route.rules[9:]
' "$WORK_DIR/base.json" > "$WORK_DIR/dotted-add.json"
jq '
  (.route.rules[] | select((.process_path_regex // []) | index("\\.local/share/ucc/profiles/agy-user\\.1/"))).outbound = "ucc-agy-exit-caoer116"
' "$WORK_DIR/dotted-add.json" > "$WORK_DIR/dotted-rebind.json"
jq '
  .route.rules = .route.rules[0:9]
    + [{ "action": "route", "outbound": "ucc-agy-exit-acct6", "process_path_regex": ["\\.local/share/ucc/profiles/agy-wild.1/"] }]
    + .route.rules[9:]
' "$WORK_DIR/base.json" > "$WORK_DIR/wildcard-dot.json"

OUT="$(classify "$WORK_DIR/dotted-add.json" "$WORK_DIR/base.json")"
assert_eq "$(jq -r '.action' <<< "$OUT")" "reload" "T14a remove action"
assert_eq "$(jq -c '.reap_profiles' <<< "$OUT")" '["agy-user.1"]' "T14a escaped-dot remove"

OUT="$(classify "$WORK_DIR/dotted-add.json" "$WORK_DIR/dotted-rebind.json")"
assert_eq "$(jq -r '.action' <<< "$OUT")" "reload" "T14b rebind action"
assert_eq "$(jq -c '.reap_profiles' <<< "$OUT")" '["agy-user.1"]' "T14b escaped-dot rebind"

OUT="$(classify "$WORK_DIR/wildcard-dot.json" "$WORK_DIR/base.json")"
assert_eq "$(jq -c '.reap_profiles' <<< "$OUT")" '[]' "T14c unescaped wildcard dot rejected"
pass "T14 (P2-1): escaped-dot slug extracted & unescaped (agy-user.1) while unescaped wildcard dot rejected"

# ── T15 (P2-2): Ephemeral docker/br-/veth* churn reloads; static iface restarts ─
jq '.inbounds[0].exclude_interface = ["docker0", "br-a1b2c3d4", "veth9f8e7d"]' "$WORK_DIR/base.json" > "$WORK_DIR/veth-churn.json"
jq 'del(.inbounds[0].exclude_interface)' "$WORK_DIR/base.json" > "$WORK_DIR/veth-gone.json"
jq '.inbounds[0].exclude_interface = ["docker0", "eth0"]' "$WORK_DIR/base.json" > "$WORK_DIR/static-iface.json"

OUT="$(classify "$WORK_DIR/base.json" "$WORK_DIR/veth-churn.json")"
assert_eq "$(jq -r '.action' <<< "$OUT")" "reload" "T15a veth add action"
assert_eq "$(jq -c '.reasons' <<< "$OUT")" "[]" "T15a veth add reasons"

OUT="$(classify "$WORK_DIR/veth-churn.json" "$WORK_DIR/veth-gone.json")"
assert_eq "$(jq -r '.action' <<< "$OUT")" "reload" "T15b veth+docker remove action"
assert_eq "$(jq -c '.reasons' <<< "$OUT")" "[]" "T15b veth+docker remove reasons"

OUT="$(classify "$WORK_DIR/base.json" "$WORK_DIR/static-iface.json")"
assert_eq "$(jq -r '.action' <<< "$OUT")" "restart" "T15c static iface action"
assert_eq "$(jq -c '.reasons' <<< "$OUT")" '["inbounds"]' "T15c static iface reasons"
pass "T15 (P2-2): ephemeral docker*/br-*/veth* churn reloads cleanly while static exclude_interface forces restart"

# ── T16 (P2-3): Full rule binding + recursive nested logical rule inspection ──
jq '
  (.route.rules[] | select((.process_path_regex // []) | index("\\.local/share/ucc/profiles/agy-caoer116/"))).port = [443]
' "$WORK_DIR/base.json" > "$WORK_DIR/pred-mutate.json"
OUT="$(classify "$WORK_DIR/base.json" "$WORK_DIR/pred-mutate.json")"
assert_eq "$(jq -r '.action' <<< "$OUT")" "reload" "T16a pred action"
assert_eq "$(jq -c '.reap_profiles' <<< "$OUT")" '["agy-caoer116"]' "T16a route predicate change triggers reap"

jq '
  .route.rules = [
    {
      "type": "logical",
      "mode": "and",
      "rules": [
        {
          "type": "logical",
          "mode": "or",
          "rules": [
            { "process_path_regex": ["\\.local/share/ucc/profiles/agy-izume/"] }
          ]
        },
        { "ip_cidr": ["198.51.100.0/24"] }
      ],
      "action": "reject"
    }
  ] + .route.rules
' "$WORK_DIR/base.json" > "$WORK_DIR/nested-logical-1.json"
jq '.route.rules[0].rules[1].ip_cidr = ["203.0.113.0/24"]' "$WORK_DIR/nested-logical-1.json" > "$WORK_DIR/nested-logical-2.json"

OUT="$(classify "$WORK_DIR/nested-logical-1.json" "$WORK_DIR/nested-logical-2.json")"
assert_eq "$(jq -r '.action' <<< "$OUT")" "reload" "T16b nested logical action"
assert_eq "$(jq -c '.reap_profiles' <<< "$OUT")" '["agy-izume"]' "T16b nested logical guard change triggers reap"
pass "T16 (P2-3): full rule predicate change and depth-2 nested logical rule change trigger targeted reap"

# ── Extract REAL updateScript body from ucc-singbox.nixos.nix ────────────────
UPDATE_BODY="$WORK_DIR/update-body.sh"
sed -n '/# BEGIN UCC_SINGBOX_UPDATE_SCRIPT/,/# END UCC_SINGBOX_UPDATE_SCRIPT/p' "$MODULE_NIX" \
  | sed "s/''\\\${/\${/g" > "$UPDATE_BODY"
[ -s "$UPDATE_BODY" ] || fail "Could not extract UCC_SINGBOX_UPDATE_SCRIPT from $MODULE_NIX"
bash -n "$UPDATE_BODY" || fail "Extracted updateScript body failed bash -n syntax check"
pass "G1c: extracted REAL updateScript body from ucc-singbox.nixos.nix passes bash -n"

# Build thin wrapper that binds ONLY the Nix store-path / option variables and
# sources the VERBATIM extracted updateScript body (with real flock, jq, cmp,
# hot-reload-classify.jq).
REAL_UPDATE_RUNNER="$WORK_DIR/run-real-update.sh"
cat > "$REAL_UPDATE_RUNNER" <<EOF_WRAPPER
#!/usr/bin/env bash
set -eu
umask 077
state="\$TEST_STATE"
renderer="\$TEST_RENDER_BIN"
fetch_bin="\$TEST_FETCH_BIN"
service_name="sing-box-ucc-ucc"
routed_user="\$(id -un)"
classify_jq="$CLASSIFY_JQ"
flock_bin="\$(command -v flock)"
cmp_bin="\$(command -v cmp)"
jq_bin="\$(command -v jq)"
systemctl_bin="\$TEST_SYSTEMCTL"
journalctl_bin="\$TEST_JOURNALCTL"
setpriv_bin="\$TEST_SETPRIV"
id_bin="\$(command -v id)"
curl_bin="\$TEST_CURL"
date_bin="\$(command -v date)"
awk_bin="\$(command -v awk)"
grep_bin="\$(command -v grep)"
sleep_bin="\$TEST_SLEEP"
reload_confirm_ticks="\${TEST_RELOAD_TICKS:-3}"
reload_poll_interval="0"
egress_reload_sleep="0"
egress_restart_sleep="0"
egress_retry_sleep="0"
reap_hooks=("\$TEST_REAP_HOOK")
source "$UPDATE_BODY"
EOF_WRAPPER
chmod +x "$REAL_UPDATE_RUNNER"

# Check whether $dir/state/.lock is currently held by another process (i.e. updateScript).
LOCK_PROBE="$WORK_DIR/check-lock.sh"
cat > "$LOCK_PROBE" <<'EOF_LOCK'
#!/usr/bin/env bash
if flock -n "$1" true 2>/dev/null; then
  echo "UNLOCKED"
else
  echo "LOCKED"
fi
EOF_LOCK
chmod +x "$LOCK_PROBE"

setup_real_case() {
  local name="$1" prev_cfg="$2" next_cfg="$3" is_active="$4" reload_rc="$5" journal_mode="$6" reap_rc="$7" egress_after="$8"
  local dir="$WORK_DIR/case-$name"
  mkdir -p "$dir/state"
  cp "$prev_cfg" "$dir/state/config.json"
  printf 'raw-prev-%s\n' "$name" > "$dir/state/raw.json"
  printf 'raw-next-%s\n' "$name" > "$dir/next.raw"
  cp "$next_cfg" "$dir/next.cfg"
  : > "$dir/events.log"
  : > "$dir/systemctl.log"
  : > "$dir/reap.log"
  printf '0\n' > "$dir/curl.count"

  cat > "$dir/fetch" <<EOF_F
#!/usr/bin/env bash
cp "$dir/next.raw" "\$1"
EOF_F
  chmod +x "$dir/fetch"

  cat > "$dir/render" <<EOF_R
#!/usr/bin/env bash
cp "$dir/next.cfg" "\$2"
EOF_R
  chmod +x "$dir/render"

  # Set render.id to the exact renderer path so same_renderer() matches before change
  printf '%s\n' "$dir/render" > "$dir/state/render.id"

  # Keep a live dummy process so confirm_reload's `kill -0 "$pid"` sees a real PID.
  sleep 300 &
  local dummy_pid=$!
  printf '%d\n' "$dummy_pid" > "$dir/dummy.pid"

  cat > "$dir/systemctl" <<EOF_SC
#!/usr/bin/env bash
lock_state="\$("$LOCK_PROBE" "$dir/state/.lock")"
echo "\$*" >> "$dir/systemctl.log"
case "\$1" in
  is-active)
    if [ "\${2:-}" = "--quiet" ]; then
      exit $is_active
    else
      if [ "$is_active" -eq 0 ]; then echo "active"; else echo "inactive"; fi
      exit $is_active
    fi
    ;;
  show)
    cat "$dir/dummy.pid"
    ;;
  reload)
    echo "systemctl:reload:lock=\$lock_state" >> "$dir/events.log"
    exit $reload_rc
    ;;
  restart)
    echo "systemctl:restart:lock=\$lock_state" >> "$dir/events.log"
    exit 0
    ;;
esac
EOF_SC
  chmod +x "$dir/systemctl"

  cat > "$dir/journalctl" <<EOF_JC
#!/usr/bin/env bash
case "\$*" in
  *--show-cursor*)
    echo "-- cursor: s=testcursor;i=1"
    exit 0
    ;;
esac
lock_state="\$("$LOCK_PROBE" "$dir/state/.lock")"
echo "journalctl:confirm:lock=\$lock_state" >> "$dir/events.log"
case "$journal_mode" in
  started)
    echo "INFO[0000] sing-box started (0.25s)"
    ;;
  error)
    echo "ERROR[0000] reload service: decode config: invalid test json"
    ;;
  timeout)
    ;;
esac
EOF_JC
  chmod +x "$dir/journalctl"

  cat > "$dir/setpriv" <<'EOF_SP'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--" ]; then shift; break; fi
  shift
done
exec "$@"
EOF_SP
  chmod +x "$dir/setpriv"

  # curl is invoked twice per egress() call: google then anthropic.
  # Calls 1-2 = before (204, 000); calls 3+ = after (from $egress_after: "<state> <g> <a>").
  local after_google after_anthro
  after_google="$(awk '{print $2}' <<< "$egress_after")"
  after_anthro="$(awk '{print $3}' <<< "$egress_after")"
  cat > "$dir/curl" <<EOF_CURL
#!/usr/bin/env bash
c="\$(cat "$dir/curl.count")"
c=\$((c + 1))
printf '%s\n' "\$c" > "$dir/curl.count"
lock_state="\$("$LOCK_PROBE" "$dir/state/.lock")"
if [ "\$c" -le 2 ]; then
  if [ "\$c" -eq 1 ]; then
    echo "egress:before:lock=\$lock_state" >> "$dir/events.log"
    printf '204'
  else
    printf '000'
  fi
else
  if [ "\$((c % 2))" -eq 1 ]; then
    echo "egress:after:lock=\$lock_state" >> "$dir/events.log"
    printf '%s' "$after_google"
  else
    printf '%s' "$after_anthro"
  fi
fi
EOF_CURL
  chmod +x "$dir/curl"

  cat > "$dir/sleep" <<'EOF_SL'
#!/usr/bin/env bash
exit 0
EOF_SL
  chmod +x "$dir/sleep"

  cat > "$dir/reap" <<EOF_RP
#!/usr/bin/env bash
lock_state="\$("$LOCK_PROBE" "$dir/state/.lock")"
echo "\$1" >> "$dir/reap.log"
echo "reap:\$1:lock=\$lock_state" >> "$dir/events.log"
exit $reap_rc
EOF_RP
  chmod +x "$dir/reap"

  TEST_STATE="$dir/state" \
  TEST_FETCH_BIN="$dir/fetch" \
  TEST_RENDER_BIN="$dir/render" \
  TEST_SYSTEMCTL="$dir/systemctl" \
  TEST_JOURNALCTL="$dir/journalctl" \
  TEST_SETPRIV="$dir/setpriv" \
  TEST_CURL="$dir/curl" \
  TEST_SLEEP="$dir/sleep" \
  TEST_REAP_HOOK="$dir/reap" \
  "$REAL_UPDATE_RUNNER" "$dir/result" 2>"$dir/stderr.log" || true

  kill "$dummy_pid" 2>/dev/null || true
  wait "$dummy_pid" 2>/dev/null || true
}

# S1: Route add -> reload + confirm_reload, flock held, 0 restarts, 0 reaps
setup_real_case s1 "$WORK_DIR/base.json" "$WORK_DIR/add.json" 0 0 started 0 "active 204 000"
assert_eq "$(cat "$WORK_DIR/case-s1/result")" "applied" "S1 result"
assert_contains "$(cat "$WORK_DIR/case-s1/events.log")" "systemctl:reload:lock=LOCKED" "S1 reload under flock 9"
assert_contains "$(cat "$WORK_DIR/case-s1/events.log")" "journalctl:confirm:lock=LOCKED" "S1 confirm under flock 9"
assert_contains "$(cat "$WORK_DIR/case-s1/events.log")" "egress:after:lock=LOCKED" "S1 egress under flock 9"
if grep -q "restart" "$WORK_DIR/case-s1/systemctl.log"; then fail "S1 unexpectedly restarted"; fi
assert_eq "$(wc -l < "$WORK_DIR/case-s1/reap.log" | tr -d ' ')" "0" "S1 reap count"
pass "S1 (real updateScript): route add -> reload + confirm_reload under flock 9, 0 restarts, 0 reaps"

# S2 (P1-2): Route remove -> pre-reload reap -> reload -> confirm -> post-reload reap -> egress (all under flock 9!)
setup_real_case s2 "$WORK_DIR/add.json" "$WORK_DIR/base.json" 0 0 started 0 "active 204 000"
assert_eq "$(cat "$WORK_DIR/case-s2/result")" "applied" "S2 result"
if grep -q "restart" "$WORK_DIR/case-s2/systemctl.log"; then fail "S2 unexpectedly restarted"; fi
assert_eq "$(wc -l < "$WORK_DIR/case-s2/reap.log" | tr -d ' ')" "2" "S2 pre+post reap passes (2 calls)"
assert_eq "$(sort -u "$WORK_DIR/case-s2/reap.log")" "agy-hotreload-test" "S2 reap target"
assert_line_order "$WORK_DIR/case-s2/events.log" "reap:agy-hotreload-test:lock=LOCKED" "systemctl:reload:lock=LOCKED" "S2 pre-reload reap precedes reload"
assert_line_order "$WORK_DIR/case-s2/events.log" "systemctl:reload:lock=LOCKED" "journalctl:confirm:lock=LOCKED" "S2 reload precedes confirm"
# Verify second reap call happens strictly AFTER confirm and strictly BEFORE egress:after
REAP2_LINE="$(grep -n -F "reap:agy-hotreload-test:lock=LOCKED" "$WORK_DIR/case-s2/events.log" | tail -n 1 | cut -d: -f1)"
CONFIRM_LINE="$(grep -n -F "journalctl:confirm:lock=LOCKED" "$WORK_DIR/case-s2/events.log" | head -n 1 | cut -d: -f1)"
EGRESS_AFTER_LINE="$(grep -n -F "egress:after:lock=LOCKED" "$WORK_DIR/case-s2/events.log" | head -n 1 | cut -d: -f1)"
[ "$CONFIRM_LINE" -lt "$REAP2_LINE" ] && [ "$REAP2_LINE" -lt "$EGRESS_AFTER_LINE" ] \
  || fail "S2 post-reload reap (line $REAP2_LINE) must sit between confirm ($CONFIRM_LINE) and egress:after ($EGRESS_AFTER_LINE)"
pass "S2 (real updateScript, P1-2): pre-reap -> reload -> confirm -> post-reap -> egress all under flock 9"

# S3: Structural inbound TUN change -> releases flock 9 -> full systemctl restart
setup_real_case s3 "$WORK_DIR/base.json" "$WORK_DIR/inbounds.json" 0 0 started 0 "active 204 000"
assert_eq "$(cat "$WORK_DIR/case-s3/result")" "applied" "S3 result"
assert_contains "$(cat "$WORK_DIR/case-s3/events.log")" "systemctl:restart:lock=UNLOCKED" "S3 restart releases flock 9"
if grep -q "reload" "$WORK_DIR/case-s3/systemctl.log"; then fail "S3 unexpectedly reloaded"; fi
pass "S3 (real updateScript): structural inbound change -> releases flock 9 + deliberate systemctl restart"

# S4: systemctl reload fails -> releases flock 9 -> fallback full restart
setup_real_case s4 "$WORK_DIR/base.json" "$WORK_DIR/add.json" 0 1 started 0 "active 204 000"
assert_eq "$(cat "$WORK_DIR/case-s4/result")" "applied" "S4 result"
assert_contains "$(cat "$WORK_DIR/case-s4/events.log")" "systemctl:reload:lock=LOCKED" "S4 attempted reload under lock"
assert_contains "$(cat "$WORK_DIR/case-s4/events.log")" "systemctl:restart:lock=UNLOCKED" "S4 fallback restart unlocked"
pass "S4 (real updateScript): systemctl reload failure -> releases flock 9 + fallback restart"

# S5: Egress degrades after reload -> rollback + restart unlocked + rejected stamp
setup_real_case s5 "$WORK_DIR/base.json" "$WORK_DIR/add.json" 0 0 started 0 "active 000 000"
assert_contains "$(cat "$WORK_DIR/case-s5/result")" "rolled back" "S5 rollback result"
assert_contains "$(cat "$WORK_DIR/case-s5/events.log")" "systemctl:reload:lock=LOCKED" "S5 reload first"
assert_contains "$(cat "$WORK_DIR/case-s5/events.log")" "systemctl:restart:lock=UNLOCKED" "S5 rollback restart unlocked"
cmp -s "$WORK_DIR/base.json" "$WORK_DIR/case-s5/state/config.json" || fail "S5 config not restored"
[ -s "$WORK_DIR/case-s5/state/rejected" ] || fail "S5 rejected stamp missing"
pass "S5 (real updateScript): post-reload egress degradation -> restores prev config + rollback restart + rejected"

# S6: Service inactive -> direct full restart (unlocked)
setup_real_case s6 "$WORK_DIR/base.json" "$WORK_DIR/add.json" 3 0 started 0 "active 204 000"
assert_eq "$(cat "$WORK_DIR/case-s6/result")" "applied" "S6 result"
assert_contains "$(cat "$WORK_DIR/case-s6/events.log")" "systemctl:restart:lock=UNLOCKED" "S6 restart unlocked"
if grep -q "reload" "$WORK_DIR/case-s6/systemctl.log"; then fail "S6 unexpectedly reloaded while inactive"; fi
pass "S6 (real updateScript): inactive service -> direct full systemctl restart"

# S7 (P1-2): Pre-reload reap hook exits non-zero -> skips reload, falls back to full restart
setup_real_case s7 "$WORK_DIR/add.json" "$WORK_DIR/base.json" 0 0 started 1 "active 204 000"
assert_eq "$(cat "$WORK_DIR/case-s7/result")" "applied" "S7 result"
if grep -q "reload" "$WORK_DIR/case-s7/systemctl.log"; then fail "S7 should not reload when pre-reload reap failed"; fi
assert_contains "$(cat "$WORK_DIR/case-s7/events.log")" "reap:agy-hotreload-test:lock=LOCKED" "S7 pre-reload reap ran"
assert_contains "$(cat "$WORK_DIR/case-s7/events.log")" "systemctl:restart:lock=UNLOCKED" "S7 fell back to restart"
assert_contains "$(cat "$WORK_DIR/case-s7/stderr.log")" "pre-reload reap hook failed" "S7 logged pre-reload reap failure"
pass "S7 (real updateScript, P1-2): failed pre-reload reap -> skips reload + falls back to full restart"

# S8 (P2-3): Async SIGHUP exits 0, journald logs `reload service:` error -> fallback restart
setup_real_case s8 "$WORK_DIR/base.json" "$WORK_DIR/add.json" 0 0 error 0 "active 204 000"
assert_eq "$(cat "$WORK_DIR/case-s8/result")" "applied" "S8 result"
assert_contains "$(cat "$WORK_DIR/case-s8/events.log")" "systemctl:reload:lock=LOCKED" "S8 reload ran"
assert_contains "$(cat "$WORK_DIR/case-s8/events.log")" "systemctl:restart:lock=UNLOCKED" "S8 fell back to restart"
assert_contains "$(cat "$WORK_DIR/case-s8/stderr.log")" "sing-box rejected SIGHUP reload" "S8 detected reload service error"
pass "S8 (real updateScript, P2-3): journald 'reload service:' error -> falls back to full restart"

# S9 (P2-3): Async SIGHUP exits 0, journald never logs `sing-box started` -> timeout fallback restart
setup_real_case s9 "$WORK_DIR/base.json" "$WORK_DIR/add.json" 0 0 timeout 0 "active 204 000"
assert_eq "$(cat "$WORK_DIR/case-s9/result")" "applied" "S9 result"
assert_contains "$(cat "$WORK_DIR/case-s9/events.log")" "systemctl:restart:lock=UNLOCKED" "S9 timeout fell back to restart"
assert_contains "$(cat "$WORK_DIR/case-s9/stderr.log")" "timed out waiting for sing-box started" "S9 logged timeout"
pass "S9 (real updateScript, P2-3): missing 'sing-box started' confirmation -> timeout fallback to full restart"

# S10 (P2-2): Ephemeral veth* churn + route add -> real updateScript reloads (0 restarts)
jq '
  .inbounds[0].exclude_interface = ["docker0", "br-112233", "veth445566"]
' "$WORK_DIR/add.json" > "$WORK_DIR/add-with-veth.json"
setup_real_case s10 "$WORK_DIR/base.json" "$WORK_DIR/add-with-veth.json" 0 0 started 0 "active 204 000"
assert_eq "$(cat "$WORK_DIR/case-s10/result")" "applied" "S10 result"
assert_contains "$(cat "$WORK_DIR/case-s10/events.log")" "systemctl:reload:lock=LOCKED" "S10 reloaded despite veth churn"
if grep -q "restart" "$WORK_DIR/case-s10/systemctl.log"; then fail "S10 unexpectedly restarted on veth churn"; fi
pass "S10 (real updateScript, P2-2): ephemeral veth* churn + route add -> hot-reload (0 restarts)"

# ── G4: Claude 0-diff repo check (works on feature branch AND merged main) ───
if git -C "$REPO_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
  DIFF_BASE="origin/main"
  if ! git -C "$REPO_ROOT" rev-parse --verify origin/main >/dev/null 2>&1 \
     || [ "$(git -C "$REPO_ROOT" rev-parse HEAD)" = "$(git -C "$REPO_ROOT" rev-parse origin/main)" ]; then
    DIFF_BASE="HEAD~1"
  fi
  CLAUDE_DIFF="$(
    git -C "$REPO_ROOT" diff "${DIFF_BASE}...HEAD" -- modules/ucc-singbox/anthropic-failclosed.jq modules/ucc-singbox/failclosed-hold.jq
    git -C "$REPO_ROOT" diff -- modules/ucc-singbox/anthropic-failclosed.jq modules/ucc-singbox/failclosed-hold.jq
    git -C "$REPO_ROOT" diff --cached -- modules/ucc-singbox/anthropic-failclosed.jq modules/ucc-singbox/failclosed-hold.jq
  )"
  [ -z "$CLAUDE_DIFF" ] || fail "G4: unexpected diff in anthropic-failclosed.jq / failclosed-hold.jq (base=$DIFF_BASE)"
  pass "G4: zero diffs on anthropic-failclosed.jq and failclosed-hold.jq (base=$DIFF_BASE)"
fi

printf '\nALL HOT-RELOAD CHECKS PASSED (%d checks)\n' "$PASS_COUNT"
