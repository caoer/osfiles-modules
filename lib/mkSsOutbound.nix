# lib/mkSsOutbound.nix — build a sing-box shadowsocks outbound from a
# sing-box-upstreams registry entry.
#
# Single source for turning a registry server into a client outbound. Used by
# mkSingBoxClientConfig (profile-driven clients) AND by hosts that hand-assemble
# a config with a host-specific inbound/route (e.g. UID-scoped TUN clients).
# Keeping this one definition is what stops client endpoints from drifting out
# of sync with the server fleet.
#
# Usage: osfLib.mkSsOutbound { inherit lib; } "dmit2" upstreams.servers.dmit-lax-2
{ lib }:
tag: entry:
{
  type = "shadowsocks";
  inherit tag;
  inherit (entry) server method password;
  server_port = entry.port;
}
// lib.optionalAttrs (entry.udpOverTcp or false) { udp_over_tcp = true; }
// lib.optionalAttrs (entry ? mux) {
  multiplex = {
    enabled = true;
    inherit (entry.mux) protocol;
    max_connections = entry.mux.maxConnections;
    min_streams = entry.mux.minStreams;
    inherit (entry.mux) padding;
  };
}
