--- smart-enter: enter directories, open files.
-- Prevents yazi.nvim recursion: "open" on a dir with --chooser-file
-- writes the dir path and exits, causing open_for_directories to
-- spawn another yazi. "enter" only navigates dirs and ignores files.
-- This plugin bridges the gap.

local check = ya.sync(function()
	local h = cx.active.current.hovered
	return h and h.cha.is_dir
end)

return {
	entry = function()
		if check() then
			ya.mgr_emit("enter", {})
		else
			ya.mgr_emit("open", {})
		end
	end,
}
