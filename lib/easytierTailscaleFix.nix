# lib/osf/easytierTailscaleFix.nix — Tailscale coexistence scripts for EasyTier.
#
# Single source for the fix/cleanup scripts consumed by BOTH modules/nixos/easytier.nix
# and modules/foreign/easytier.nix (platform substrates stay separate; only this
# byte-identical, platform-neutral script pair is shared). Divergence here would be a
# silent one-platform mesh blackhole during an incident — so it lives in exactly one place.
#
# Tailscale coexistence: EasyTier magicDnsRelay sits inside Tailscale's
# CGNAT block. Two collisions to undo:
#   (1) routing — force the query to the main table (tun0), not Tailscale's.
#   (2) filtering — accept the reply before Tailscale's anti-spoof rule
#       `ts-input -s CGNAT ! -i tailscale0 -j DROP` eats it.
# Without (2) the responder is silent on Tailscale hosts (ping = 100% loss).
# `|| true` keeps both scripts idempotent on restart.
#
# Returns { fix, cleanup } — each a pkgs.writeShellScript derivation. Bodies are
# byte-for-byte the originals, so output store paths are unchanged (no rebuild churn).
{ pkgs }:
let
  wk = import ./well-known.nix;
in
{
  fix = pkgs.writeShellScript "easytier-tailscale-fix" ''
    ${pkgs.iproute2}/bin/ip rule add to ${wk.easytier.magicDnsCidr} lookup main priority 5200 || true
    ${pkgs.iptables}/bin/iptables -I INPUT 1 -i tun0 -s ${wk.easytier.magicDnsRelay} -j ACCEPT || true
  '';

  cleanup = pkgs.writeShellScript "easytier-tailscale-cleanup" ''
    ${pkgs.iproute2}/bin/ip rule del to ${wk.easytier.magicDnsCidr} lookup main priority 5200 || true
    ${pkgs.iptables}/bin/iptables -D INPUT -i tun0 -s ${wk.easytier.magicDnsRelay} -j ACCEPT || true
  '';
}
