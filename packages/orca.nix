# packages/orca.nix — Orca (stablyai/orca), taken from upstream's Linux release.
#
# stablyai/orca publishes `orca-ide_<v>_amd64.deb` on every GitHub release: the
# Electron app under /opt/Orca, whose resources/bin/orca-ide is the CLI shim
# (`orca-ide serve`, `orca-ide --version`, …) that runs the app's CLI under the
# Electron binary in Node mode. A source build needs Docker and network in its
# build hooks, so this repackages the release bytes: autoPatchelf against the
# library set nixpkgs' electron-bin uses, plus the dlopen'd ones as runtime
# dependencies.
#
# resources/package-type stays `deb`: Orca reads it, finds no apt/dpkg under
# /usr/bin, and treats the install as externally managed, so its updater only
# reports a new version and never downloads or installs one.
#
# bin/orca-ide wraps the shim with what headless `orca-ide serve` needs:
#   PATH     Xvfb (Electron serve starts it by bare name when DISPLAY is unset),
#            the computer-use tools from the deb's Depends (python3 + gi,
#            xdotool, xclip, xdg-utils), then the NixOS system and per-user
#            profiles, which Orca's own PATH augmentation leaves out.
#   fonts    the host's /etc/fonts when it has one, else a DejaVu fontconfig.
# The Electron binary itself is not wrapped: the shim finds it by name next to
# resources/.
#
# The orcad template carries musl and arm64 builds next to the glibc ones;
# autoPatchelf skips the foreign-arch files and the musl libc is ignored.
#
# Bump: set `version`, then `nix store prefetch-file <url>` for `hash`; N's
# scripts/release/release.sh does both through its `orca` row in
# modules/data/release.json.
{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  makeWrapper,
  makeFontsConf,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  cairo,
  cups,
  dbus,
  expat,
  gdk-pixbuf,
  glib,
  gtk3,
  nss,
  nspr,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxrandr,
  libxkbfile,
  libxscrnsaver,
  libxtst,
  pango,
  systemd,
  libnotify,
  libsecret,
  libpulseaudio,
  libdrm,
  libgbm,
  libxkbcommon,
  libxshmfence,
  libGL,
  libuuid,
  vulkan-loader,
  python3,
  xvfb,
  xdotool,
  xclip,
  xdg-utils,
  dejavu_fonts,
}:
let
  python = python3.withPackages (ps: [ ps.pygobject3 ]);
  fallbackFonts = makeFontsConf { fontDirectories = [ dejavu_fonts ]; };
in
stdenv.mkDerivation rec {
  pname = "orca";
  version = "1.4.242";

  src = fetchurl {
    url = "https://github.com/stablyai/orca/releases/download/v${version}/orca-ide_${version}_amd64.deb";
    hash = "sha256-5VuKV/FmIAI2XKZKlZWzq1ET8hOSHNkl/aI19ofKRbM=";
  };

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    makeWrapper
  ];

  buildInputs = [
    stdenv.cc.cc.lib
    alsa-lib
    at-spi2-atk
    at-spi2-core
    cairo
    cups
    dbus
    expat
    gdk-pixbuf
    glib
    gtk3
    nss
    nspr
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxrandr
    libxkbfile
    libxscrnsaver
    libxtst
    pango
    systemd
    libnotify
    libsecret
    libdrm
    libgbm
    libxkbcommon
    libxshmfence
    libuuid
  ];

  # dlopen'd by Chromium, so absent from NEEDED: GL, Vulkan, udev, PulseAudio.
  runtimeDependencies = [
    libGL
    vulkan-loader
    (lib.getLib systemd)
    libpulseaudio
  ];

  autoPatchelfIgnoreMissingDeps = [ "libc.musl-x86_64.so.1" ];

  unpackPhase = ''
    runHook preUnpack
    dpkg-deb --fsys-tarfile $src | tar -x --no-same-owner --no-same-permissions
    runHook postUnpack
  '';

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    [ "$(cat opt/Orca/resources/package-type)" = deb ] \
      || { echo "orca: resources/package-type is not deb" >&2; exit 1; }

    mkdir -p $out/opt $out/bin
    cp -a opt/Orca $out/opt/Orca
    cp -a usr/share $out/share
    substituteInPlace $out/share/applications/*.desktop \
      --replace-quiet /opt/Orca/orca-ide $out/bin/orca-ide

    # chrome-sandbox cannot be setuid in the store; Chromium uses the user
    # namespace sandbox instead.
    chmod 0755 $out/opt/Orca/chrome-sandbox

    makeWrapper $out/opt/Orca/resources/bin/orca-ide $out/bin/orca-ide \
      --prefix PATH : ${
        lib.makeBinPath [
          xvfb
          python
          xdotool
          xclip
          xdg-utils
        ]
      } \
      --suffix PATH : /run/current-system/sw/bin:/etc/profiles/per-user/dev/bin \
      --prefix GI_TYPELIB_PATH : ${at-spi2-core}/lib/girepository-1.0 \
      --run '[ -n "''${FONTCONFIG_FILE-}" ] || [ -e /etc/fonts/fonts.conf ] || export FONTCONFIG_FILE=${fallbackFonts}'

    runHook postInstall
  '';

  meta = {
    description = "Orca agent IDE and headless server (upstream Linux release)";
    homepage = "https://github.com/stablyai/orca";
    license = lib.licenses.mit;
    mainProgram = "orca-ide";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
