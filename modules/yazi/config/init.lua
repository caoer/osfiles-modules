-- Layout cycle: Tab cycles modes, resize snaps back to responsive
local layout_cycle = require("layout-cycle")

function Tab:layout()
	-- Dual-compat ratio access: nightly indexes the tuple (named fields fire a
	-- per-frame deprecation), stable serializes named fields ([1] is nil there).
	local ratio = rt.mgr.ratio
	local par = ratio[1] or ratio.parent
	local cur = ratio[2] or ratio.current
	local pre = ratio[3] or ratio.preview
	local all = par + cur + pre
	local w = self._area.w

	-- Reset to responsive on terminal resize
	if w ~= layout_cycle.last_width then
		layout_cycle.mode = "responsive"
		layout_cycle.last_width = w
	end

	local mode = layout_cycle.mode

	if mode == "preview" then
		-- Skinny file list + big preview
		self._chunks = ui.Layout()
			:direction(ui.Layout.HORIZONTAL)
			:constraints({
				ui.Constraint.Ratio(0, all),
				ui.Constraint.Ratio(2, all),
				ui.Constraint.Ratio(all - 2, all),
			})
			:split(self._area)
	elseif mode == "list" then
		-- Wide file list, no preview
		self._chunks = ui.Layout()
			:direction(ui.Layout.HORIZONTAL)
			:constraints({
				ui.Constraint.Ratio(par, all),
				ui.Constraint.Ratio(cur + pre, all),
				ui.Constraint.Ratio(0, all),
			})
			:split(self._area)
	elseif w > 100 then
		-- Responsive: full 3-column
		self._chunks = ui.Layout()
			:direction(ui.Layout.HORIZONTAL)
			:constraints({
				ui.Constraint.Ratio(par, all),
				ui.Constraint.Ratio(cur, all),
				ui.Constraint.Ratio(pre, all),
			})
			:split(self._area)
	elseif w > 60 then
		-- Responsive: hide parent
		self._chunks = ui.Layout()
			:direction(ui.Layout.HORIZONTAL)
			:constraints({
				ui.Constraint.Ratio(0, all),
				ui.Constraint.Ratio(cur + par, all),
				ui.Constraint.Ratio(pre, all),
			})
			:split(self._area)
	else
		-- Responsive: single column
		self._chunks = ui.Layout()
			:direction(ui.Layout.HORIZONTAL)
			:constraints({
				ui.Constraint.Ratio(0, all),
				ui.Constraint.Ratio(all, all),
				ui.Constraint.Ratio(0, all),
			})
			:split(self._area)
	end
end

-- Folder file-count linemode (files show size).
-- Directory counts are computed off the render thread by the `count` plugin's
-- async fetcher and cached in `count.counts`; here we only read that cache, so
-- rendering never does directory I/O. Counting synchronously here froze the
-- file list on huge trees (e.g. /Users/Shared/projects).
local count = require("count")
function Linemode:count()
	local file = self._file
	if not file.cha.is_dir then
		local size = file:size()
		return size and ya.readable_size(size) or ""
	end

	local n = count.counts[tostring(file.url)]
	return (n and n >= 0) and tostring(n) or ""
end

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
-- ANSI role names, not hexes: these recolor filenames in the file list, so the
-- Mocha hexes they used to carry were the same 1.2:1-on-light problem theme.toml
-- had. Named colors resolve through the terminal palette, which wezterm swaps
-- per appearance — see the header comment in theme.toml. Kept in sync with
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