--- @since 26.1.22
-- Layout cycle plugin: Tab cycles through layout modes.
-- On terminal resize, snaps back to "responsive".
--
-- `setup()` installs the `Tab:layout` override; `entry()` cycles the mode.
-- Wire it up with:
--   init.lua:    require("layout-cycle"):setup()
--   keymap.toml: { on = ["<Tab>"], run = "plugin layout-cycle" }

local M = {}

-- Modes: responsive (auto by width), preview (big preview), list (no preview)
M.mode = "responsive"
M.last_width = 0

local modes = { "responsive", "preview", "list" }

local cycle = ya.sync(function(st)
	local current = M.mode
	for i, m in ipairs(modes) do
		if m == current then
			M.mode = modes[(i % #modes) + 1]
			break
		end
	end
	ui.render()
	return M.mode
end)

function M:entry()
	local new_mode = cycle()
	ya.notify {
		title = "Layout",
		content = new_mode,
		timeout = 1.5,
		level = "info",
	}
end

function M:setup()
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
		if w ~= M.last_width then
			M.mode = "responsive"
			M.last_width = w
		end

		local mode = M.mode

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
end

return M
