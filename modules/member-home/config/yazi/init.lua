-- Layout cycle: Tab cycles modes, resize snaps back to responsive
local layout_cycle = require("layout-cycle")

function Tab:layout()
	local ratio = rt.mgr.ratio
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
				ui.Constraint.Ratio(0, ratio.all),
				ui.Constraint.Ratio(2, ratio.all),
				ui.Constraint.Ratio(ratio.all - 2, ratio.all),
			})
			:split(self._area)
	elseif mode == "list" then
		-- Wide file list, no preview
		self._chunks = ui.Layout()
			:direction(ui.Layout.HORIZONTAL)
			:constraints({
				ui.Constraint.Ratio(ratio.parent, ratio.all),
				ui.Constraint.Ratio(ratio.current + ratio.preview, ratio.all),
				ui.Constraint.Ratio(0, ratio.all),
			})
			:split(self._area)
	elseif w > 100 then
		-- Responsive: full 3-column
		self._chunks = ui.Layout()
			:direction(ui.Layout.HORIZONTAL)
			:constraints({
				ui.Constraint.Ratio(ratio.parent, ratio.all),
				ui.Constraint.Ratio(ratio.current, ratio.all),
				ui.Constraint.Ratio(ratio.preview, ratio.all),
			})
			:split(self._area)
	elseif w > 60 then
		-- Responsive: hide parent
		self._chunks = ui.Layout()
			:direction(ui.Layout.HORIZONTAL)
			:constraints({
				ui.Constraint.Ratio(0, ratio.all),
				ui.Constraint.Ratio(ratio.current + ratio.parent, ratio.all),
				ui.Constraint.Ratio(ratio.preview, ratio.all),
			})
			:split(self._area)
	else
		-- Responsive: single column
		self._chunks = ui.Layout()
			:direction(ui.Layout.HORIZONTAL)
			:constraints({
				ui.Constraint.Ratio(0, ratio.all),
				ui.Constraint.Ratio(ratio.all, ratio.all),
				ui.Constraint.Ratio(0, ratio.all),
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

th.git = th.git or {}
th.git.modified = ui.Style():fg("blue")
th.git.added = ui.Style():fg("green")
th.git.untracked = ui.Style():fg("yellow")
th.git.ignored = ui.Style():fg("#666666")
th.git.deleted = ui.Style():fg("red"):bold()
th.git.updated = ui.Style():fg("cyan")
th.git.unknown = ui.Style():fg("#666666")
th.git.clean = ui.Style():fg("green")

th.git.modified_sign = "~"
th.git.added_sign = "+"
th.git.untracked_sign = "?"
th.git.ignored_sign = "‒"
th.git.deleted_sign = "✗"
th.git.updated_sign = "↑"
th.git.unknown_sign = "·"
th.git.clean_sign = " "

local git = require("git")
git:setup {
	-- Order of status signs showing in the linemode
	order = 1500,
}

-- Color filenames based on git status
-- Status codes from git.yazi: ignored=6, untracked=5, modified=4, added=3, deleted=2, updated=1
local git_filename_styles = {
	[6] = ui.Style():fg("#666666"),   -- ignored
	[5] = ui.Style():fg("#f9e2af"),   -- untracked (yellow)
	[4] = ui.Style():fg("#89b4fa"),   -- modified (blue)
	[3] = ui.Style():fg("#a6e3a1"),   -- added (green)
	[2] = ui.Style():fg("#f38ba8"),   -- deleted (red)
	[1] = ui.Style():fg("#94e2d5"),   -- updated (cyan)
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