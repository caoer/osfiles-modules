--- archive-walk: step into disk images and archives as if they were directories.
--
-- Yazi has no VFS for archives — `yazi-fs/src/engine` ships exactly one backend
-- (`local`), and the Lua VFS service kinds (mount/hub/scope) only carry a `run`
-- Cmd, so they delegate to a plugin that must produce a REAL mount. Walking in
-- therefore means either mounting a filesystem image or extracting an archive.
-- Which one is right is decided by the format, and the two costs differ in kind:
--
--   disk image (mount)  O(1)   ~0.5s flat, measured 17KB → 1GB unchanged
--   archive (extract)   O(n)   ~300MB/s on APFS; 0.28s @ 104MB, 3.7s @ 1GB
--
-- So images mount and archives extract. The crossover is ~150-200MB: below it
-- extraction actually beats mounting, above it mounting wins and keeps winning.
-- Pack payloads larger than ~200MB as a UDZO .dmg and they open in flat 0.5s.
--
-- The mount cost is then hidden entirely: `peek` runs only for the hovered file,
-- so previewing a disk image starts the attach in the background. By the time
-- Enter is pressed the image is already mounted and the cd is instant.
--
-- Which of the two applies is a property of the host, not only of the format:
--
--   macOS  .dmg .iso .img  hdiutil, in-kernel, ~0.5s flat
--          .sqfs           anylinuxfs — real Linux filesystem drivers in a
--                          libkrun microVM, re-exported to the host over
--                          localhost NFSv3. No kernel extension and no
--                          privilege, ~2s cold. Apple Silicon only, and each
--                          mount gets its own 512 MiB guest.
--   Linux  .sqfs           squashfuse, through a setuid fusermount3 where
--                          the system provides one
--          disk images     nothing. An unprivileged FUSE mount needs that same
--                          setuid helper and stock NixOS ships none, so
--                          squashfuse cannot even spawn it and unmount returns
--                          EPERM. Granting it fleet-wide is a system decision,
--                          not a file manager's.
--
-- 7zz reads every format in that table, disk images included, so nothing here
-- depends on a mount succeeding: a failed attach degrades to the O(n) walk
-- instead of to a dead end. It needs no declaration either — the nixpkgs yazi
-- wrapper already prepends its bin to yazi's own PATH, which is where both the
-- built-in `archive` previewer and this plugin's Command("7zz") resolve it.
-- `yazi --debug` confirms it on a host with no 7zz in the user profile at all.

local M = {}

-- Filesystem images, mountable on macOS. `.sparsebundle` is deliberately
-- absent: it is a directory, so the file list already walks into it and
-- hovering never fires a previewer for it.
local IMAGES = { dmg = true, iso = true, sparseimage = true, cdr = true, img = true }

-- The one format that mounts on both platforms — seekable, zstd, random-access
-- — which is also why `pack` defaults to it.
local SQUASHFS = { squashfs = true, sqfs = true, sfs = true }

-- Extractable containers. Compound suffixes land on their last component
-- (`.tar.zst` → `zst`), which is why the compressors are listed alongside.
local ARCHIVES = {
	["7z"] = true,
	zip = true,
	rar = true,
	tar = true,
	tgz = true,
	tbz2 = true,
	txz = true,
	tzst = true,
	gz = true,
	bz2 = true,
	xz = true,
	zst = true,
}

-- Live attaches pile up as real volumes, so warn instead of silently hoarding.
local MOUNT_WARN_AT = 8

-- Delay before a hover-triggered attach starts. Long enough that scrolling
-- through a folder of images doesn't attach every one, short enough to finish
-- before a deliberate Enter. The hovered file is re-checked after sleeping
-- rather than relying on peek cancellation, which yazi does not document.
local HOVER_DEBOUNCE = 0.25

---Which helper can mount this extension on this host, if any. Primitives only,
---so this is safe to call from inside a `ya.sync` block.
---@param ext string|nil lowercased extension
---@return string|nil key into MOUNT
local function mounter(ext)
	if not ext then
		return nil
	end
	local macos = ya.target_os() == "macos"
	if SQUASHFS[ext] then
		return macos and "anylinuxfs" or "squashfuse"
	elseif IMAGES[ext] then
		return macos and "hdiutil" or nil
	end
	return nil
