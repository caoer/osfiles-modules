-- Extend LazyVim's treesitter config with additional parsers
return {
  "nvim-treesitter/nvim-treesitter",
  opts = {
    ensure_installed = {
      "bash",
      "css",
      "dockerfile",
      "fish",
      "git_config",
      "gitcommit",
      "gitignore",
      "go",
      "gomod",
      "nix",
      "regex",
      "rust",
      "sql",
      "toml",
      "typescript",
    },
  },
}
