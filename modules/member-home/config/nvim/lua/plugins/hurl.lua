return {
  {
    "jellydn/hurl.nvim",
    dependencies = {
      "MunifTanjim/nui.nvim",
      "nvim-lua/plenary.nvim",
      "nvim-treesitter/nvim-treesitter",
    },
    ft = "hurl",
    opts = {
      mode = "split",
      show_notification = false,
      formatters = {
        json = { "jq" },
      },
    },
    keys = {
      { "<leader>ha", "<cmd>HurlRunner<CR>", ft = "hurl", desc = "Run all requests" },
      { "<leader>he", "<cmd>HurlRunnerAt<CR>", ft = "hurl", desc = "Run request at cursor" },
      { "<leader>hE", "<cmd>HurlRunnerToEnd<CR>", ft = "hurl", desc = "Run from cursor to end" },
      { "<leader>hv", "<cmd>HurlVerbose<CR>", ft = "hurl", desc = "Run verbose" },
      { "<leader>hm", "<cmd>HurlToggleMode<CR>", ft = "hurl", desc = "Toggle popup/split" },
      { "<leader>h", ":HurlRunner<CR>", ft = "hurl", desc = "Run selection", mode = "v" },
    },
  },
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "hurl" } },
  },
}
