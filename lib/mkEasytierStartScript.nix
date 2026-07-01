# lib/osf/mkEasytierStartScript.nix — Generate an EasyTier start script.
#
# Auth modes (see docs/easytier-secure-mode-acl-design.md):
#   auth = "secret"     — backbone: ET_NETWORK_SECRET + --secure-mode. When
#                         credentialFilePath is set, also --credential-file
#                         (loads the credential DB and publishes trusted pubkeys).
#   auth = "credential" — leaf: ET_CREDENTIAL (a per-device X25519 privkey).
#                         --credential implies --secure-mode; no network_secret.
#
# Secret/credential is passed via env var (not CLI) to keep it out of
# /proc/PID/cmdline.
{
  pkgs,
  easytierPkg,
  secretPath,
  hostname,
  ip,
  networkName,
  rpcPortal,
  defaultProtocol,
  listeners,
  peers,
  subnets,
  extraFlags ? [ ],
  vpnPortal ? null,
  auth ? "secret",
  credentialFilePath ? null,
  # Prefix length for tun0 overlay address. Determines the kernel route scope
  # on the TUN interface (e.g. /16 covers mesh + infra subnets dev tun0). Must cover all
  # mesh subnets: infra (.144) + robot routers (.146) + future.
  tunPrefixLen ? 16,
}:
let
  wk = import ./well-known.nix;

  envVar = if auth == "credential" then "ET_CREDENTIAL" else "ET_NETWORK_SECRET";

  # Backbone enables secure mode explicitly and (optionally) loads the
  # credential DB. Credential leaves get secure mode implicitly via ET_CREDENTIAL.
  secureFlags =
    if auth == "credential" then
      [ ]
    else
      [ "--secure-mode" ]
      ++ (
        if credentialFilePath != null then
          [
            "--credential-file"
            credentialFilePath
          ]
        else
          [ ]
      );

  flagList = [
    "--hostname"
    hostname
    "--ipv4"
    "${ip}/${toString tunPrefixLen}"
    "--network-name"
    networkName
    "--rpc-portal"
    rpcPortal
    "--default-protocol"
    defaultProtocol
    "--accept-dns"
    "true"
  ]
  ++ secureFlags
  ++ builtins.concatMap (l: [
    "--listeners"
    l
  ]) listeners
  ++ builtins.concatMap (uri: [
    "--peers"
    uri
  ]) peers
  ++ builtins.concatMap (s: [
    "-n"
    s
  ]) subnets
  ++ (
    if vpnPortal != null then
      [
        "--vpn-portal"
        "wg://${wk.anyAddr}:${toString vpnPortal.listenPort}/${vpnPortal.clientCidr}"
      ]
    else
      [ ]
  )
  ++ extraFlags;

  flags = builtins.concatStringsSep " " flagList;
in
pkgs.writeShellScript "easytier-start" ''
  for i in $(seq 1 30); do
    [ -s "${secretPath}" ] && break
    sleep 1
  done
  if [ ! -s "${secretPath}" ]; then
    echo "ERROR: easytier ${envVar} not available at ${secretPath} after 30s" >&2
    exit 1
  fi

  export ${envVar}
  ${envVar}="$(cat "${secretPath}")"

  exec ${easytierPkg}/bin/easytier-core ${flags}
''
