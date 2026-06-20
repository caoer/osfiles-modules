-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

local map = vim.keymap.set

-- Open in VS Code
map("n", "gv", ":!code %<CR>", { desc = "Open in VS Code", silent = true })
-- map("n", "gc", ":!cursor %<CR>", { desc = "Open in Cursor", silent = true })

-- Remove default Ctrl mappings if they exist (optional customization)
pcall(vim.keymap.del, "n", "<C-h>")
pcall(vim.keymap.del, "n", "<C-j>")
pcall(vim.keymap.del, "n", "<C-k>")
pcall(vim.keymap.del, "n", "<C-l>")

-- Add leader-based window navigation
map("n", "<leader>h", "<C-w>h", { desc = "Go to left window" })
map("n", "<leader>j", "<C-w>j", { desc = "Go to below window" })
map("n", "<leader>k", "<C-w>k", { desc = "Go to above window" })
map("n", "<leader>l", "<C-w>l", { desc = "Go to right window" })

-- Window navigation with arrow keys (QMK sends arrows for C-j/C-k).
map("n", "<Left>", "<C-w>h", { desc = "Go to left window" })
map("n", "<Down>", "<C-w>j", { desc = "Go to below window" })
map("n", "<Up>", "<C-w>k", { desc = "Go to above window" })
map("n", "<Right>", "<C-w>l", { desc = "Go to right window" })

-- Move focus out of a terminal without leaving terminal mode.
-- Plain arrows must pass to the shell (atuin history), so use Shift+arrows.
map("t", "<S-Left>", "<cmd>wincmd h<cr>", { desc = "Go to left window" })
map("t", "<S-Down>", "<cmd>wincmd j<cr>", { desc = "Go to below window" })
map("t", "<S-Up>", "<cmd>wincmd k<cr>", { desc = "Go to above window" })
map("t", "<S-Right>", "<cmd>wincmd l<cr>", { desc = "Go to right window" })

-- Symmetry: Shift+arrows in normal mode too (one muscle memory everywhere)
map("n", "<S-Left>", "<C-w>h", { desc = "Go to left window" })
map("n", "<S-Down>", "<C-w>j", { desc = "Go to below window" })
map("n", "<S-Up>", "<C-w>k", { desc = "Go to above window" })
map("n", "<S-Right>", "<C-w>l", { desc = "Go to right window" })

-- -- Explorer: reveal current file
-- map("n", "<leader>e", function()
--   Snacks.explorer.reveal({ file = vim.fn.expand("%:p") })
-- end, { desc = "Explorer (reveal file)" })

map("n", "<leader>yp", function()
  local path = vim.fn.expand("%:p")
  vim.fn.setreg("+", path)
  vim.notify("Copied: " .. path, vim.log.levels.INFO)
end, { desc = "Copy file path" })

-- Find tmux config files
map("n", "<leader>fm", function()
  Snacks.picker.files({ cwd = "/Users/Shared/projects/caoer/locus/.repos/osfiles/config/tmux" })
end, { desc = "Find tmux config" })

vim.keymap.set("n", "<leader>ww", function()
  vim.cmd("w")
  Snacks.notify.info(vim.fn.expand("%"), {
    title = "Saved",
    style = "fancy",
  })
end, { desc = "Save file" })

-- ============================================================================
-- Search and Replace
-- ============================================================================
vim.keymap.set({ "n", "v" }, "<leader>sf", function()
  local grug = require("grug-far")
  local opts = {
    prefills = {
      paths = vim.fn.expand("%"),
    },
  }

  -- If in visual mode, prefill search with selection
  if vim.fn.mode() == "v" or vim.fn.mode() == "V" then
    grug.with_visual_selection(opts)
  else
    grug.open(opts)
  end
end, { desc = "Search/replace in current file" })

-- Quick substitute: replace selected word globally in file
vim.keymap.set("v", "<leader>ss", function()
  vim.cmd('noautocmd normal! "zy')
  local escaped = vim.fn.escape(vim.fn.getreg("z"), "/\\.*$^~[]")
  local cmd = string.format("%%s/%s/%s/g", escaped, escaped)
  vim.api.nvim_feedkeys(":", "n", false)
  vim.schedule(function()
    vim.fn.setcmdline(cmd, 5 + 2 * #escaped)
  end)
end, { desc = "Substitute selected (cursor at end)" })

vim.keymap.set("n", "<leader>tq", function()
  local cols = vim.fn.input("select cols (e.g. url,tranco_today): ")
  local tmp = vim.fn.tempname() .. ".csv"
  vim.fn.system(
    string.format(
      "duckdb -c \"COPY (SELECT %s FROM read_csv_auto('%s')) TO '%s' (HEADER)\"",
      cols,
      vim.fn.expand("%:p"),
      tmp
    )
  )
  vim.cmd("edit " .. tmp)
end, { desc = "CSV: project cols via DuckDB" })
