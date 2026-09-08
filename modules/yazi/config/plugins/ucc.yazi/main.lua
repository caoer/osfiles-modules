-- ucc: start a ucc-* agent seat in yazi's current directory, in this
-- terminal, and return to yazi when it exits — the same handover `!` and
-- lazygit make.
--
--   plugin ucc          ucc-auto, launcher defaults (g a)
--   plugin ucc -- pick  g A: popup — `r` reuses the last launcher/model/effort,
--                       `p` picks anew: launcher (fzf), model, effort (popups).
--                       With no recorded pick it goes straight to the picker.
--
-- Model and effort are separate flags on every launcher; "launcher default"
-- passes neither. Endpoint wrappers pin their model and refuse (exit 2) a
-- different explicit one, so the default is the safe pick on anything but
-- ucc-auto / claude-profile launchers.
--
-- The last pick lives in ~/.local/state/yazi/ucc-recent (three lines:
-- launcher, model, effort; empty line = launcher default).

local get_cwd = ya.sync(function()
	return tostring(cx.active.current.cwd)
end)

local UCC_HOME = os.getenv("UCC_HOME") or (os.getenv("HOME") .. "/.local/share/ucc")
local STATE_DIR = (os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")) .. "/yazi"
local RECENT = STATE_DIR .. "/ucc-recent"

local MODELS = {
	{ on = "d", desc = "launcher default", value = nil },
	{ on = "f", desc = "claude-fable-5-1", value = "claude-fable-5-1" },
	{ on = "o", desc = "claude-opus-5", value = "claude-opus-5" },
	{ on = "O", desc = "claude-opus-4-8", value = "claude-opus-4-8" },
	{ on = "s", desc = "sonnet", value = "sonnet" },
}

local EFFORTS = {
	{ on = "d", desc = "launcher default", value = nil },
	{ on = "l", desc = "low", value = "low" },
	{ on = "m", desc = "medium", value = "medium" },
	{ on = "h", desc = "high", value = "high" },
	{ on = "x", desc = "xhigh", value = "xhigh" },
	{ on = "M", desc = "max", value = "max" },
}

local function notify(content, level)
	ya.notify({ title = "ucc", content = content, level = level or "info", timeout = 4 })
end

local function read_recent()
	local f = io.open(RECENT, "r")
	if not f then
		return nil
	end
	local launcher, model, effort = f:read("l"), f:read("l"), f:read("l")
	f:close()
	if not launcher or launcher == "" then
		return nil
	end
	return { launcher = launcher, model = model ~= "" and model or nil, effort = effort ~= "" and effort or nil }
end

local function write_recent(sel)
	fs.create("dir_all", Url(STATE_DIR))
	local f = io.open(RECENT, "w")
	if not f then
		return notify("cannot write " .. RECENT, "warn")
	end
	f:write(sel.launcher, "\n", sel.model or "", "\n", sel.effort or "", "\n")
	f:close()
end

local function summary(sel)
	return sel.launcher .. " · " .. (sel.model or "default") .. " · " .. (sel.effort or "default")
end

-- Launcher names: ucc-* in $UCC_HOME/bin minus the -cli / -ip helpers and the
-- ucc-source-* env dumps, which are not seats. Sorted; ucc-auto floats first.
local function pick_launcher()
	local script = "cd " .. ya.quote(UCC_HOME .. "/bin") .. [[ && {
  [ -x ucc-auto ] && echo ucc-auto
  ls ucc-* | grep -v -e '-cli$' -e '-ip$' -e '^ucc-source-' -e '^ucc-auto$'
} | fzf --prompt='launcher> ' --no-multi]]
	local permit = ui.hide()
	local out, err = Command("sh")
		:arg({ "-c", script })
		:stdin(Command.INHERIT)
		:stdout(Command.PIPED)
		:stderr(Command.INHERIT)
		:output()
	permit:drop()
	if not out then
		notify("fzf failed: " .. tostring(err), "error")
		return nil
	end
	local name = out.stdout:gsub("%s+$", "")
	return name ~= "" and name or nil
end

local function pick(cands)
	local i = ya.which({ cands = cands })
	return i and cands[i] or nil
end

local function pick_all()
	local launcher = pick_launcher()
	if not launcher then
		return nil
	end
	local model = pick(MODELS)
	if not model then
		return nil
	end
	local effort = pick(EFFORTS)
	if not effort then
		return nil
	end
	local sel = { launcher = launcher, model = model.value, effort = effort.value }
	write_recent(sel)
	return sel
end

local function choose()
	local recent = read_recent()
	if not recent then
		return pick_all()
	end
	local c = pick({
		{ on = "r", desc = "recent: " .. summary(recent) },
		{ on = "p", desc = "pick launcher, model, effort" },
	})
	if not c then
		return nil
	end
	return c.on == "r" and recent or pick_all()
end

return {
	entry = function(_, job)
		local cwd = get_cwd()
		local sel = { launcher = "ucc-auto" }
		if job.args[1] == "pick" then
			sel = choose()
			if not sel then
				return
			end
		end

		local argv = {}
		if sel.model then
			argv[#argv + 1] = "--model"
			argv[#argv + 1] = sel.model
		end
		if sel.effort then
			argv[#argv + 1] = "--effort"
			argv[#argv + 1] = sel.effort
		end

		local permit = ui.hide()
		local status, err = Command(UCC_HOME .. "/bin/" .. sel.launcher)
			:arg(argv)
			:cwd(cwd)
			:stdin(Command.INHERIT)
			:stdout(Command.INHERIT)
			:stderr(Command.INHERIT)
			:status()
		permit:drop()

		if not status then
			notify(sel.launcher .. " failed to start: " .. tostring(err), "error")
		elseif not status.success then
			notify(sel.launcher .. " exited with code " .. tostring(status.code), "warn")
		end
		ya.emit("refresh", {})
	end,
}
