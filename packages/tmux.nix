# tmux built from the caoer/tmux fork (flake input tmux-src): upstream
# master post-3.7b, plus the zt patches (6s synchronized-output timeout,
# upstream default is 1s).
#
# Why not a release tag: tmux 3.7b commit e802909d sets PANE_REDRAW when a
# pane app ends synchronized output (CSI ?2026l). yazi/ratatui ends every
# frame with ?2026l, so tmux full-repaints the pane right after forwarding
# the IIP image passthrough; WezTerm anchors IIP images to cells and the
# repaint erases the placement — every preview blanks. 3.7/3.7a lack the
# redraw and upstream master removed it again (65a032b2), but no release
# carries the removal yet. Verified 2026-07-27: A/B rigs at identical
# geometry, client byte captures (3.6a dirty-lines vs 3.7b full-screen
# repaint per frame), positive control (passthrough image + bare ?2026h/l
# erased under 3.7b only). Re-evaluate at the first release after 3.7b.
#
# This file lives here, not in osfiles, because modules/member-base.nix must
# install the fork itself. member-base runs on every NixOS host, and a stock
# `tmux` here silently shadowed the fork in the system buildEnv (earlier list
# entry wins) — so the fleet compiled the fork and then ran 3.7b anyway.
# One definition, consumed by member-base and by osfiles' basic.nix /
# headless-cli.nix, is what keeps that from coming back.
{ tmux, tmux-src }:
tmux.overrideAttrs (old: {
  pname = "tmux";
  version = "next-3.8-zt-0.0.3";
  name = "tmux-next-3.8-zt-0.0.3";
  src = tmux-src;
  patches = [ ];
  # Upstream master makes the jemalloc choice mandatory at configure time.
  configureFlags = (old.configureFlags or [ ]) ++ [ "--disable-jemalloc" ];
})
