{ pkgs, lib, ... }:

{
  home.packages = [
    pkgs.yazi
    pkgs.duckdb
    pkgs.tailspin
    pkgs.mdcat
  ];

  programs.zsh.initContent = lib.mkAfter ''
    function yy() {
      local tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
      yazi "$@" --cwd-file="$tmp"
      if cwd="$(cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
        builtin cd -- "$cwd"
      fi
      rm -f -- "$tmp"
    }
    alias rr=yy
  '';
}
