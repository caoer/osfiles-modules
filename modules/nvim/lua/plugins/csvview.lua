return {
  {
    "hat0uma/csvview.nvim",
    ft = { "csv", "tsv" },
    cmd = { "CsvViewEnable", "CsvViewDisable", "CsvViewToggle" },
    opts = {
      parser = { comments = { "#" } },
      view = {
        display_mode = "border",
        header_lnum = 1,
        sticky_header = { enabled = true },
      },
      keymaps = {
        textobject_field_inner = { "if", mode = { "o", "x" } },
        textobject_field_outer = { "af", mode = { "o", "x" } },
        jump_next_field_end = { "<Tab>", mode = { "n", "v" } },
        jump_prev_field_end = { "<S-Tab>", mode = { "n", "v" } },
      },
    },
    keys = {
      { "<leader>tv", "<cmd>CsvViewToggle<cr>", desc = "Toggle CSV/TSV view" },
    },
  },
  {
    "cameron-wags/rainbow_csv.nvim",
    ft = { "csv", "tsv" },
    cmd = { "RainbowDelim", "NoRainbowDelim", "Select", "Update" },
    config = true,
  },
}
