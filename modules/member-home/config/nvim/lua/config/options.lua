-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

local opt = vim.opt

-- Clipboard: pbcopy/pbpaste on macOS (works in nested tmux popups),
-- OSC 52 on remote/SSH (passes through tmux chain to terminal).
local is_local_mac = vim.fn.has("mac") == 1 and vim.env.SSH_CONNECTION == nil

local function copy_fn(reg)
  if is_local_mac then
    return function(lines, regtype)
      local text = table.concat(lines, "\n")
      if regtype == "V" then text = text .. "\n" end
      vim.fn.system("pbcopy", text)
    end
  end
  -- Remote: OSC 52 (fire-and-forget, works through tmux/SSH)
  local osc52_fn = require("vim.ui.clipboard.osc52").copy(reg)
  return function(lines, regtype)
    if regtype == "V" then
      local copy = { unpack(lines) }
      table.insert(copy, "")
      return osc52_fn(copy)
    end
    return osc52_fn(lines)
  end
end

local function paste_fn()
  if is_local_mac then
    local h = io.popen("pbpaste")
    local content = h:read("*a")
    h:close()
    local lines = vim.split(content, "\n", { plain = true })
    if #lines > 1 and lines[#lines] == "" then
      table.remove(lines)
      return lines, "V"
    end
    return lines
  end
  -- Remote: tmux paste buffer (OSC 52 is write-only)
  local h = io.popen("tmux save-buffer - 2>/dev/null")
  if h then
    local content = h:read("*a")
    h:close()
    if content and content ~= "" then
      local lines = vim.split(content, "\n", { plain = true })
      if #lines > 1 and lines[#lines] == "" then
        table.remove(lines)
        return lines, "V"
      end
      return lines
    end
  end
  return {}
end

vim.g.clipboard = {
  name = is_local_mac and "pbcopy/pbpaste" or "OSC 52 + tmux",
  copy = {
    ["+"] = copy_fn("+"),
    ["*"] = copy_fn("*"),
  },
  paste = {
    ["+"] = paste_fn,
    ["*"] = paste_fn,
  },
}
opt.clipboard = "unnamedplus"

-- Custom settings that differ from LazyVim defaults
opt.swapfile = false
opt.backup = false
opt.undodir = os.getenv("HOME") .. "/.local/share/nvim/undo"
opt.hlsearch = false
opt.incsearch = true
opt.scrolloff = 8 -- LazyVim default is 4
opt.updatetime = 50 -- LazyVim default is 200

-- Indent settings (LazyVim default is 4, we want 2)
opt.shiftwidth = 2
opt.tabstop = 2
opt.softtabstop = 2
opt.expandtab = true

-- Remove vertical separator (make it invisible)
-- opt.fillchars = { vert = " ", vertleft = " ", vertright = " ", verthoriz = " " }
opt.fillchars = { vert = "│", horiz = "─" }

-- Spell checking setup for developers
opt.spell = false -- Off by default
opt.spelllang = "en_us"
opt.spellfile = vim.fn.stdpath("config") .. "/spell/en.utf-8.add"
opt.spelloptions = "camel" -- Treat CamelCase properly

opt.autoread = true

-- Yank file references
local yank = require("config.yank")
vim.keymap.set("n", "<leader>yc", function() yank.yank_ref(false) end, { desc = "Copy @file ref (relative)" })
vim.keymap.set("v", "<leader>yc", function() yank.yank_ref(true) end, { desc = "Copy @file ref (relative)" })
vim.keymap.set("n", "<leader>yC", function() yank.yank_ref_abs(false) end, { desc = "Copy @file ref (absolute)" })
vim.keymap.set("v", "<leader>yC", function() yank.yank_ref_abs(true) end, { desc = "Copy @file ref (absolute)" })
vim.keymap.set("n", "<leader>yx", function() yank.yank_xml_empty(false) end, { desc = "Copy XML ref (no content)" })
vim.keymap.set("v", "<leader>yx", function() yank.yank_xml_empty(true) end, { desc = "Copy XML ref (no content)" })
vim.keymap.set("n", "<leader>yX", function() yank.yank_xml_full(false) end, { desc = "Copy XML with content" })
vim.keymap.set("v", "<leader>yX", function() yank.yank_xml_full(true) end, { desc = "Copy XML with content" })
