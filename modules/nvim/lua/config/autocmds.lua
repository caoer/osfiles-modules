-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
-- Add any additional autocmds here

-- Disable diagnostics for markdown files
vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
	pattern = { "*.md" },
	callback = function()
		vim.diagnostic.enable(false, { bufnr = 0 })
	end,
})

-- macOS Sequoia: codesign treesitter parser .so files.
-- Without signing, macOS kills nvim with SIGKILL (exit 137) due to
-- "Code Signature Invalid" when dlopen'ing parser shared libraries.
-- Run :TSCodesign after :TSUpdate, or it runs automatically on VimEnter.
if vim.fn.has("mac") == 1 then
	local function sign_treesitter_parsers()
		local parser_dir = vim.fn.stdpath("data") .. "/site/parser"
		local handle = io.popen('ls "' .. parser_dir .. '"/*.so 2>/dev/null | head -1')
		if handle then
			local first = handle:read("*l")
			handle:close()
			if first then
				vim.fn.jobstart(
					{ "sh", "-c", 'for f in "' .. parser_dir .. '"/*.so; do codesign -f -s - "$f" 2>/dev/null; done' },
					{ detach = true }
				)
			end
		end
	end

	vim.api.nvim_create_user_command("TSCodesign", function()
		sign_treesitter_parsers()
		vim.notify("Signing treesitter parsers...")
	end, { desc = "Codesign treesitter parser .so files (macOS)" })

	vim.api.nvim_create_autocmd("VimEnter", {
		callback = function()
			-- Quick check: verify one parser; if invalid, re-sign all
			local parser_dir = vim.fn.stdpath("data") .. "/site/parser"
			local result = vim.fn.system("codesign --verify " .. parser_dir .. "/lua.so 2>&1")
			if vim.v.shell_error ~= 0 then
				sign_treesitter_parsers()
			end
		end,
	})
end

-- Mason reset command (:MasonReset)
require("config.mason-reset")

-- TOML files: use marker folding (# section {{{ / # }}})
vim.api.nvim_create_autocmd("FileType", {
	pattern = "toml",
	callback = function()
		vim.opt_local.foldmethod = "marker"
		vim.opt_local.foldlevel = 0 -- start collapsed
	end,
})

-- Reorganize profiles.toml on save: group by namespace, sort by name A-Z
vim.api.nvim_create_autocmd("BufWritePre", {
	pattern = "*/zt-browsers/profiles.toml",
	callback = function()
		local buf_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

		-- Parse all [[profiles]] blocks (ignore fold markers and blank lines)
		local profiles = {}
		local current = nil
		for _, line in ipairs(buf_lines) do
			local is_marker = line:match("^# .+ %(%d+%) {{{$") or line:match("^# }}}$")
			if not is_marker then
				if line:match("^%[%[profiles%]%]$") then
					if current then
						table.insert(profiles, current)
					end
					current = { lines = { line }, name = "", namespace = "" }
				elseif current then
					if line ~= "" then
						table.insert(current.lines, line)
						local ns = line:match('^namespace%s*=%s*"([^"]*)"')
						if ns then
							current.namespace = ns
						end
						local nm = line:match('^name%s*=%s*"([^"]*)"')
						if nm then
							current.name = nm
						end
					end
				end
			end
		end
		if current then
			table.insert(profiles, current)
		end

		if #profiles == 0 then
			return
		end

		-- Group by namespace
		local groups = {}
		local ns_order = {}
		for _, p in ipairs(profiles) do
			local ns = p.namespace
			if not groups[ns] then
				groups[ns] = {}
				table.insert(ns_order, ns)
			end
			table.insert(groups[ns], p)
		end

		-- Sort namespace keys: named ones alphabetically, "" (ungrouped) last
		table.sort(ns_order, function(a, b)
			if a == "" then
				return false
			end
			if b == "" then
				return true
			end
			return a:lower() < b:lower()
		end)

		-- Sort profiles within each group by name A-Z
		for _, ns in ipairs(ns_order) do
			table.sort(groups[ns], function(a, b)
				return a.name:lower() < b.name:lower()
			end)
		end

		-- Rebuild buffer
		local out = {}
		for _, ns in ipairs(ns_order) do
			local label = ns ~= "" and ns or "ungrouped"
			local entries = groups[ns]
			table.insert(out, "# " .. label .. " (" .. #entries .. ") {{{")
			table.insert(out, "")
			for _, p in ipairs(entries) do
				for _, l in ipairs(p.lines) do
					table.insert(out, l)
				end
				table.insert(out, "")
			end
			table.insert(out, "# }}}")
			table.insert(out, "")
		end

		-- Remove trailing blank line
		while #out > 0 and out[#out] == "" do
			table.remove(out)
		end
		table.insert(out, "")

		vim.api.nvim_buf_set_lines(0, 0, -1, false, out)
	end,
})

vim.filetype.add({
	extension = {
		conf = "toml",
		dconf = "dosini", -- surge-config multi-section profiles + Rules
	},
	filename = {
		["Cargo.lock"] = "toml",
	},
	pattern = {
		["%.config/.*"] = "toml",
		-- surge-config provider proxy lists: `name = ss, host, port, k=v`
		[".*surge%-config/providers/.*%.txt"] = "dosini",
	},
})
