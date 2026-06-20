-- Core LazyVim plugin overrides
-- Use this to customize LazyVim's default behavior
return {
  -- Configure colorscheme
  { "LazyVim/LazyVim", opts = { colorscheme = "tokyonight" } },
  {
    "folke/tokyonight.nvim",
    opts = {
      transparent = true,
      styles = { style = "moon", sidebars = "transparent", floats = "transparent" },
      on_highlights = function(hl, c)
        hl.WinSeparator = { fg = c.blue, bold = true }
      end,
    },
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        marksman = {}, -- Keep markdown LSP for other features
        -- typos_lsp disabled - using cspell instead (better code dictionaries)
        nil_ls = {
          settings = {
            ["nil"] = {
              nix = { flake = { autoArchive = true } },
            },
          },
        },
      },
      setup = {
        marksman = function()
          return true
        end,
      },
    },
  },
  {
    "mason-org/mason.nvim",
    opts = {
      ensure_installed = { "cspell" },
    },
  },
  {
    "mfussenegger/nvim-lint",
    optional = true,
    opts = {
      linters_by_ft = {
        markdown = { "cspell" },
      },
      linters = {
        cspell = {
          prepend_args = { "-c", vim.fn.expand("~/.config/cspell/cspell.json") },
        },
      },
    },
  },
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        -- Disable prettier for markdown (it strips table alignment)
        markdown = { "markdownlint-cli2", "markdown-toc" },
      },
    },
  },
  -- Enable git change indicators in the sign column (LazyVim disables by default)
  {
    "lewis6991/gitsigns.nvim",
    opts = { signcolumn = true },
  },
  -- Disable dashboard that might show terminal output
  -- { "nvimdev/dashboard-nvim", enabled = false },

  -- Disable alpha dashboard
  -- { "goolord/alpha-nvim", enabled = false },
}
