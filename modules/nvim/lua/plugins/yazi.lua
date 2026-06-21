-- Yazi file manager integration
return {
  -- Free up <leader>r/R for yazi
  {
    "folke/snacks.nvim",
    keys = {
      { "<leader>r", false },
      { "<leader>R", false },
    },
  },

  {
    "mikavilpas/yazi.nvim",
    version = "*",
    dependencies = { { "nvim-lua/plenary.nvim", lazy = true } },
    event = "VeryLazy",
    init = function()
      vim.g.loaded_netrwPlugin = 1
    end,
    keys = {
      { "<leader>r", "<cmd>Yazi<cr>", mode = { "n", "v" }, desc = "Open yazi (current file)" },
      { "<leader>R", "<cmd>Yazi cwd<cr>", desc = "Open yazi (cwd)" },
      { "<f4>", "<cmd>Yazi toggle<cr>", desc = "Resume last yazi session" },
    },
    opts = {
      -- safe with smart-enter plugin: Enter on dirs navigates in-place,
      -- only files write to chooser-file (no recursion).
      open_for_directories = true,
      floating_window_scaling_factor = 0.9,
      keymaps = {
        show_help = "<f1>",
        open_and_pick_window = "<f4>",
      },
    },
  },
}
