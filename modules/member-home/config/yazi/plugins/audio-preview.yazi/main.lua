--- @since 26.1.22
--- Audio preview: shows embedded album art, falls back to a waveform visualization.
--- Seek toggles between album art (skip=0) and waveform (skip=1).

local M = {}

-- Use system ffmpeg (full), not the ffmpeg-headless pulled in by yazi/yt-dlp deps,
-- which hangs on some media. /run/current-system/sw/bin is present on
-- nix-darwin/NixOS; foreign hosts (cos-ucc) provide full ffmpeg on PATH via
-- home.packages instead — fall back to bare name there.
local function sysbin(name)
	local sys = "/run/current-system/sw/bin/" .. name
	return fs.cha(Url(sys)) and sys or name
end
local FFPROBE = sysbin("ffprobe")
local FFMPEG = sysbin("ffmpeg")

local function cache_path(job)
	local base = ya.file_cache(job)
	if not base then
		return nil
	end
	return Url(tostring(base) .. ".jpg")
end

local function fail(job, msg)
	ya.preview_widget(job, ui.Text.parse(msg):area(job.area):wrap(ui.Wrap.YES))
end

-- Extract embedded album art (copies the attached cover stream as an image).
local function extract_cover(input, output)
	local child = Command(FFMPEG)
		:arg({
			"-v", "error",
			"-i", tostring(input),
			"-an",
			"-vcodec", "copy",
			"-y",
			tostring(output),
		})
		:stdout(Command.NULL)
		:stderr(Command.NULL)
		:spawn()
	if not child then
		return false
	end
	local result = child:wait_with_output()
	return result and result.status.success
end

-- Render a waveform image when there is no embedded cover.
local function generate_waveform(input, output, w, h)
	-- Scale char dimensions to pixels (char ~8px wide, ~16px tall).
	local pw = math.max(w * 8, 400)
	local ph = math.max(h * 16, 200)
	local size = string.format("%dx%d", pw, ph)

	local child = Command(FFMPEG)
		:arg({
			"-v", "error",
			"-i", tostring(input),
			"-filter_complex",
			string.format("showwavespic=s=%s:colors=0x89b4fa|0x585b70:scale=cbrt", size),
			"-frames:v", "1",
			"-y",
			tostring(output),
		})
		:stdout(Command.NULL)
		:stderr(Command.PIPED)
		:spawn()
	if not child then
		return false
	end
	local result = child:wait_with_output()
	return result and result.status.success
end

function M:preload(job)
	local cache = cache_path(job)
	if not cache then
		return true
	end
	if fs.cha(cache) then
		return true
	end

	local aw = (job.area and job.area.w) or 80
	local ah = (job.area and job.area.h) or 25

	if job.skip == 0 then
		-- Album art first, then fall back to waveform.
		if extract_cover(job.file.url, cache) and fs.cha(cache) then
			return true
		end
		if generate_waveform(job.file.url, cache, aw, ah) then
			return true
		end
	else
		-- Explicit waveform mode.
		if generate_waveform(job.file.url, cache, aw, ah) then
			return true
		end
	end

	return false
end

function M:peek(job)
	local cache = cache_path(job)
	if not cache then
		return fail(job, "Failed to get cache path")
	end

	if not fs.cha(cache) then
		if not self:preload(job) then
			-- Last resort: show metadata as text.
			local child = Command(FFPROBE)
				:arg({
					"-v", "error",
					"-show_entries", "format=duration,bit_rate:format_tags=title,artist,album",
					"-of", "default=noprint_wrappers=1",
					tostring(job.file.url),
				})
				:stdout(Command.PIPED)
				:stderr(Command.NULL)
				:spawn()
			if child then
				local out = child:wait_with_output()
				if out and out.stdout and #out.stdout > 0 then
					return fail(job, out.stdout)
				end
			end
			return fail(job, "No audio preview available")
		end
	end

	ya.image_show(cache, job.area)
end

function M:seek(job)
	local h = cx.active.current.hovered
	if h and h.url == job.file.url then
		local skip = cx.active.preview.skip
		local new_skip = skip == 0 and 1 or 0
		ya.mgr_emit("peek", { new_skip, only_if = job.file.url })
	end
end

return M
