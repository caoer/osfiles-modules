return {
    entry = function()
        local output = Command("git"):arg("status"):stderr(Command.PIPED):output()
        if output.stderr ~= "" then
            ya.notify({
                title = "lazygit",
                content = "Not in a git directory\nError: " .. output.stderr,
                level = "warn",
                timeout = 5,
            })
        else
            -- Visual hint inside lazygit that we'll exit back to yazi: lavender borders.
            local cfg_dir = (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/lazygit"
            local lg_config = cfg_dir .. "/config.yml," .. cfg_dir .. "/yazi.yml"
            local output, err_code = Command("lazygit")
                :env("LG_CONFIG_FILE", lg_config)
                :stdout(Command.PIPED):stderr(Command.PIPED):spawn()
            permit = ui.hide and ui.hide() or ya.hide()
            if output and not err_code then
                output, err_code = output:wait_with_output()
            end
            if err_code ~= nil then
                ya.notify({
                    title = "Failed to run lazygit command",
                    content = "Status: " .. err_code,
                    level = "error",
                    timeout = 5,
                })
            elseif not output.status.success then
                ya.notify({
                    title = "lazygit in" .. cwd .. "failed, exit code " .. output.status.code,
                    content = output.stderr,
                    level = "error",
                    timeout = 5,
                })
            end
        end
    end,
}
