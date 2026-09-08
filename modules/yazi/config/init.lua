-- Layout cycle: Tab cycles modes (responsive → preview → list), resize snaps
-- back to responsive. The Tab:layout override lives in the plugin's setup().
require("layout-cycle"):setup()

-- Folder file-count linemode (files show size). Counts are computed off the
-- render thread by the plugin's async fetcher; the linemode installed by
-- setup() only reads the cache, so rendering never does directory I/O.
require("count"):setup()

-- DuckDB plugin configuration
require("duckdb"):setup()

require("zoxide"):setup {
	update_db = true,
}

-- Git sign styling lives in theme.toml [git] (first-class plugin styles,
-- #3934) — the old th.git.* Lua assignments broke under app:theme hot-reload
-- and would hard-error once any [git] section existed. The filename recolor
-- below stays in Lua: there is no declarative equivalent for Entity:style.
local git = require("git")
git:setup {
	-- Order of status signs showing in the linemode
	order = 1500,
}

-- Recolor filenames ONLY for tracked changes. Codes from git.yazi:
-- updated=1, deleted=2, added=3, modified=4, untracked=5, ignored=6, clean=0.
-- 5/6/0 are intentionally absent → untracked/ignored/clean keep filetype color.
-- ANSI role names, not hexes: these recolor filenames in the file list, so
-- hex colors tuned for one appearance would be unreadable in the other. Named
-- colors resolve through the terminal palette, which the terminal swaps per
-- appearance — see the header comment in theme.toml. Kept in sync with
-- theme.toml [git].
local git_filename_styles = {
	[4] = ui.Style():fg("blue"),   -- modified
	[3] = ui.Style():fg("green"),  -- added
	[2] = ui.Style():fg("red"),    -- deleted
	[1] = ui.Style():fg("cyan"),   -- updated/staged
}

local entity_style = Entity.style
function Entity:style()
	local s = entity_style(self)
	if not git.dirs then
		return s
	end

	local url = self._file.url
	local parent = tostring(url.base or url.parent)
	local repo = git.dirs[parent]
	if not repo then
		return s
	end
	-- 99 = excluded directory, treat as ignored
	if repo == 99 then
		return s:patch(git_filename_styles[6] or ui.Style())
	end

	local code = git.repos[repo] and git.repos[repo][tostring(url):sub(#repo + 2)]
	if code and git_filename_styles[code] then
		return s:patch(git_filename_styles[code])
	end

	return s
end
