# sing-box — universal proxy platform.
#
# Linux: built from source with upstream's linux purego release recipe
# (.github/workflows/build.yml, variant purego: CGO_ENABLED=0,
# release/DEFAULT_BUILD_TAGS + with_purego, release/LDFLAGS) plus with_gvisor.
# Upstream's prebuilt release binaries leave with_gvisor out from 1.15.0-alpha.11
# on, and our TUN inbounds use stack "mixed" / "gvisor", which need it.
# Like the prebuilt we shipped, the package carries no libcronet.so, so the
# naive outbound is compiled in but has no library to load.
#
# Darwin: upstream's prebuilt release binary.
{
  lib,
  stdenv,
  fetchurl,
  fetchFromGitHub,
  buildGoModule,
}:

let
  version = "1.15.0-alpha.12";

  meta = with lib; {
    description = "sing-box — universal proxy platform";
    homepage = "https://github.com/SagerNet/sing-box";
    changelog = "https://github.com/SagerNet/sing-box/releases/tag/v${version}";
    license = licenses.gpl3Plus;
    mainProgram = "sing-box";
  };

  # release/DEFAULT_BUILD_TAGS at the tag, + with_purego (upstream's linux
  # purego variant), + with_gvisor.
  tags = [
    "with_quic"
    "with_dhcp"
    "with_wireguard"
    "with_utls"
    "with_acme"
    "with_clash_api"
    "with_tailscale"
    "with_ccm"
    "with_ocm"
    "with_cloudflared"
    "with_naive_outbound"
    "with_usbip"
    "with_openvpn"
    "with_openconnect"
    "badlinkname"
    "tfogo_checklinkname0"
    "with_purego"
    "with_gvisor"
  ];

  fromSource = buildGoModule {
    pname = "sing-box";
    inherit version tags;

    src = fetchFromGitHub {
      owner = "SagerNet";
      repo = "sing-box";
      rev = "v${version}";
      hash = "sha256-Xu2lsqcGdKdRTEcWwIX6EFuEd87ImnWGI4Vp10aO37Y=";
    };

    vendorHash = "sha256-O18+Y7wlcSUFRo54jC4Ogb8AtnPuLG7rPhzIDCC6sjU=";

    subPackages = [ "cmd/sing-box" ];

    env.CGO_ENABLED = "0";

    # release/LDFLAGS at the tag, plus upstream's version stamp and -s -w.
    ldflags = [
      "-X github.com/sagernet/sing-box/constant.Version=${version}"
      "-X runtime.godebugDefault=multipathtcp=0,tlssha1=1"
      "-checklinkname=0"
      "-s"
      "-w"
      "-buildid="
    ];

    doCheck = false;

    meta = meta // {
      platforms = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    };
  };

  darwinPrebuilt = stdenv.mkDerivation {
    pname = "sing-box";
    inherit version;

    src = fetchurl {
      url = "https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-darwin-arm64.tar.gz";
      sha256 = "sha256-c9p60wRA3Wj2azZz3y/IzJcg5jkPivirmmv5ceT9Y+I=";
    };
    sourceRoot = "sing-box-${version}-darwin-arm64";

    dontBuild = true;
    dontConfigure = true;

    installPhase = ''
      runHook preInstall
      install -Dm755 sing-box $out/bin/sing-box
      runHook postInstall
    '';

    meta = meta // {
      platforms = [ "aarch64-darwin" ];
    };
  };
in
if stdenv.hostPlatform.isDarwin then darwinPrebuilt else fromSource
