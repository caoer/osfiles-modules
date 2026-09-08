--- @since 26.1.22

-- Async immediate-child counter for the "count" linemode.
--
-- Counting directories synchronously inside `Linemode:count` froze the file
-- list on huge trees: every visible folder hit `fs.read_dir` on the render
-- thread. This fetcher does that read off-thread, once per directory, and
-- stashes the immediate-child count on the plugin's sync state via `ya.sync`.
-- The linemode installed by `setup()` only reads the cached number, so
-- rendering never touches the disk and never blocks.
--
-- Wire it up with:
--   init.lua:  require("count"):setup()
--   yazi.toml: [mgr] linemode = "count", plus the "count" fetcher on "*/"
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
	-- yazi >= 26.8.15 takes a coroutine yielding one state per file and
	-- rejects a boolean ("error converting Lua boolean to function"); 26.5.6
	-- takes the boolean (ya.co exists on both, so it cannot discriminate).
	-- The preset noop fetcher returns whatever shape this binary's runner
	-- takes — mirror it. `false` on the old runner meant "run again later",
	-- which is `retry` on the new one (upstream git.yazi made the same move).
	if type(require("noop"):fetch(job)) == "function" then
		return ya.co(function()
			for _, file in ipairs(job.files) do
				coroutine.yield(file, { retry = true })
			end
		end)
	end
	return false
end

function M:setup()
	-- Folder file-count linemode: dirs show immediate child count (async,
	-- from the fetcher's cache), files show size.
	function Linemode:count()
		local file = self._file
		if not file.cha.is_dir then
			local size = file:size()
			return size and ya.readable_size(size) or ""
		end

		local n = M.counts[tostring(file.url)]
		return (n and n >= 0) and tostring(n) or ""
	end
end

return M
