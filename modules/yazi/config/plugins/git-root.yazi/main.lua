local get_cwd = ya.sync(function()
	return tostring(cx.active.current.cwd)
end)

local get_hovered = ya.sync(function()
	local h = cx.active.current.hovered
	return h and tostring(h.url) or nil
end)

return {
	-- cd to the farthest git ancestor (project root); with the `copy` arg,
	-- copy the hovered file's path relative to that root instead (c C).
	entry = function(self, job)
		local cwd = get_cwd()

		-- Walk up to find farthest git ancestor (project root)
		local root = nil
		local dir = cwd
		while dir ~= "/" and dir ~= "" do
			local cha = fs.cha(Url(dir .. "/.git"))
			if cha then
				root = dir
			end
			dir = dir:match("(.+)/[^/]*$") or "/"
		end

		if not root then
			return ya.notify { title = "git-root", content = "Not inside a git repo", timeout = 3, level = "warn" }
		end

		if job.args[1] == "copy" then
			local hovered = get_hovered()
			if not hovered then
				return ya.notify { title = "git-root", content = "Nothing hovered", timeout = 3, level = "warn" }
			end
			local rel = hovered:sub(#root + 2)
			ya.clipboard(rel)
			ya.notify { title = "git-root", content = "Copied: " .. rel, timeout = 2, level = "info" }
		else
			ya.emit("cd", { root })
		end
	end,
}
