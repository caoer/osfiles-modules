--- @since 26.1.22
-- Layout cycle plugin: Tab cycles through layout modes.
-- On terminal resize, snaps back to "responsive".

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

return M
