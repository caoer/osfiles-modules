# packages/watchdog.nix — eBPF TCP health monitor + auto-recovery.
#
# Source: locus kit/watchdog/. Generated BPF files (tcpmon_bpfel.go,
# tcpmon_bpfel.o) must be checked in — buildGoModule skips go generate.
{
  lib,
  buildGoModule,
  watchdogSrc ? null,
}:

buildGoModule {
  pname = "tunnel-watchdog";
  version = "0.1.0";

  src =
    if watchdogSrc != null then
      watchdogSrc
    else
      builtins.throw "watchdog: pass watchdogSrc (locus kit/watchdog/) via flake input or buildGoModule args";

  # Compute after first build: nix build, copy printed hash here.
  vendorHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

  subPackages = [ "." ];

  preBuild = ''
    if [ ! -f tcpmon_bpfel.go ]; then
      echo "ERROR: generated BPF files missing. Run 'go generate' on a Linux host with clang first."
      exit 1
    fi
  '';

  meta = {
    description = "eBPF TCP health monitor with escalating auto-recovery for tunnel services";
    platforms = lib.platforms.linux;
  };
}
