-- File finder configuration for fzf-lua and telescope
-- Adds ability to search gitignored files

return {
  -- Configure fzf-lua (LazyVim's default picker)
  {
    "ibhagwan/fzf-lua",
    opts = {
      files = {
        hidden = true, -- Show hidden files by default
      },
    },
    keys = {
      -- Find ALL files including gitignored (uppercase F for "Find ALL")
      {
        "<leader>fF",
        function()
          require("fzf-lua").files({
            cmd = "fd --type f --hidden --no-ignore --exclude .git", -- Show all files, including gitignored and hidden
          })
        end,
        desc = "Find Files (all, including gitignored)",
      },
      {
        "<leader>fD",
        function()
          require("fzf-lua").files({
            cwd = "/Users/Shared/projects/caoer/locus/.repos/osfiles",
          })
        end,
        desc = "Find Files (osfiles)",
      },
    },
  },

  -- Also configure telescope as backup (if you switch to it)
  -- {
  --   "nvim-telescope/telescope.nvim",
  --   optional = true,
  --   keys = {
  --     {
  --       "<leader>fF",
  --       function()
  --         require("telescope.builtin").find_files({
  --           hidden = true,
  --           no_ignore = true, -- Don't respect .gitignore
  --         })
  --       end,
  --       desc = "Find Files (all, including gitignored)",
  --     },
  --   },
  -- },
}
