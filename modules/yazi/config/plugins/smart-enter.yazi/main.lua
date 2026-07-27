--- smart-enter: enter directories, walk into containers, open files.
-- Prevents yazi.nvim recursion: "open" on a dir with --chooser-file
-- writes the dir path and exits, causing open_for_directories to
-- spawn another yazi. "enter" only navigates dirs and ignores files.
-- This plugin bridges the gap.
--
-- Disk images and archives route to archive-walk, which mounts or extracts them
-- and cds in, so one Enter key walks into everything that has an inside.

local walk = require("archive-walk")

-- Classify in a single sync hop — `walk.describe`/`walk.kind` are pure, so they
-- are safe here, and only the resulting string crosses the sync boundary.
local check = ya.sync(function()
	local h = cx.active.current.hovered
	if not h then
		return "none"
	elseif h.cha.is_dir then
		return "dir"
	end
	local d = walk.describe(h)
	return walk.kind(d.ext, d.is_dir) and "walk" or "file"
end)

return {
	entry = function()
		local what = check()
		if what == "dir" then
			ya.emit("enter", {})
		elseif what == "walk" then
			ya.emit("plugin", { "archive-walk" })
		elseif what == "file" then
			ya.emit("open", {})
		end
	end,
}
