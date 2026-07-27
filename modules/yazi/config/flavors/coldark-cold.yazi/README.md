# coldark-cold.yazi

Light-appearance flavor for this config. Not an upstream yazi flavor — assembled
here, because none was needed until `theme.toml` started following the macOS
appearance and the code preview became the one thing that could not.

| File | Origin |
|------|--------|
| `tmtheme.xml` | [ArmandPhilippot/coldark-bat](https://github.com/ArmandPhilippot/coldark-bat) `Coldark-Cold.tmTheme`, vendored **unmodified**. MIT — `LICENSE-tmtheme`. |
| `flavor.toml` | Written here, deliberately near-empty. See its header. |

## Why a flavor and not `syntect_theme`

`[mgr] syntect_theme` is documented as *"not available after using a flavor,
as flavors always use their own tmTheme files"*, and it accepts **absolute paths
only** — verified: neither `tmthemes/x.tmTheme` nor
`~/.config/yazi/tmthemes/x.tmTheme` resolves. An absolute path cannot serve both
the macOS out-of-store symlink into this repo and the servers, where
`home/profiles/server-tools-pro.nix` store-copies `config/yazi` to
`~/.config/yazi`. Flavors are referenced by name and resolved relative to the
config dir, so they are portable by construction.

## Why Coldark-Cold

Its background (`#e3eaf2`) is within a hair of Tokyo Night Day's terminal
background (`#e1e2e7`), and `bat` ships the same theme — the `.txt`/`.md`
previewers in `../../yazi.toml` point `--theme-light` at it, so yazi's syntect
path and the two bat paths agree in light mode instead of drifting.

## Not the family axis

`config/wezterm/common.lua` offers 14 theme families and the picker swaps
wezterm + tmux together. This pair is variant-correct (light preview on a light
background — the actual legibility bug) but **not** family-following: previews
stay Enki-Tokyo-Night / Coldark-Cold even when the terminal is gruvbox. Making
previews follow the family would need 14 flavor pairs. The UI chrome does follow
both axes, because `theme.toml` names ANSI roles rather than hexes.
