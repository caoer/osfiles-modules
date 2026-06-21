return {
  "atmask/sops.nvim",
  ft = { "yaml", "json" },
  opts = {
    auto_decrypt = true,
    auto_encrypt = true,
  },
  keys = {
    { "<leader>sz", "<cmd>SopsDecrypt<cr>", desc = "Decrypt SOPS file" },
    { "<leader>se", "<cmd>SopsEncrypt<cr>", desc = "Encrypt SOPS file" },
  },
}
