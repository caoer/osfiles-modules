-- Mason reset: nuke corrupted state and reinstall all packages.
-- Usage: :MasonReset
--
-- Reads installed packages from mason receipts before cleanup,
-- removes the entire mason directory, then reinstalls everything.

vim.api.nvim_create_user_command("MasonReset", function()
	local mason_dir = vim.fn.stdpath("data") .. "/mason"

	-- 1. Collect installed package names from directory listing
	local packages_dir = mason_dir .. "/packages"
	local installed = {}
	local handle = vim.uv.fs_scandir(packages_dir)
	if handle then
		while true do
			local name, type = vim.uv.fs_scandir_next(handle)
			if not name then
				break
			end
			if type == "directory" then
				table.insert(installed, name)
			end
		end
	end

	if #installed == 0 then
		vim.notify("No Mason packages found to reinstall.", vim.log.levels.WARN)
		return
	end

	local pkg_list = table.concat(installed, ", ")
	vim.notify("Found " .. #installed .. " packages: " .. pkg_list, vim.log.levels.INFO)

	-- 2. Remove mason directory entirely
	vim.fn.delete(mason_dir, "rf")
	vim.notify("Removed " .. mason_dir, vim.log.levels.INFO)

	-- 3. Reload mason so it recreates directory structure
	require("lazy").load({ plugins = { "mason.nvim" } })

	-- 4. Reinstall all packages
	vim.notify("Reinstalling: " .. pkg_list, vim.log.levels.INFO)
	vim.cmd("MasonInstall " .. table.concat(installed, " "))
end, { desc = "Remove all Mason state and reinstall packages" })
