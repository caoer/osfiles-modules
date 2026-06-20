--- @since 26.1.22
--- Video preview: composites N frames into a grid (montage) via ffmpeg's tile filter.
--- Falls back to a waveform for audio-only files that share the video/* mime
--- (e.g. .aac / .m4a in an MP4 container). Seek cycles grid sizes 3x3 -> 4x3 -> 4x4.
---
--- Registered as both a previewer (peek) and a preloader. The preloader builds the
--- image ahead of hover; peek generates inline as a fallback. Both guard on fs.cha.

local M = {}

-- Use system ffmpeg (full), not the ffmpeg-headless pulled in by yazi/yt-dlp deps,
-- which hangs on MP4s whose moov atom sits at end-of-file. /run/current-system/sw/bin
-- is present on nix-darwin/NixOS; foreign hosts (cos-ucc) provide full ffmpeg on
-- PATH via home.packages instead — fall back to bare name there.
local function sysbin(name)
	local sys = "/run/current-system/sw/bin/" .. name
	return fs.cha(Url(sys)) and sys or name
end
local FFPROBE = sysbin("ffprobe")
local FFMPEG = sysbin("ffmpeg")

-- Grid layouts indexed by skip value
local GRIDS = {
	{ cols = 3, rows = 3 }, -- 9 frames (default)
	{ cols = 4, rows = 3 }, -- 12 frames
	{ cols = 4, rows = 4 }, -- 16 frames
}

local function get_grid(skip)
	return GRIDS[math.min((skip or 0) + 1, #GRIDS)]
end

-- ya.file_cache returns a Url with no extension; ffmpeg needs one to pick the muxer.
local function cache_path(job)
	local base = ya.file_cache(job)
	return base and Url(tostring(base) .. ".jpg") or nil
end

local function fail(job, msg)
	ya.preview_widget(job, ui.Text.parse(msg):area(job.area):wrap(ui.Wrap.YES))
end

local function probe_duration(url)
	local child = Command(FFPROBE)
		:arg({
			"-v", "error",
			"-show_entries", "format=duration",
			"-of", "default=noprint_wrappers=1:nokey=1",
			tostring(url),
		})
		:stdout(Command.PIPED)
		:stderr(Command.NULL)
		:spawn()
	if not child then
		return nil
	end
	local out = child:wait_with_output()
	if not out or not out.status.success then
		return nil
	end
	return tonumber(out.stdout)
end

local function run_ffmpeg(args)
	local child = Command(FFMPEG):arg(args):stdout(Command.NULL):stderr(Command.PIPED):spawn()
	if not child then
		return false, "spawn failed"
	end
	local out = child:wait_with_output()
	if not out or not out.status.success then
		return false, (out and out.stderr) or "unknown"
	end
	return true
end

local function make_montage(job, cache, duration)
	local grid = get_grid(job.skip)
	local total = grid.cols * grid.rows
	local interval = duration / (total + 1)
	-- Per-tile width from preview area (char ~8px wide); area may be nil during preload.
	local aw = (job.area and job.area.w) or 80
	local tile_w = math.min(math.floor((aw * 8) / grid.cols), 480)
	local vf = string.format(
		"fps=1/%f,scale=%d:-2,tile=%dx%d:padding=4:margin=4:color=0x1e1e2e",
		interval, tile_w, grid.cols, grid.rows
	)
	return run_ffmpeg({
		"-v", "error",
		"-i", tostring(job.file.url),
		"-vf", vf,
		"-frames:v", "1",
		"-q:v", "3",
		"-y", tostring(cache),
	})
end

local function make_waveform(job, cache)
	local aw = (job.area and job.area.w) or 80
	local ah = (job.area and job.area.h) or 25
	local size = string.format("%dx%d", math.max(aw * 8, 400), math.max(ah * 16, 200))
	return run_ffmpeg({
		"-v", "error",
		"-i", tostring(job.file.url),
		"-filter_complex", string.format("showwavespic=s=%s:colors=0x89b4fa|0x585b70:scale=cbrt", size),
		"-frames:v", "1",
		"-y", tostring(cache),
	})
end

function M:preload(job)
	local cache = cache_path(job)
	if not cache then
		return true
	end
	if fs.cha(cache) then
		return true
	end

	local duration = probe_duration(job.file.url)
	if not duration or duration <= 0 then
		ya.err("video-montage: bad/no duration for " .. tostring(job.file.url))
		return false
	end

	-- Try the montage first. Audio-only files in an MP4 container report mime video/*
	-- but have no video stream; the tile filter fails, so fall back to a waveform.
	if make_montage(job, cache, duration) then
		return true
	end
	local ok, err = make_waveform(job, cache)
	if not ok then
		ya.err("video-montage: montage and waveform both failed: " .. tostring(err))
		return false
	end
	return true
end

function M:peek(job)
	local cache = cache_path(job)
	if not cache then
		return fail(job, "Failed to get cache path")
	end

	if not fs.cha(cache) then
		if not self:preload(job) then
			return fail(job, "Failed to generate preview (check yazi.log)")
		end
	end

	ya.image_show(cache, job.area)
end

function M:seek(job)
	local h = cx.active.current.hovered
	if h and h.url == job.file.url then
		local skip = cx.active.preview.skip
		local new_skip = math.max(0, math.min(skip + job.units, #GRIDS - 1))
		if new_skip ~= skip then
			ya.mgr_emit("peek", { new_skip, only_if = job.file.url })
		end
	end
end

return M
