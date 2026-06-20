local function toggle_checkbox()
    local line = vim.api.nvim_get_current_line()
    local new_line
    if line:match("%[ %]") then
        new_line = line:gsub("%[ %]", "[x]", 1)
    elseif line:match("%[x%]") or line:match("%[X%]") then
        new_line = line:gsub("%[[xX]%]", "[ ]", 1)
    else
        return false
    end
    vim.api.nvim_set_current_line(new_line)
    return true
end

return -- lazy.nvim
{
    "folke/snacks.nvim",
    ---@type snacks.Config
    opts = {
        picker = {
            sources = {
                explorer = {hidden = true, ignored = true},
                files = {hidden = true},
                grep = {hidden = true}
            }
        },
        scroll = {
            animate = {duration = {step = 5, total = 50}, easing = "linear"}
        }
    },
    keys = {
        {
            "<CR>",
            function()
                if not toggle_checkbox() then
                    -- No checkbox found, do normal Enter behavior
                    vim.cmd("normal! j")
                end
            end,
            desc = "Toggle checkbox",
            ft = "markdown"
        }, {
            "<leader>fC",
            function()
                Snacks.explorer({cwd = vim.fn.expand("%:p:h")})
            end,
            desc = "Explorer (current file dir)"
        }
    }
}
