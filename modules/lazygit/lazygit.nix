{ config, lib, pkgs, ... }:
let
  cfg = config.osf.lazygit;
in
{
  options.osf.lazygit = {
    enable = lib.mkEnableOption "lazygit";
  };

  config = lib.mkIf cfg.enable {
    programs.lazygit = {
      enable = true;
      settings = {
        gui = {
          splitDiff = "always";
          sidePanelWidth = 0.26;
          expandFocusedSidePanel = true;
          # Palette-indexed ANSI names, not frozen hex. lazygit rides the
          # terminal's active scheme (wezterm switches it per theme-family +
          # macOS light/dark), so these follow every theme and repaint live on
          # a switch. `default` = terminal fg, `reverse` = adaptive high-contrast
          # selection — the two that made hardcoded hex unreadable in light mode.
          theme = {
            activeBorderColor = [ "cyan" "bold" ];
            inactiveBorderColor = [ "default" ];
            optionsTextColor = [ "blue" ];
            selectedLineBgColor = [ "reverse" ];
            cherryPickedCommitBgColor = [ "cyan" ];
            cherryPickedCommitFgColor = [ "black" ];
            unstagedChangesColor = [ "red" ];
            defaultFgColor = [ "default" ];
            searchingActiveBorderColor = [ "yellow" ];
          };
        };
        promptToReturnFromSubprocess = false;
        os = {
          editPreset = "nvim";
        };
        git = {
          mainBranches = [ "main" ];
          autoFetch = true;
          autoRefresh = true;
          pagers = [
            {
              colorArg = "always";
              pager = "";
            }
          ];
        };
        keybinding = {
          universal = {
            quit = "q";
            quit-alt1 = "<c-c>";
            return = "<esc>";
            quitWithoutChangingDirectory = "Q";
            togglePanel = "<tab>";
            prevItem = "<up>";
            nextItem = "<down>";
            prevItem-alt = "k";
            nextItem-alt = "j";
            prevPage = ",";
            nextPage = ".";
            scrollLeft = "H";
            scrollRight = "L";
            gotoTop = "<";
            gotoBottom = ">";
            toggleRangeSelect = "v";
            rangeSelectDown = "<s-down>";
            rangeSelectUp = "<s-up>";
            prevBlock = "<left>";
            nextBlock = "<right>";
            prevBlock-alt = "h";
            nextBlock-alt = "l";
            nextBlock-alt2 = "<tab>";
            prevBlock-alt2 = "<backtab>";
            jumpToBlock = [ "1" "2" "3" "4" "5" ];
            nextMatch = "n";
            prevMatch = "N";
            startSearch = "/";
            optionMenu = "x";
            optionMenu-alt1 = "?";
            select = "<space>";
            goInto = "<enter>";
            confirm = "<enter>";
            remove = "d";
            new = "n";
            edit = "e";
            openFile = "o";
            scrollUpMain = "<pgup>";
            scrollDownMain = "<pgdown>";
            scrollUpMain-alt1 = "K";
            scrollDownMain-alt1 = "J";
            scrollUpMain-alt2 = "<c-u>";
            scrollDownMain-alt2 = "<c-d>";
            executeShellCommand = ":";
            createRebaseOptionsMenu = "m";
            pushFiles = "P";
            pullFiles = "p";
            refresh = "R";
            createPatchOptionsMenu = "<c-p>";
            nextTab = "]";
            prevTab = "[";
            nextScreenMode = "+";
            prevScreenMode = "_";
            undo = "z";
            redo = "Z";
            suspendApp = "<c-z>";
            filteringMenu = "<c-s>";
            diffingMenu = "W";
            diffingMenu-alt = "<c-e>";
            copyToClipboard = "<c-o>";
            openRecentRepos = "<c-r>";
            submitEditorText = "<enter>";
            extrasMenu = "@";
            toggleWhitespaceInDiffView = "<c-w>";
            increaseContextInDiffView = "}";
            decreaseContextInDiffView = "{";
          };
        };
        customCommands = [
          {
            key = "Y";
            description = "Back to yazi (with selected file)";
            context = "files";
            command = "printf '%s/%s' \"$(git rev-parse --show-toplevel)\" \"{{.SelectedFile.Name}}\" > /tmp/lazygit-yazi-selected; kill $(pgrep -n lazygit)";
          }
          {
            key = "Y";
            description = "Back to yazi (with selected commit file)";
            context = "commitFiles";
            command = "printf '%s/%s' \"$(git rev-parse --show-toplevel)\" \"{{.SelectedCommitFile.Name}}\" > /tmp/lazygit-yazi-selected; kill $(pgrep -n lazygit)";
          }
          {
            key = "Y";
            description = "Back to yazi (with selected worktree)";
            context = "worktrees";
            command = "echo \"{{.SelectedWorktree.Path}}\" > /tmp/lazygit-yazi-selected; kill $(pgrep -n lazygit)";
          }
          {
            key = "Y";
            description = "Back to yazi";
            context = "global";
            command = "git rev-parse --show-toplevel > /tmp/lazygit-yazi-selected; kill $(pgrep -n lazygit)";
          }
          {
            key = "<c-g>";
            context = "worktrees";
            description = "Show PR info for this worktree";
            command = "gh pr view \"{{.SelectedWorktree.Branch}}\" --json number,title,state,url,isDraft,reviewDecision --jq '\"#\\(.number) \\(.title)\\nState: \\(.state)\\nDraft: \\(.isDraft)\\nReview: \\(.reviewDecision)\\nURL: \\(.url)\"'";
            output = "popup";
          }
          {
            key = "<c-a>";
            context = "worktrees";
            description = "List all worktrees with PR numbers";
            command = "for wt in $(git worktree list --porcelain | grep '^branch refs/heads/' | sed 's|branch refs/heads/||'); do pr_info=$(gh pr view \"$wt\" --json number,state,title --jq '\"#\\(.number) [\\(.state)] \\(.title)\"' 2>/dev/null); if [ -n \"$pr_info\" ]; then printf \"%-30s %s\\n\" \"$wt\" \"$pr_info\"; else printf \"%-30s %s\\n\" \"$wt\" \"(no PR)\"; fi; done";
            output = "popup";
          }
          {
            key = "<c-g>";
            context = "localBranches";
            description = "Show PR info for this branch";
            command = "gh pr view \"{{.SelectedLocalBranch.Name}}\" --json number,title,state,url,isDraft,reviewDecision --jq '\"#\\(.number) \\(.title)\\nState: \\(.state)\\nDraft: \\(.isDraft)\\nReview: \\(.reviewDecision)\\nURL: \\(.url)\"'";
            output = "popup";
          }
        ];
      };
    };

    programs.zsh.initContent = lib.mkAfter ''
      lg() {
        export LAZYGIT_NEW_DIR_FILE=~/.lazygit/newdir
        lazygit "$@"
        if [ -f "$LAZYGIT_NEW_DIR_FILE" ]; then
          cd "$(cat "$LAZYGIT_NEW_DIR_FILE")"
          rm -f "$LAZYGIT_NEW_DIR_FILE" > /dev/null
        fi
      }
    '';

    xdg.configFile."lazygit/yazi.yml".source = ./yazi.yml;
  };
}
