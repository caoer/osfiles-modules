-- Interactive cheatsheet picker for LazyVim keymaps
-- Provides searchable, categorized list of common commands with mnemonics

return {
	{
		"ibhagwan/fzf-lua",
		optional = true,
		keys = {
			{ "<leader>s?", desc = "Cheatsheet" },
		},
		config = function()
			-- Cheatsheet data organized by category
			local items = {
				-- SPELLCHECK
				{ category = "SPELLCHECK", key = "<leader>us", desc = "Toggle spellcheck on/off", mnemonic = "" },
				{
					category = "SPELLCHECK",
					key = "zg",
					desc = "Add word to dictionary",
					mnemonic = "z=spell, g=Good word",
				},
				{ category = "SPELLCHECK", key = "zw", desc = "Mark word as Wrong/bad", mnemonic = "z=spell, w=Wrong" },
				{
					category = "SPELLCHECK",
					key = "zug",
					desc = "Undo Good - remove from dictionary",
					mnemonic = "undo good",
				},
				{
					category = "SPELLCHECK",
					key = "]s",
					desc = "Jump to next misspelled word",
					mnemonic = "] forward, s=spell",
				},
				{
					category = "SPELLCHECK",
					key = "[s",
					desc = "Jump to previous misspelled word",
					mnemonic = "[ backward",
				},
				{
					category = "SPELLCHECK",
					key = "z=",
					desc = "Show spelling suggestions",
					mnemonic = "z=spell, ==list",
				},

				-- NAVIGATION
				{ category = "NAVIGATION", key = "s", desc = "2-char forward jump (Flash)", mnemonic = "s=search" },
				{
					category = "NAVIGATION",
					key = "S",
					desc = "Treesitter syntax search",
					mnemonic = "capital S=Syntax",
				},
				{
					category = "NAVIGATION",
					key = "f{char}",
					desc = "Jump forward to character",
					mnemonic = "f=find forward",
				},
				{
					category = "NAVIGATION",
					key = "F{char}",
					desc = "Jump backward to character",
					mnemonic = "F=Find backward",
				},
				{
					category = "NAVIGATION",
					key = "t{char}",
					desc = "Jump forward until (before) char",
					mnemonic = "t='til",
				},
				{
					category = "NAVIGATION",
					key = "T{char}",
					desc = "Jump backward until char",
					mnemonic = "T='Til back",
				},
				{
					category = "NAVIGATION",
					key = ";",
					desc = "Repeat last f/F/t/T same direction",
					mnemonic = "semicolon=same",
				},
				{
					category = "NAVIGATION",
					key = ",",
					desc = "Repeat last f/F/t/T opposite direction",
					mnemonic = "comma=contrary",
				},
				{
					category = "NAVIGATION",
					key = "/{pattern}",
					desc = "Search forward",
					mnemonic = "/ points right →",
				},
				{ category = "NAVIGATION", key = "?{pattern}", desc = "Search backward", mnemonic = "? reversed /" },
				{ category = "NAVIGATION", key = "n", desc = "Next match", mnemonic = "n=next" },
				{ category = "NAVIGATION", key = "N", desc = "Previous match", mnemonic = "N=opposite" },
				{
					category = "NAVIGATION",
					key = "<C-s>",
					desc = "Toggle Flash labels in search",
					mnemonic = "Ctrl-s in search",
				},

				-- FILE FINDING
				{
					category = "FILE FINDING",
					key = "<leader><leader>",
					desc = "Find files (respects .gitignore)",
					mnemonic = "",
				},
				{
					category = "FILE FINDING",
					key = "<leader>fF",
					desc = "Find ALL files (gitignored too)",
					mnemonic = "capital F=FULL",
				},
				{ category = "FILE FINDING", key = "<leader>ff", desc = "Find files", mnemonic = "f=files" },
				{ category = "FILE FINDING", key = "<leader>fg", desc = "Git files only", mnemonic = "g=git" },
				{ category = "FILE FINDING", key = "<leader>fr", desc = "Recent files", mnemonic = "r=recent" },
				{ category = "FILE FINDING", key = "<leader>/", desc = "Grep in files", mnemonic = "/ search" },
				{ category = "FILE FINDING", key = "<leader>sg", desc = "Search grep", mnemonic = "s=search, g=grep" },

				-- WINDOW MANAGEMENT
				{ category = "WINDOW", key = "<leader>h", desc = "Go to left window", mnemonic = "h=left" },
				{ category = "WINDOW", key = "<leader>j", desc = "Go to below window", mnemonic = "j=down" },
				{ category = "WINDOW", key = "<leader>k", desc = "Go to above window", mnemonic = "k=up" },
				{ category = "WINDOW", key = "<leader>l", desc = "Go to right window", mnemonic = "l=right" },
			}

			-- Format an item for the picker
			local function format_item(item)
				local key_width = 20
				local category_width = 15
				local key_colored = string.format("%-" .. key_width .. "s", item.key)
				local category = string.format("%-" .. category_width .. "s", "[" .. item.category .. "]")
				local mnemonic = item.mnemonic ~= "" and " (" .. item.mnemonic .. ")" or ""
				return category .. key_colored .. item.desc .. mnemonic
			end

			-- Open cheatsheet picker using fzf-lua
			local function open_cheatsheet()
				local ok, fzf = pcall(require, "fzf-lua")
				if not ok then
					vim.notify("fzf-lua not available", vim.log.levels.ERROR)
					return
				end

				local entries = {}
				for _, item in ipairs(items) do
					table.insert(entries, format_item(item))
				end

				fzf.fzf_exec(entries, {
					prompt = "Cheatsheet❯ ",
					preview = function(selected)
						-- Extract the keymap from the selected line
						local category = selected[1]:match("%[(.-)%]")
						local key = selected[1]:match("%]%s*(%S+)")

						-- Find the item in our data
						for _, item in ipairs(items) do
							if item.key == key and item.category == category then
								local preview_lines = {
									"══════════════════════════════════════",
									"KEYMAP: " .. item.key,
									"CATEGORY: " .. item.category,
									"══════════════════════════════════════",
									"",
									"DESCRIPTION:",
									"  " .. item.desc,
									"",
								}
								if item.mnemonic ~= "" then
									table.insert(preview_lines, "MNEMONIC:")
									table.insert(preview_lines, "  " .. item.mnemonic)
									table.insert(preview_lines, "")
								end
								table.insert(
									preview_lines,
									"══════════════════════════════════════"
								)
								table.insert(preview_lines, "Press Enter to copy keymap to clipboard")
								return preview_lines
							end
						end
						return { "No preview available" }
					end,
					actions = {
						["default"] = function(selected)
							-- Copy the keymap to clipboard
							local key = selected[1]:match("%]%s*(%S+)")
							if key then
								vim.fn.setreg("+", key)
								vim.notify("Copied to clipboard: " .. key, vim.log.levels.INFO)
							end
						end,
					},
					winopts = {
						height = 0.8,
						width = 0.9,
						preview = {
							layout = "vertical",
							vertical = "down:50%",
						},
					},
				})
			end

			-- Create user command
			vim.api.nvim_create_user_command("Cheatsheet", open_cheatsheet, { desc = "Open cheatsheet picker" })

			-- Add keymap
			vim.keymap.set("n", "<leader>s?", open_cheatsheet, { desc = "Open cheatsheet" })
		end,
	},
}
