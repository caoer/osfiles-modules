# Local patches on vendored plugins

Every plugin here is committed to this repo, and yazi loads them straight off
disk. `../package.toml` is not read by yazi — only by `ya pkg`, which uses it to
re-fetch upstream. The plugins are the source of truth; the manifest is an
update tool.

`ya pkg` rewrites `package.toml` on every `add` and `upgrade`, stripping any
comment in it. That is why this note lives in a file `ya pkg` never touches.

## The patches are files, not prose

`patches/<plugin>/NNN-slug.diff` holds each local change, and
`patches/apply.sh` puts them back. Nobody has to remember what was patched:

    ya pkg upgrade --discard wylie102/duckdb
    plugins/patches/apply.sh
    git diff

`apply.sh` is idempotent — a patch already present is reported, not applied
twice — so it is safe to run after any upgrade, discarded or not. `--check` is a
dry run. A patch that no longer applies is reported `FAILED` and the script
exits non-zero, which is the signal that upstream rewrote those lines and the
patch needs re-deriving rather than forcing.

Patches apply in filename order, and each was generated against the state its
predecessor leaves behind, so `git apply` lands them with no fuzz.

`ya pkg` deploys plugin files read-only (0444), so `apply.sh` makes the plugin
writable first. Git records only the execute bit, so that mode change is
invisible to the repo.

## Why `--discard` is needed at all

`ya pkg upgrade` hashes each deployed plugin against `package.toml` and aborts
the whole run when it finds local edits:

    You have modified the contents of the `lazygit.yazi` plugin.
    For safety, the operation has been aborted.

So patches can never be lost silently. The cost is that a patched plugin never
upgrades on its own, and a bare `ya pkg upgrade` stops at the first one it
meets. Pass explicit ids to sweep the unpatched rest:

    ya pkg upgrade yazi-rs/plugins:piper yazi-rs/plugins:git yazi-rs/plugins:chmod

## What is patched

Two plugins, four changes. Verified by installing every pinned revision into a
scratch `YAZI_CONFIG_HOME` and diffing — the other five plugins and the flavor
came back byte-identical.

| Patch | Why | Origin |
| -- | -- | -- |
| `duckdb.yazi/001-sqlite-extension-map` | map `sqlite` and `sqlite3` to the duckdb handler, so those files preview at all | `551161d9` |
| `duckdb.yazi/002-readonly-existing-database` | `-readonly` on the database branch, so opening a file to look at it never checkpoints its WAL | `0944a7a7` |
| `duckdb.yazi/003-no-init-on-previews` | `-no-init`, because `output_is_valid()` treats any stderr as fatal and a `.duckdbrc` makes the CLI log to stderr, killing every preview | `dcedbc47` |
| `lazygit.yazi/001-lg-config-overlay` | `LG_CONFIG_FILE` overlay, so lazygit draws a distinct border when launched from yazi | `308f8080` |

`archive-walk.yazi`, `audio-preview.yazi`, `count.yazi`, `git-root.yazi`,
`layout-cycle.yazi`, `smart-enter.yazi` and `video-montage.yazi` are written
here. They have no upstream, are absent from `package.toml`, and need no
patches — edit them directly.

`fg.yazi` is the one in between: it carries upstream provenance (LICENSE,
README) but is absent from `package.toml`, so `ya pkg` neither hashes nor
re-fetches it. It is therefore edited directly too, and a patch file for it
would never be applied by `apply.sh`. Its colors are ANSI role names rather
than the upstream hexes, for the reason given in `../theme.toml`.

## Recording a new patch

Edit the vendored plugin in place, then capture the change with `--relative`,
which emits the `a/main.lua` paths `apply.sh` expects:

    git -C plugins/duckdb.yazi diff --relative --no-ext-diff \
      > plugins/patches/duckdb.yazi/004-slug.diff

Number it after the existing patches so it applies last, on top of them.

## Reviewing an upgrade

On macOS `~/.config/yazi` is an out-of-store symlink into this repo, so
`ya pkg upgrade` writes into the working tree and `git diff` is the review step.
Check the diff for API-shaped changes against the pinned yazi before committing
— upstream targets nightly, and a plugin may adopt a binding this yazi lacks.

To fetch upstream without touching the live config, point `ya` at a scratch
config home and compare by hand:

    YAZI_CONFIG_HOME=/tmp/yz ya pkg install
    diff -u plugins/duckdb.yazi/main.lua /tmp/yz/plugins/duckdb.yazi/main.lua
