--- @since 26.1.22

-- Async immediate-child counter for the "count" linemode.
--
-- Counting directories synchronously inside `Linemode:count` froze the file
-- list on huge trees (e.g. /Users/Shared/projects): every visible folder hit
-- `fs.read_dir` on the render thread. This fetcher does that read off-thread,
-- once per directory, and stashes the immediate-child count on the plugin's
-- sync state via `ya.sync`. The linemode in init.lua only reads the cached
-- number, so rendering never touches the disk and never blocks.
--
-- State lives on this module table (`M.counts`); in the sync VM
-- `require("count").counts` is the same table `ya.sync` writes to, the way
-- git.yazi shares `st`.

local M = { counts = {} }

-- Runs in the sync thread; `st` is this plugin's persistent state (== M).
local set_count = ya.sync(function(st, url, n)
	st.counts = st.counts or {}
	if st.counts[url] ~= n then
		st.counts[url] = n
		ui.render()
	end
end)

---@type UnstableFetcher
function M:fetch(job)
	for _, file in ipairs(job.files) do
		if file.cha.is_dir then
			-- Immediate children only — no recursion. Limit caps cost on
			-- pathological directories; the count just saturates there.
			local files = fs.read_dir(file.url, { limit = 100000 })
			set_count(tostring(file.url), files and #files or -1)
		end
	end
	return false
end

return M