end

---How each helper attaches read-only at a mountpoint we name, and releases it.
---
---`settle` bounds the wait for that mountpoint to fill once the helper exits,
---because an exit status is not proof: squashfuse daemonises and can return 0
---having mounted nothing at all, which is exactly what a missing setuid
---fusermount3 looks like. Only a populated mountpoint proves the mount took.
local MOUNT = {
	-- `-noverify` is the single biggest lever: it skips the pre-mount checksum
	-- pass and cuts attach from 1.44s to 0.55s (2.9x). `-nobrowse`/`-noautoopen`
	-- keep Finder from listing the volume or opening a window over the terminal.
	hdiutil = {
		attach = function(src, mnt)
			return "hdiutil",
				{ "attach", src, "-readonly", "-nobrowse", "-noverify", "-noautoopen", "-quiet", "-mountpoint", mnt }
		end,
		release = function(mnt) return "hdiutil", { "detach", mnt, "-quiet" } end,
		settle = 1,
	},
	-- Synchronous: it returns only once the NFS mount is up, measured 1.9s cold
	-- for a bare .sqfs. `-w false` is `--window`: attaching pops open a Finder
	-- window over the terminal otherwise, and `nobrowse` keeps the volume out of
	-- the sidebar too — together they are hdiutil's `-noautoopen -nobrowse`.
	-- On release `-w` is a different flag, `--wait-for-vm`, which waits for the
	-- guest to exit: a plain unmount leaves the VM running until the next
	-- `anylinuxfs stop`, a 512 MiB leak per container walked into.
	anylinuxfs = {
		attach = function(src, mnt)
			return "anylinuxfs", { "mount", "-o", "ro", "--nfs-options=nobrowse", "-w", "false", src, mnt }
		end,
		release = function(mnt) return "anylinuxfs", { "unmount", "-w", "10", mnt } end,
		settle = 3,
	},
	squashfuse = {
		attach = function(src, mnt) return "squashfuse", { src, mnt } end,
		release = function(mnt) return "fusermount3", { "-u", mnt } end,
		settle = 1,
	},
}

---Classify a container by extension. Primitives only, so this is safe to call
---from inside a `ya.sync` block.
---@param ext string|nil
---@param is_dir boolean|nil
---@return string|nil "image", "archive", or nil
function M.kind(ext, is_dir)
	if is_dir or not ext then
		return nil
	end
	ext = ext:lower()
	if mounter(ext) then
		return "image"
	elseif IMAGES[ext] or SQUASHFS[ext] or ARCHIVES[ext] then
		-- Nothing here mounts it, but 7zz still reads it, so it walks in at O(n)
		-- rather than not at all.
		return "archive"
	end
	return nil
end

---Flatten a File into plain fields. Everything crossing a `ya.sync` boundary
---must be Sendable, and a File userdata is not — so the hovered entry is
---described in primitives and rebuilt into Urls on the async side.
---@param file table
---@return table
function M.describe(file)
	-- `url.ext`/`url.stem` are not plain Lua strings, so coerce them here rather
	-- than at every use site.
	local ext, stem = file.url.ext, file.url.stem
	return {
		url = tostring(file.url),
		-- `name` keeps the dots a stem would eat: packing `foo.bar/` has to
		-- produce `foo.bar.sqfs`, not `foo.sqfs`.
		name = tostring(file.name),
		stem = stem and tostring(stem) or "image",
		ext = ext and tostring(ext) or nil,
		is_dir = file.cha.is_dir,
		mtime = file.cha.mtime or 0,
		len = file.cha.len or 0,
	}
end

---Slot names are `<source>-<content>-<stem>`: the first half identifies WHICH
---file, the second WHICH VERSION of it. Splitting them that way means a rebuilt
---archive lands in a new slot (never a stale hit) while its old slot stays
---recognisable as the same source, so `prune_stale` can drop it.
---@param d table
---@return string
local function source_id(d) return ya.hash(d.url):sub(1, 8) end

