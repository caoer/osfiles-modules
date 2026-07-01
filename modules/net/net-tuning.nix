# modules/net/net-tuning.nix — Cross-platform network performance tuning.
#
# Parameterized on { platform } to avoid infinite recursion (pkgs.stdenv
# depends on config._module.args, which requires evaluating all modules).
#
# Presets:
#   none        — no tuning.
#   basic       — lightweight defaults (both platforms).
#   linux_proxy — server: large buffers, pacing, aggressive TCP, kernel/VM.
#                 Linux only — asserts on macOS.
#   mac_client  — desktop: large buffers, window scaling, CUBIC tuning.
#                 macOS only — asserts on Linux.
#
# Traffic shaping (osf.netTuning.trafficShaping) is orthogonal —
# Linux-only, enable separately with interface + rate cap.
{
  platform ? "linux",
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.osf.netTuning;
  ts = cfg.trafficShaping;

  isDarwin = platform == "darwin";
  isLinux = platform == "linux";

  isBasicOrAbove = cfg.preset != "none";

  # ── macOS sysctl arguments by tier ─────────────────────────────────
  darwinBasicArgs = [
    "net.inet.tcp.mssdflt=1460" # ethernet MTU (default 512)
    "net.inet.tcp.v6mssdflt=1440" # IPv6: 1500 - 40 - 20
    "net.inet.tcp.fastopen=3" # TFO client+server
    "net.inet.tcp.delayed_ack=3" # auto-detect (Apple Minshall fix)
  ];

  # Buffer tuning for high-BDP paths (CN2 GIA, ~200ms RTT).
  # BDP = 1 Gbps × 200ms = 25 MB. Ceiling at 32 MB (128% of BDP).
  #
  # IMPORTANT: sendspace/recvspace are INITIAL per-socket allocations.
  # On macOS Sequoia+, Network.framework (Skywalk) pre-allocates these
  # in per-nexus channel pools with hard limits. Large initial values
  # exhaust the pool after a few connections → ENOBUFS → "Failed to
  # attach protocol tcp" → all GUI apps lose internet while CLI works.
  # Keep initial values small; the kernel autotuner ramps to the
  # autorcvbufmax/autosndbufmax ceilings per-connection as needed.
  darwinBufferArgs = [
    "kern.ipc.maxsockbuf=33554432" # 32 MB — macOS ceiling
    "net.inet.tcp.autorcvbufmax=33554432" # 32 MB autotuner ceiling
    "net.inet.tcp.autosndbufmax=33554432" # 32 MB
    "net.inet.tcp.sendspace=262144" # 256 KB initial — autotuner scales up
    "net.inet.tcp.recvspace=262144" # 256 KB initial — autotuner scales up
    "net.inet.tcp.win_scale_factor=9" # max window 33.6 MB > BDP
    "net.inet.tcp.autosndbufinc=65536" # faster buffer ramp
    "net.inet.tcp.cubic_tcp_friendliness=1" # CUBIC >= standard TCP on LFN
  ];
in
{
  options.osf.netTuning = {
    preset = lib.mkOption {
      type = lib.types.enum [
        "none"
        "basic"
        "linux_proxy"
        "mac_client"
      ];
      default = "none";
      description = ''
        Network performance tuning preset.

        none        — no sysctl tuning from this module.
        basic       — lightweight per-platform defaults.
                      NixOS: BBR, fq qdisc, TCP fast open.
                      macOS: TCP fast open, ethernet MSS, delayed ACK.
        linux_proxy — Linux only. basic + 64 MB buffers, BBR pacing,
                      aggressive TCP, keepalive, kernel/VM server params.
        mac_client  — macOS only. basic + 32 MB buffers, window scaling,
                      CUBIC tuning for high-BDP desktop paths.
      '';
    };

    trafficShaping = {
      enable = lib.mkEnableOption "HTB aggregate traffic shaping (Linux only; caps egress with fq leaf for BBR pacing)";

      interface = lib.mkOption {
        type = lib.types.str;
        default = "eth0";
        description = "Network interface to shape.";
      };

      rateMbit = lib.mkOption {
        type = lib.types.int;
        default = 850;
        description = ''
          Aggregate egress cap in Mbit/s. Set below the provider's hard
          limit to prevent BBR probe overshoot → provider drops → sawtooth.
        '';
      };
    };
  };

  config = lib.mkMerge (
    # ── Platform assertions ───────────────────────────────────────────
    [
      {
        assertions = [
          {
            assertion = !(isDarwin && cfg.preset == "linux_proxy");
            message = "osf.netTuning.preset \"linux_proxy\" cannot be used on macOS. Use \"basic\" or \"mac_client\".";
          }
          {
            assertion = !(isLinux && cfg.preset == "mac_client");
            message = "osf.netTuning.preset \"mac_client\" cannot be used on Linux. Use \"basic\" or \"linux_proxy\".";
          }
          {
            assertion = !(isDarwin && ts.enable);
            message = "osf.netTuning.trafficShaping is Linux-only (requires tc/iproute2).";
          }
        ];
      }
    ]

    # ════════════════════════════════════════════════════════════════
    # NixOS (boot.kernel.sysctl)
    # ════════════════════════════════════════════════════════════════
    ++ (lib.optionals isLinux [
      # ── basic: BBR + fq + fastopen ──────────────────────────────
      (lib.mkIf isBasicOrAbove {
        boot.kernel.sysctl = {
          "net.core.default_qdisc" = lib.mkDefault "fq";
          "net.ipv4.tcp_congestion_control" = lib.mkDefault "bbr";
          "net.ipv4.tcp_fastopen" = lib.mkDefault 3;
        };
      })

      # ── linux_proxy: buffers + TCP perf + pacing + keepalive + VM
      (lib.mkIf (cfg.preset == "linux_proxy") {
        boot.kernel.sysctl = {
          # BBR pacing — prevent overshoot past provider bandwidth cap.
          "net.ipv4.tcp_pacing_ss_ratio" = lib.mkDefault 120;
          "net.ipv4.tcp_pacing_ca_ratio" = lib.mkDefault 105;

          # Buffers — sized for high-BDP links (150-200ms RTT × high bw).
          # 64 MB ceiling; kernel auto-tunes per-socket via tcp_moderate_rcvbuf.
          "net.core.rmem_max" = lib.mkDefault 67108864;
          "net.core.wmem_max" = lib.mkDefault 67108864;
          "net.core.netdev_max_backlog" = lib.mkDefault 4096;
          "net.ipv4.tcp_rmem" = lib.mkDefault "4096 87380 67108864";
          "net.ipv4.tcp_wmem" = lib.mkDefault "4096 65536 67108864";

          # TCP performance
          "net.ipv4.tcp_adv_win_scale" = lib.mkDefault 4;
          "net.ipv4.tcp_slow_start_after_idle" = lib.mkDefault 0;
          "net.ipv4.tcp_mtu_probing" = lib.mkDefault 1;
          "net.ipv4.tcp_tw_reuse" = lib.mkDefault 1;
          "net.ipv4.tcp_fin_timeout" = lib.mkDefault 15;
          "net.ipv4.tcp_max_tw_buckets" = lib.mkDefault 32768;
          "net.ipv4.tcp_max_syn_backlog" = lib.mkDefault 4096;
          "net.ipv4.tcp_synack_retries" = lib.mkDefault 2;
          "net.ipv4.tcp_syn_retries" = lib.mkDefault 3;

          # Keepalive — faster dead peer detection
          "net.ipv4.tcp_keepalive_time" = lib.mkDefault 600;
          "net.ipv4.tcp_keepalive_intvl" = lib.mkDefault 30;
          "net.ipv4.tcp_keepalive_probes" = lib.mkDefault 5;

          # Ephemeral port range
          "net.ipv4.ip_local_port_range" = lib.mkDefault "1024 65535";

          # Kernel/VM — server-optimized
          "kernel.panic" = lib.mkDefault 1;
          "kernel.sched_autogroup_enabled" = lib.mkDefault 0;
          "vm.swappiness" = lib.mkDefault 0;
          "vm.dirty_ratio" = lib.mkDefault 10;
          "vm.dirty_background_ratio" = lib.mkDefault 5;
        };
      })

      # ── Traffic shaping: HTB aggregate cap + fq leaf ────────────
      (lib.mkIf ts.enable {
        systemd.services.tc-shaping = {
          description = "HTB traffic shaping on ${ts.interface} (${toString ts.rateMbit}Mbit cap)";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.writeShellScript "tc-shaping-start" ''
              ${pkgs.iproute2}/bin/tc qdisc del dev ${ts.interface} root 2>/dev/null || true
              ${pkgs.iproute2}/bin/tc qdisc add dev ${ts.interface} root handle 1: htb default 10
              ${pkgs.iproute2}/bin/tc class add dev ${ts.interface} parent 1: classid 1:10 htb rate ${toString ts.rateMbit}mbit ceil ${toString ts.rateMbit}mbit burst 64k cburst 64k
              ${pkgs.iproute2}/bin/tc qdisc add dev ${ts.interface} parent 1:10 handle 20: fq
            '';
            ExecStop = pkgs.writeShellScript "tc-shaping-stop" ''
              ${pkgs.iproute2}/bin/tc qdisc del dev ${ts.interface} root 2>/dev/null || true
            '';
          };
        };
      })
    ])

    # ════════════════════════════════════════════════════════════════
    # macOS (launchd daemon — no boot.kernel.sysctl on Darwin)
    # ════════════════════════════════════════════════════════════════
    ++ (lib.optionals isDarwin [
      # ── basic: TFO + MSS + delayed ACK ──────────────────────────
      (lib.mkIf (cfg.preset == "basic") {
        launchd.daemons.tcp-tuning = {
          serviceConfig = {
            Label = "com.osf.tcp-tuning";
            RunAtLoad = true;
            KeepAlive.SuccessfulExit = false;
            ProgramArguments = [
              "/usr/sbin/sysctl"
              "-w"
            ]
            ++ darwinBasicArgs;
          };
        };
      })

      # ── mac_client: basic + 32 MB buffers + window scale + CUBIC
      (lib.mkIf (cfg.preset == "mac_client") {
        launchd.daemons.tcp-tuning = {
          serviceConfig = {
            Label = "com.osf.tcp-tuning";
            RunAtLoad = true;
            KeepAlive.SuccessfulExit = false;
            ProgramArguments = [
              "/usr/sbin/sysctl"
              "-w"
            ]
            ++ darwinBasicArgs
            ++ darwinBufferArgs;
          };
        };
      })
    ])
  );
}
