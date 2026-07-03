# modules/media-tools.nix — opt-in heavyweight media codecs for NixOS hosts.
#
# yazi's A/V preview plugins (video-montage.yazi / audio-preview.yazi) shell out
# to /run/current-system/sw/bin/ffmpeg by absolute path, so ffmpeg must live in
# the system layer, not home.packages. Full ffmpeg drags a ~410 MiB decode + GUI
# closure (gtk, pipewire, flite TTS, gst-plugins) onto every box.
#
# OFF by default: the plugins probe for ffmpeg at preview time and skip cleanly
# when it is absent (blank preview, no error) — text/data/log/md previews are
# unaffected. Opt in per host that actually browses audio/video in yazi:
#
#   osf.mediaPreview.enable = true;
{ lib, config, pkgs, ... }:
{
  options.osf.mediaPreview.enable =
    lib.mkEnableOption "full ffmpeg for yazi audio/video preview (adds ~410 MiB closure)";

  config = lib.mkIf config.osf.mediaPreview.enable {
    environment.systemPackages = [ pkgs.ffmpeg ];
  };
}