local function slot(d)
	local content = ya.hash(string.format("%s|%s", d.mtime, d.len)):sub(1, 8)
	return source_id(d) .. "-" .. content .. "-" .. d.stem
end

local function root(kind)
	local home = os.getenv("HOME") or "/tmp"
	return Url(home .. "/.cache/yazi/archive-walk/" .. kind)
end

local function target(d, kind)
	return root(kind):join(slot(d))
end

---Record which file a slot was opened from, so walking out can return there.
---This has to go through the filesystem: previewers run in a separate Lua VM
---from the entry function, and the attach usually happens on the preview side,
---so an in-memory table would be invisible to the side that needs to read it.
---@param name string slot name
---@param d table
local function remember_origin(name, d)
	fs.create("dir_all", root("origins"))
	fs.write(root("origins"):join(name), d.url)
end

---Which slot contains `dir`, at any depth inside it.
---@param dir string
---@return string|nil kind, string|nil name
local function slot_of(dir)
	for _, kind in ipairs({ "mnt", "x" }) do
		local prefix = tostring(root(kind)) .. "/"
		if dir:sub(1, #prefix) == prefix then
			local name = dir:sub(#prefix + 1):match("^([^/]+)")
			if name then
				return kind, name
			end
			return nil, nil
		end
	end
	return nil, nil
end

---@param name string slot name
---@return string|nil source path
local function read_origin(name)
	-- `fs` has no read, so cat it — one spawn, only when stepping out.
	local out = Command("cat"):arg(tostring(root("origins"):join(name))):output()
	if out and out.status.success then
		local p = (out.stdout or ""):gsub("%s+$", "")
		return p ~= "" and p or nil
	end
	return nil
end

---The source file for the slot rooted EXACTLY at `dir`, or nil.
---Nil for anything deeper inside a slot, so `h` keeps climbing normally until it
---reaches the top and only then steps back out to where the container lives.
---@param dir string current directory
---@return string|nil
local function origin_of(dir)
	local kind, name = slot_of(dir)
	if not kind or tostring(root(kind):join(name)) ~= dir then
		return nil
	end
	return read_origin(name)
end

---Is this directory a live mount / a finished extraction? Both are "has content".
---@param url table
---@return boolean
local function populated(url)
	local files = fs.read_dir(url, { limit = 1 })
	return files ~= nil and #files > 0
end

---Count live attaches under our mount root, to know when to warn.
---@return integer
local function live_mounts()
	local dirs = fs.read_dir(root("mnt"), {})
	if not dirs then
		return 0
	end
	local n = 0
	for _, dir in ipairs(dirs) do
		if dir.cha.is_dir and populated(dir.url) then
			n = n + 1
		end
	end
	return n
end

---Drop extraction slots belonging to the same source file but an older content
---signature. Without this, every rebuild of an archive leaves its previous
---extraction behind and the cache grows without bound.
---@param d table
---@param keep string slot name to preserve
local function prune_stale(d, keep)
	local dirs = fs.read_dir(root("x"), {})
	if not dirs then
		return
	end
	local prefix = source_id(d) .. "-"
	for _, dir in ipairs(dirs) do
		local name = tostring(dir.name)
		if dir.cha.is_dir and name ~= keep and name:sub(1, #prefix) == prefix then
			fs.remove("dir_all", dir.url)
		end
	end
end

---Attach a disk image read-only. Idempotent: a live mount short-circuits.
---@param d table
---@return table|nil url, string|nil err
function M.attach(d)
	local name = slot(d)
	local mnt = root("mnt"):join(name)
	if populated(mnt) then
		remember_origin(name, d)
		return mnt, nil
	end

	local how = MOUNT[mounter(d.ext and d.ext:lower())]
	if not how then
		return nil, "nothing on this host mounts ." .. tostring(d.ext)
	end

	local ok, err = fs.create("dir_all", mnt)
	if not ok then
		return nil, "cannot create mountpoint: " .. tostring(err)
	end

	local cmd, argv = how.attach(d.url, tostring(mnt))
	local output, cmd_err = Command(cmd):arg(argv):output()
	if not output then
		fs.remove("dir", mnt)
		return nil, "no " .. cmd .. " on PATH: " .. tostring(cmd_err)
	end

	-- Poll for content rather than trusting the exit code (see MOUNT).
	local mounted = false
	for _ = 1, how.settle * 10 do
		if populated(mnt) then
			mounted = true
			break
		end
		ya.sleep(0.1)
	end

	if not mounted then
		-- Release before giving up: anylinuxfs leaves its guest running even when
		-- the NFS mount never lands, so skipping this leaks a VM per failure.
		local rcmd, rargv = how.release(tostring(mnt))
		Command(rcmd):arg(rargv):output()
		fs.remove("dir", mnt)
		local why = (output.stderr or ""):gsub("%s+$", "")
		if why == "" then
			why = cmd .. " exited " .. tostring(output.status.code) .. " without mounting anything"
		end
		return nil, why
	end

	remember_origin(name, d)
	return mnt, nil
end

---Unwrap a compressed tarball in place. 7zz peels exactly one layer, so `x` on
---`foo.tar.zst` yields a lone `foo.tar` and the user would have to press Enter
---twice to reach the files. Collapse that second layer here — tarballs are the
---common case on Linux, where extraction is the only way in.
---@param dir table extraction directory
local function untar_in_place(dir)
	local files = fs.read_dir(dir, { limit = 2 })
	if not files or #files ~= 1 or files[1].cha.is_dir then
		return
	end

	local inner = files[1]
	local ext = inner.url.ext
	if not ext or tostring(ext):lower() ~= "tar" then
		return
	end

	local output = Command("7zz")
		:arg({ "x", "-y", "-bso0", "-bsp0" })
		:arg("-o" .. tostring(dir))
		:arg(tostring(inner.url))
		:output()

	-- On failure the .tar simply stays put and remains walkable by a second
	-- Enter, so this is an improvement that cannot regress into a dead end.
	if output and output.status.success then
		fs.remove("file", inner.url)
	end
end

---Extract an archive into the cache. Idempotent: a finished extraction is reused,
---which is what makes re-entering an archive free after the first O(n) pass.
---@param d table
---@return table|nil url, string|nil err
function M.extract(d)
	local name = slot(d)
	local dir = root("x"):join(name)
	if populated(dir) then
		remember_origin(name, d)
		return dir, nil
	end

	local ok, err = fs.create("dir_all", dir)
	if not ok then
		return nil, "cannot create extract dir: " .. tostring(err)
	end

	local output = Command("7zz")
		:arg({ "x", "-y", "-bso0", "-bsp0" })
		:arg("-o" .. tostring(dir))
		:arg(d.url)
		:output()

	if not output then
		fs.remove("dir", dir)
		return nil, "7zz not found — install it to walk into archives"
	elseif not output.status.success then
		-- Leave nothing half-extracted behind: a partial tree would be
		-- indistinguishable from a finished one on the next entry.
		fs.remove("dir_all", dir)
		local why = (output.stderr or ""):gsub("%s+$", "")
		return nil, why ~= "" and why or ("7zz exited " .. tostring(output.status.code))
	end

	untar_in_place(dir)
	remember_origin(name, d)

	-- Only after a good extraction — a failed one must not evict a working cache.
	prune_stale(d, name)
	return dir, nil
end

-- --- Create ------------------------------------------------------------------

-- The inverse of walking in. Measured on one 69 MB tree (M4 Max):
--
--   squashfs zstd-19   15 MB   1s
--   ULFO dmg           38 MB   9s
--
-- squashfs wins on both axes, and not by a tuning accident: it compresses in
-- 128 KB blocks that span file boundaries and dedups identical files, while DMG
-- compresses each block in isolation and dedups nothing. So squashfs is the
-- default everywhere. DMG survives on macOS for exactly one reason now that
-- anylinuxfs mounts squashfs there too, and the format prompt states it: DMG
-- keeps macOS extended attributes, and mksquashfs drops them.
--
-- Compression levels are already at the knee. ULMO (LZMA) beat ULFO (LZFSE) by
-- 5% for 2-7x the runtime — 68s against 9s on a 494 MB set — and xz beat zstd-19
-- by 7% while decompressing far slower. Neither pays.
--
-- Read-only is not a limitation to route around: every compressed image format
-- here is read-only by definition, and the obvious workaround measured worse
-- than doing nothing (a sparsebundle + afsctool + compact took 78 MB to hold
-- 37 MB, because the bundle allocates bands for the uncompressed writes and
-- `compact` never fully reclaims them). A writable compressed mount is
-- `hdiutil attach img.dmg -shadow <path>`, which belongs to the mount side.
local PACK = {
	{
		id = "squashfs",
		key = "s",
		ext = "sqfs",
		argv = function(src, out)
			return "mksquashfs", { src, out, "-comp", "zstd", "-Xcompression-level", "19", "-no-progress", "-noappend" }
		end,
		missing = "mksquashfs not found — install squashfsTools to pack",
	},
	{
		id = "dmg",
		key = "d",
		ext = "dmg",
		os = "macos",
		argv = function(src, out, name)
			return "hdiutil", { "create", "-srcfolder", src, "-format", "ULFO", "-volname", name, "-ov", out }
		end,
		missing = "hdiutil not found",
	},
}

---Formats this platform can actually produce, in preference order.
---@return table
local function pack_formats()
	local out = {}
	for _, f in ipairs(PACK) do
		if not f.os or f.os == ya.target_os() then
			out[#out + 1] = f
		end
	end
	return out
end

---Pick a format: the named one, the only one, or whichever key the user presses.
---@param id string|nil explicit format id from the keybinding
---@return table|nil format, string|nil err
local function choose_format(id)
	local cands = pack_formats()
	if id then
		for _, f in ipairs(cands) do
			if f.id == id then
				return f, nil
			end
		end
		return nil, "cannot pack as " .. id .. " on this platform"
	end
	if #cands == 1 then
		return cands[1], nil
	end

	local which = {}
	for _, f in ipairs(cands) do
		local desc
		if f.id == "squashfs" then
			-- mksquashfs prints `Unrecognised xattr prefix com.apple.provenance`
			-- and carries on: squashfs drops macOS extended attributes, taking
			-- decmpfs compression and quarantine flags with them. That is the one
			-- thing DMG still does better, so it has to be visible while choosing,
			-- not reported afterwards when the source may already be gone.
			desc = "SquashFS — 2.5x smaller, 9x faster; drops macOS xattrs"
		else
			desc = "DMG — bigger and slower; keeps macOS xattrs"
		end
		which[#which + 1] = { on = f.key, desc = desc }
	end

	local i = ya.which { cands = which }
	return i and cands[i] or nil, nil
end

---Build a read-only compressed image of `d` inside `dest`.
---@param d table source entry, needing only `url` and `name`
---@param fmt table
---@param dest table directory the image is written to
---@return table|nil url, string|nil err
local function build(d, fmt, dest)
	-- `fs.unique` picks the name and claims it by creating the file: packing
	-- twice leaves the first image alone, and the second lands on
	-- `myproject.v2_1.sqfs` — it suffixes before the extension. The zero-byte
	-- placeholder it leaves behind is why both tools take an overwrite flag.
	local out = fs.unique("file", dest:join(d.name .. "." .. fmt.ext))
	if not out then
		return nil, "cannot place the image in " .. tostring(dest)
	end

	local cmd, argv = fmt.argv(d.url, tostring(out), d.name)
	local output, cmd_err = Command(cmd):arg(argv):output()

	-- Every failure path removes `out`: on a truncated image, because both tools
	-- write as they go and half a file looks packable until you open it; on a
	-- missing tool, because the claimed placeholder would otherwise stay behind
	-- and push the next attempt onto `_1`.
	if not output then
		fs.remove("file", out)
		return nil, fmt.missing .. " (" .. tostring(cmd_err) .. ")"
	elseif not output.status.success then
		fs.remove("file", out)
		local why = (output.stderr or ""):gsub("%s+$", "")
		return nil, why ~= "" and why or (cmd .. " exited " .. tostring(output.status.code))
	end
	return out, nil
end

-- --- Preview -----------------------------------------------------------------

local hovered_url = ya.sync(function()
	local h = cx.active.current.hovered
	return h and tostring(h.url) or ""
end)

---Bounded depth-first listing of a mounted volume, budgeted to the visible area.
local function collect(url, depth, budget, out)
	if #out >= budget then
		return
	end
	local files = fs.read_dir(url, { limit = budget })
	if not files then
		return
	end
	table.sort(files, function(a, b)
		if a.cha.is_dir ~= b.cha.is_dir then
			return a.cha.is_dir
		end
		return a.name < b.name
	end)
	for _, f in ipairs(files) do
		if #out >= budget then
			return
		end
		out[#out + 1] = { file = f, depth = depth }
		if f.cha.is_dir and depth < 3 then
			collect(f.url, depth + 1, budget, out)
		end
	end
end

local function render_tree(job, mnt)
	local items = {}
	collect(mnt, 0, job.skip + job.area.h, items)

	if #items == 0 then
		return ya.preview_widget(job, ui.Text("Empty volume"):area(job.area))
	end

	local left, right = {}, {}
	for i = job.skip + 1, math.min(#items, job.skip + job.area.h) do
		local it = items[i]
		-- th.icon:match is the nightly spelling; File:icon() deprecates there
		-- (a notification per rendered row) but is the only API on stable.
		local icon = th.icon and th.icon:match(it.file) or it.file:icon()
		right[#right + 1] = it.file.cha.is_dir and " " or (" " .. ya.readable_size(it.file.cha.len or 0) .. " ")
		left[#left + 1] = ui.Line {
			string.rep(" │", it.depth),
			icon and ui.Span(" " .. icon.text .. " "):style(icon.style) or " ",
			ui.truncate(it.file.name, {
				rtl = true,
				max = math.max(0, job.area.w - (it.depth * 2) - 4 - ui.width(right[#right])),
			}),
		}
	end

	ya.preview_widget(job, {
		ui.Text(left):area(job.area),
		ui.Text(right):area(job.area):align(ui.Align.RIGHT),
	})
end

local function message(job, text)
	ya.preview_widget(job, ui.Text(ui.Line(text):reverse()):area(job.area):wrap(ui.Wrap.YES))
end

function M:peek(job)
	local d = M.describe(job.file)

	-- Not a mountable image on this platform: the built-in 7zz-backed archive
	-- previewer already renders a better tree than we could.
	if M.kind(d.ext, d.is_dir) ~= "image" then
		return require("archive"):peek(job)
	end

	local mnt = target(d, "mnt")
	if populated(mnt) then
		return render_tree(job, mnt)
	end

	-- Hovering is what hides the mount cost, but it must not hoard: on macOS a
	-- .sqfs costs a whole microVM, so past the warning line let the tree render
	-- from 7zz and leave mounting to a deliberate Enter.
	if live_mounts() >= MOUNT_WARN_AT then
		return require("archive"):peek(job)
	end

	-- Debounce, then confirm the cursor is still here. Scrolling past an image
	-- must not attach it.
	message(job, "Disk image — attaching to walk in…")
	ya.sleep(HOVER_DEBOUNCE)
	if hovered_url() ~= d.url then
		return
	end

	local _, err = M.attach(d)
	if hovered_url() ~= d.url then
		return
	elseif err then
		-- Same degrade as entry: 7zz reads it, so show the tree rather than an
		-- error nobody can act on from a preview pane.
		return require("archive"):peek(job)
	end

	-- Mounted now — redraw through the same path, which takes the render branch.
	ya.emit("peek", { job.skip, only_if = job.file.url, force = true })
end

function M:seek(job) require("code"):seek(job) end

-- --- Entry -------------------------------------------------------------------

local hovered = ya.sync(function()
	local h = cx.active.current.hovered
	return h and M.describe(h) or nil
end)

local cwd = ya.sync(function() return tostring(cx.active.current.cwd) end)

---What `pack` acts on: everything selected, or the hovered entry when the
---selection is empty. Same convention as `chmod`, so the selection means the
---same thing across the config. Paths only — a Url does not cross `ya.sync`.
---@return table paths
local selection = ya.sync(function()
	local tab, paths = cx.active, {}
	-- #4096: nightly yields File (tostring gives "File: 0x…"), stable yields
	-- Url. `f.url or f` reads the path on both.
	for _, f in pairs(tab.selected) do
		paths[#paths + 1] = tostring(f.url or f)
	end
	if #paths == 0 and tab.current.hovered then
		paths[1] = tostring(tab.current.hovered.url)
	end
	return paths
end)

---Detach every live mount under our root, and drop the empty slots.
---@return integer detached
local function unmount_all()
	local dirs = fs.read_dir(root("mnt"), {})
	if not dirs then
		return 0
	end
	local n = 0
	for _, dir in ipairs(dirs) do
		if dir.cha.is_dir then
			if populated(dir.url) then
				-- Whoever mounted it has to release it, and which helper that was
				-- follows from the source file's extension — already recorded in
				-- `origins` at attach time, so this needs no second bookkeeping
				-- file. Where that record is missing, fall back to the platform's
				-- image mounter, which is what every mount predating it used.
				local src = read_origin(tostring(dir.name))
				local ext = src and Url(src).ext
				local how = MOUNT[mounter(ext and tostring(ext):lower()) or mounter("dmg") or mounter("sqfs")]
				local out
				if how then
					local cmd, argv = how.release(tostring(dir.url))
					out = Command(cmd):arg(argv):output()
				end
				if out and out.status.success then
					n = n + 1
				end
			end
			-- `dir`, not `dir_all`: a release that silently failed leaves the
			-- mountpoint populated, and this must not delete a live mount's tree.
			fs.remove("dir", dir.url)
		end
	end
	return n
end

function M:entry(job)
	local args = job.args or {}

	-- The inverse of walking in, bound to the same `h` that leaves a directory.
	-- Climbing out of a slot root with plain `leave` would land in the cache dir,
	-- which is a dead end nobody asked to visit; `reveal` returns to the
	-- container's own folder and puts the cursor back on it. The image stays
	-- attached so stepping back in is free — `g m` is the explicit cleanup.
	if args[1] == "leave" then
		local src = origin_of(cwd())
		if src then
			return ya.emit("reveal", { Url(src) })
		end
		return ya.emit("leave", {})
	end

	-- Pack is a batch, one image per source rather than one image around all of
	-- them: each selected folder becomes its own `<name>.<ext>` in the directory
	-- you are standing in. Source and destination are independent, so the gesture
	-- is select wherever the folders live, walk to an archive folder, press the
	-- key. A single hovered folder is the same operation with a selection of one,
	-- and lands in the same place it always did, since a hovered entry's parent is
	-- the working directory.
	if args[1] == "pack" then
		-- Commit visual mode first: until it ends, what is under the cursor is not
		-- yet in `tab.selected`. Same first move as `chmod`.
		ya.emit("escape", { visual = true })

		local dest = Url(cwd())
		if slot_of(cwd()) then
			-- The images would land inside a read-only mount or the extract cache.
			-- Both are wrong destinations, and the mount fails with an errno nobody
			-- should have to decode. Sources may sit in a container — only where the
			-- images are written matters, which is what makes packing a folder back
			-- out of an opened image work.
			return ya.notify {
				title = "archive-walk",
				content = "You are inside an opened container — walk out before packing",
				level = "warn",
				timeout = 5,
			}
		end

		-- Files are skipped, not fatal: a lone file inside a compressed image is
		-- not what anyone means by packing, and dropping a batch of twenty over one
		-- stray selection is the worse failure. The count is reported either way.
		local items, skipped = {}, 0
		for _, path in ipairs(selection()) do
			local url = Url(path)
			local cha = fs.cha(url)
			if cha and cha.is_dir and url.name then
				items[#items + 1] = { url = path, name = tostring(url.name) }
			else
				skipped = skipped + 1
			end
		end

		if #items == 0 then
			return ya.notify {
				title = "archive-walk",
				content = "Pack works on directories — select or hover one",
				level = "warn",
				timeout = 4,
			}
		end

		local fmt, ferr = choose_format(args[2])
		if ferr then
			return ya.notify { title = "archive-walk", content = ferr, level = "error", timeout = 5 }
		elseif not fmt then
			return -- dismissed the picker
		end

		ya.notify {
			title = "archive-walk",
			content = string.format(
				"Packing %s as %s…",
				#items == 1 and items[1].name or (#items .. " folders"),
				fmt.id
			),
			timeout = 3,
		}

		-- One failure does not stop the batch: the folders are unrelated, so the
		-- nineteen that can be packed still should be, and the summary names what
		-- could not.
		local began = ya.time()
		local built, bytes, failed = {}, 0, {}
		for _, item in ipairs(items) do
			local out, err = build(item, fmt, dest)
			if err then
				failed[#failed + 1] = item.name .. ": " .. err
			else
				built[#built + 1] = out
				local cha = fs.cha(out)
				bytes = bytes + (cha and cha.len or 0)
			end
		end

		local summary
		if #built == 1 then
			summary = string.format(
				"%s — %s in %.1fs",
				tostring(built[1]):match("([^/]+)$"),
				ya.readable_size(bytes),
				ya.time() - began
			)
		elseif #built > 1 then
			summary = string.format("%d images — %s in %.1fs", #built, ya.readable_size(bytes), ya.time() - began)
		else
			summary = "nothing packed"
		end
		if skipped > 0 then
			summary = summary .. string.format(" (%d skipped — not a directory)", skipped)
		end
		if #failed > 0 then
			-- Two failures fill a notification; the rest would push the summary off
			-- the end of it, so they are counted instead.
			local shown = table.concat(failed, "; ", 1, math.min(#failed, 2))
			if #failed > 2 then
				shown = shown .. string.format("; +%d more", #failed - 2)
			end
			summary = summary .. " — failed: " .. shown
		end

		ya.notify {
			title = "archive-walk",
			content = summary,
			level = #failed > 0 and "error" or nil,
			timeout = #failed > 0 and 10 or 5,
		}

		if #built == 0 then
			return
		end
		-- Drop the selection, or the next press packs the same folders again into
		-- `_1` copies of images that are already sitting there.
		ya.emit("escape", { select = true })
		-- Land on the first image built: it is walkable by the same Enter that
		-- walks into every other container, so packing and checking the result are
		-- one gesture.
		return ya.emit("reveal", { built[1] })
	end

	if args[1] == "unmount" then
		-- A mount cannot be released while it is the working directory, so step
		-- out of it first. Without this, `g m` pressed inside a mount reports
		-- detaching nothing and leaves it attached.
		local kind, name = slot_of(cwd())
		if kind then
			local src = read_origin(name)
			ya.emit("cd", { src and Url(src).parent or Url(os.getenv("HOME") or "/") })
			ya.sleep(0.3)
		end

		local n = unmount_all()
		return ya.notify {
			title = "archive-walk",
			content = n == 1 and "Detached 1 image" or string.format("Detached %d images", n),
			timeout = 3,
		}
	end

	local d = hovered()
	if not d then
		return
	end

	local kind = M.kind(d.ext, d.is_dir)
	if not kind then
		return ya.emit("open", {})
	end

	local url, err
	if kind == "image" then
		if live_mounts() >= MOUNT_WARN_AT then
			ya.notify {
				title = "archive-walk",
				content = string.format("%d images still attached — `g m` detaches them", MOUNT_WARN_AT),
				level = "warn",
				timeout = 5,
			}
		end
		url, err = M.attach(d)
		if err then
			-- Mounting is the fast path, not the only one: 7zz reads every format
			-- that gets here, so a failed attach falls back to the O(n) walk. Say
			-- so rather than degrading silently — an anylinuxfs guest that stopped
			-- starting is otherwise invisible until someone notices the latency.
			ya.notify {
				title = "archive-walk",
				content = "Mount failed, extracting instead — " .. err,
				level = "warn",
				timeout = 6,
			}
			url, err = M.extract(d)
		end
	else
		url, err = M.extract(d)
	end

	if err then
		return ya.notify { title = "archive-walk", content = err, level = "error", timeout = 6 }
	end
	ya.emit("cd", { url })
end

return M
