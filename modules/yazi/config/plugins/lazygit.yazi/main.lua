--- @since 25.12.29
return {
	entry = function()
		local out = Command("git")
			:arg({ "rev-parse", "--git-dir" })
			:stdout(Command.NULL)
			:stderr(Command.NULL)
			:output()

		-- output() returns (nil, Error) when the binary is missing, so the
		-- nil check has to come before any field access.
		if not out or not out.status.success then
			return ya.notify({
				title = "lazygit",
				content = "Not in a git repository",
				level = "warn",
				timeout = 5,
			})
		end

		-- Visual hint inside lazygit that we'll exit back to yazi: lavender borders.
		local cfg_dir = (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/lazygit"
		local lg_config = cfg_dir .. "/config.yml," .. cfg_dir .. "/yazi.yml"

		-- Hide before handing the terminal over, and drop the permit the moment
		-- lazygit exits — a permit parked in a global only restores at GC time.
		local permit = ui.hide()
		local status, err = Command("lazygit")
			:env("LG_CONFIG_FILE", lg_config)
			:stdin(Command.INHERIT)
			:stdout(Command.INHERIT)
			:stderr(Command.INHERIT)
			:status()
		permit:drop()

		if not status then
			ya.notify({
				title = "lazygit",
				content = "Failed to run lazygit: " .. tostring(err),
				level = "error",
				timeout = 5,
			})
		elseif not status.success then
			ya.notify({
				title = "lazygit",
				content = "lazygit exited with code " .. tostring(status.code),
				level = "error",
				timeout = 5,
			})
		end

		ya.emit("refresh", {})
	end,
}
