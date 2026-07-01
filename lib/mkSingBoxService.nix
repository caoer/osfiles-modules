# lib/osf/mkSingBoxService.nix — Shared systemd service builder for sing-box instances.
#
# Returns { "<name>" = <systemd-service-attrset>; } for merging into systemd.services.
{ lib, ... }:
{
  name,
  package,
  configPath,
  description,
  afterServices ? [ "network-online.target" ],
  wantedBy ? [ "multi-user.target" ],
  requiresServices ? [ ],
  partOfServices ? [ ],
  capabilities ? [ "CAP_NET_BIND_SERVICE" ],
  stateDirectory ? null,
  runtimeDirectory ? null,
  check ? true,
  autoStart ? true,
  restart ? "on-failure",
  restartSec ? 5,
  limitNoFile ? 65536,
  dataDir ? null,
  extraStartPre ? null, # null | string | list of ExecStartPre commands
  extraStartPost ? null, # null | string | list of ExecStartPost commands
  extraStopPost ? null,
  restartTriggers ? [ ],
  conflicts ? [ ], # systemd Conflicts=
}:
let
  execStart =
    "${package}/bin/sing-box"
    + lib.optionalString (dataDir != null) " -D ${dataDir}"
    + " run -c ${configPath}";

  checkCmd = "${package}/bin/sing-box check -c ${configPath}";

  startPreList =
    (
      if builtins.isList extraStartPre then
        extraStartPre
      else if extraStartPre != null then
        [ extraStartPre ]
      else
        [ ]
    )
    ++ lib.optional check checkCmd;
in
{
  "${name}" = {
    inherit description;
    after = afterServices;
    wants = lib.filter (s: lib.hasSuffix ".target" s) afterServices;
    wantedBy = lib.optionals autoStart wantedBy;
  }
  // lib.optionalAttrs (restartTriggers != [ ]) {
    inherit restartTriggers;
  }
  // lib.optionalAttrs (requiresServices != [ ]) {
    requires = requiresServices;
  }
  // lib.optionalAttrs (partOfServices != [ ]) {
    partOf = partOfServices;
  }
  // lib.optionalAttrs (conflicts != [ ]) {
    inherit conflicts;
  }
  // {
    serviceConfig = {
      ExecStart = execStart;
      Restart = restart;
      RestartSec = restartSec;
      LimitNOFILE = limitNoFile;
    }
    // lib.optionalAttrs (startPreList != [ ]) {
      ExecStartPre = startPreList;
    }
    // lib.optionalAttrs (extraStartPost != null) {
      ExecStartPost = extraStartPost;
    }
    // lib.optionalAttrs (extraStopPost != null) {
      ExecStopPost = extraStopPost;
    }
    // lib.optionalAttrs (capabilities != [ ]) {
      AmbientCapabilities = capabilities;
      CapabilityBoundingSet = capabilities;
    }
    // lib.optionalAttrs (stateDirectory != null) {
      StateDirectory = stateDirectory;
    }
    // lib.optionalAttrs (runtimeDirectory != null) {
      RuntimeDirectory = runtimeDirectory;
    };
  };
}
