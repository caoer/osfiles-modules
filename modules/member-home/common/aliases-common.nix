# Cross-platform zsh aliases (mac + servers).
_: {
  programs.zsh.shellGlobalAliases = {
    C = "| pbcopy";
  };

  programs.zsh.shellAliases = {
    fj = "fj -H git.0xdao.app";
    tt = "ucc-auto";

    c = "tput clear";

    ".." = "cd ..";
    "..." = "cd ../..";
    "...." = "cd ../../..";
    "....." = "cd ../../../..";
    "......" = "cd ../../../../..";
  };
}
