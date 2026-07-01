{
  anyAddr = "0.0.0.0";
  localhost = "127.0.0.1";
  loopbackCidr = "127.0.0.0/8";
  broadcast = "255.255.255.255/32";
  multicast = "224.0.0.0/4";

  dns = {
    cloudflare = "1.1.1.1";
    cloudflare2 = "1.0.0.1";
    google = "8.8.8.8";
    google2 = "8.8.4.4";
    alidns = "223.5.5.5";
    alidns2 = "223.6.6.6";
    dnspod = "119.29.29.29";
  };

  rfc1918 = {
    classA = "10.0.0.0/8";
    classB = "172.16.0.0/12";
    classC = "192.168.0.0/16";
  };

  cgnat = "100.64.0.0/10";

  resolvedStub = "127.0.0.53";

  # EasyTier and Tailscale both use 100.100.100.100 for magic DNS,
  # differentiated by interface (tun0 vs tailscale0).
  easytier = {
    magicDns = "100.100.100.100";
    magicDnsRelay = "100.100.100.101";
    magicDnsCidr = "100.100.100.101/32";
  };
  tailscale.magicDns = "100.100.100.100";
}
