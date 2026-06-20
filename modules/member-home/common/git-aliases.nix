# Portable oh-my-zsh-style git shortcut aliases. Pure zsh text, no closure cost.
_: {
  programs.zsh.shellAliases = {
    # Basic
    g = "git";
    ga = "git add";
    gaa = "git add --all";
    gapa = "git add --patch";
    gau = "git add --update";
    gav = "git add --verbose";
    gap = "git apply";
    gapt = "git apply --3way";

    # Branch
    gb = "git branch";
    gba = "git branch --all";
    gbd = "git branch --delete";
    gbD = "git branch --delete --force";
    gbr = "git branch --remote";
    gbnm = "git branch --no-merged";
    gbm = "git branch --move";

    # Bisect
    gbs = "git bisect";
    gbsb = "git bisect bad";
    gbsg = "git bisect good";
    gbsr = "git bisect reset";
    gbss = "git bisect start";

    # Commit
    gc = "git commit --verbose";
    "gc!" = "git commit --verbose --amend";
    "gcn!" = "git commit --verbose --no-edit --amend";
    gca = "git commit --verbose --all";
    "gca!" = "git commit --verbose --all --amend";
    "gcan!" = "git commit --verbose --all --no-edit --amend";
    gcam = "git commit --all --message";
    gcsm = "git commit --signoff --message";
    gcas = "git commit --all --signoff";
    gcasm = "git commit --all --signoff --message";
    gcf = "git config --list";
    gcmsg = "git commit --message";

    # Checkout
    gco = "git checkout";
    gcom = "git checkout \$(gdb)";
    gcor = "git checkout --recurse-submodules";
    gcod = "git checkout --detach";

    # Cherry-pick
    gcp = "git cherry-pick";
    gcpa = "git cherry-pick --abort";
    gcpc = "git cherry-pick --continue";

    # Clone
    gcl = "git clone --recurse-submodules";
    gclean = "git clean --interactive -d";

    # Diff
    gd = "git diff";
    gdca = "git diff --cached";
    gdcw = "git diff --cached --word-diff";
    gds = "git diff --staged";
    gdt = "git diff-tree --no-commit-id --name-only -r";
    gdw = "git diff --word-diff";
    gdv = "git diff -w \$@ | view -";

    # Fetch
    gf = "git fetch";
    gfa = "git fetch --all --prune";
    gfo = "git fetch origin";

    # Flow
    gfl = "git flow";
    gflf = "git flow feature";
    gflh = "git flow hotfix";
    gflr = "git flow release";

    # Grep
    gg = "git grep";
    gga = "git grep --all";

    # GUI
    ggui = "git gui citool";
    gguitka = "git gui citool --amend";

    # Log
    gl = "git log --stat";
    glg = "git log --stat --graph";
    glgp = "git log --stat --patch";
    glo = "git log --oneline --decorate";
    glog = "git log --oneline --decorate --graph";
    gloga = "git log --oneline --decorate --graph --all";
    glol = "git log --graph --pretty='%Cred%h%Creset -%C(auto)%d%Creset %s %Cgreen(%ar) %C(bold blue)<%an>%Creset'";
    glola = "git log --graph --pretty='%Cred%h%Creset -%C(auto)%d%Creset %s %Cgreen(%ar) %C(bold blue)<%an>%Creset' --all";
    glols = "git log --graph --pretty='%Cred%h%Creset -%C(auto)%d%Creset %s %Cgreen(%ar) %C(bold blue)<%an>%Creset' --stat";
    glod = "git log --graph --pretty='%Cred%h%Creset -%C(auto)%d%Creset %s %Cgreen(%ad) %C(bold blue)<%an>%Creset'";

    # Merge
    gm = "git merge";
    gmom = "git merge origin/\$(gdb)";
    gmtl = "git mergetool --no-prompt";
    gmtlvim = "git mergetool --no-prompt --tool=vimdiff";
    gma = "git merge --abort";

    # Push
    gp = "git push";
    gpd = "git push --dry-run";
    gpf = "git push --force-with-lease";
    "gpf!" = "git push --force";
    gpoat = "git push origin --all && git push origin --tags";
    gpod = "git push origin --delete";
    gpr = "git pull --rebase";
    gpv = "git push --verbose";

    # Pull
    gpl = "git pull";

    # Rebase
    grb = "git rebase";
    grba = "git rebase --abort";
    grbc = "git rebase --continue";
    grbd = "git rebase \$(gdb)";
    grbi = "git rebase --interactive";
    grbm = "git rebase \$(gdb)";
    grbo = "git rebase --onto";
    grbs = "git rebase --skip";

    # Remote
    gr = "git remote";
    gra = "git remote add";
    grav = "git remote --verbose";
    grrm = "git remote remove";
    grmv = "git remote rename";
    grpo = "git remote prune origin";
    grset = "git remote set-url";
    grup = "git remote update";
    grv = "git remote --verbose";

    # Reset
    grh = "git reset";
    grhh = "git reset --hard";
    groh = "git reset origin/\$(gcb) --hard";

    # Restore
    grs = "git restore";
    grss = "git restore --source";
    grst = "git restore --staged";

    # Revert
    grev = "git revert";

    # Remove
    grm = "git rm";
    grmc = "git rm --cached";

    # Show
    gsh = "git show";
    gsps = "git show --pretty=short --show-signature";

    # Stash
    gsta = "git stash push";
    gstaa = "git stash apply";
    gstc = "git stash clear";
    gstd = "git stash drop";
    gstl = "git stash list";
    gstp = "git stash pop";
    gsts = "git stash show --text";
    gstu = "git stash --include-untracked";
    gstall = "git stash --all";

    # Status
    gst = "git status";
    gws = "git status";
    gss = "git status --short";
    gsb = "git status --short --branch";

    # Submodule
    gsi = "git submodule init";
    gsu = "git submodule update";

    # Switch
    gsw = "git switch";
    gswc = "git switch --create";
    gswm = "git switch \$(gdb)";

    # Tag
    gts = "git tag --sign";
    gtv = "git tag | sort -V";
    gtl = "git tag --list";

    # Update
    gup = "git pull --rebase";
    gupv = "git pull --rebase --verbose";
    gupa = "git pull --rebase --autostash";
    gupav = "git pull --rebase --autostash --verbose";

    # Whatchanged
    gwch = "git whatchanged -p --abbrev-commit --pretty=medium";

    # Worktree
    gwt = "git worktree";
    gwta = "git worktree add";
    gwtls = "git worktree list";
    gwtmv = "git worktree move";
    gwtrm = "git worktree remove";

    # Extras
    gpo = "git push -u origin";
    gpoh = "git push origin HEAD:master";
    gcamc = "gcam '[WIP] - 🚧'";
    gcount = "git rev-list --all | wc -l";
    gnotes = "git log --oneline --no-merges";

    # GitHub CLI
    h = "gh";
    hb = "gh browse";
  };
}
