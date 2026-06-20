local get_cwd = ya.sync(function()
	return tostring(cx.active.current.cwd)
end)

return {
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

		if root then
			ya.mgr_emit("cd", { root })
		else
			ya.notify { title = "git-root", content = "Not inside a git repo", timeout = 3, level = "warn" }
		end
	end,
}
