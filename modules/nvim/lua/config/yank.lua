-- ============================================================================
-- Yank to Outer Tmux TTY (for popup clipboard workaround)
-- ============================================================================

local M = {}

function M.to_outer_tmux()
  -- Get the yanked content from the unnamed register
  local content = vim.fn.getreg('"')
  if content == "" then
    return
  end

  -- Try multiple sources for outer TTY:
  -- 1. Shell env var
  -- 2. Tmux server environment (set by start-shell.sh)
  -- 3. Query outer tmux directly
  local tty = os.getenv("OUTER_TTY")
  if not tty or tty == "" then
    -- Query current tmux server's environment
    local env_output = vim.fn.system("tmux show-environment OUTER_TTY 2>/dev/null"):gsub("%s+$", "")
    tty = env_output:match("OUTER_TTY=(.+)")
  end
  if not tty or tty == "" then
    -- Fall back to querying outer tmux
    tty = vim.fn.system("tmux -L zt list-clients -F '#{client_tty}' 2>/dev/null | head -1"):gsub("%s+$", "")
  end

  if not tty or tty == "" then
    vim.notify("Could not find outer tmux TTY", vim.log.levels.WARN)
    return
  end

  -- Base64 encode (no wrap) and send OSC 52 to outer tmux's TTY
  local encoded = vim.fn.system("echo -n " .. vim.fn.shellescape(content) .. " | base64 -w0")
  local cmd = string.format("printf '\\033]52;c;%s\\007' > %s", encoded, tty)
  vim.fn.system(cmd)
end

-- ============================================================================
-- Yank File References
-- ============================================================================

local function get_git_root()
  local root = vim.fn.systemlist("git rev-parse --show-toplevel 2>/dev/null")[1]
  if vim.v.shell_error == 0 and root and #root > 0 then
    return root
  end
  return nil
end

local function relative_path()
  local abs = vim.fn.expand("%:p")
  local git_root = get_git_root()
  if git_root then
    return abs:gsub("^" .. vim.pesc(git_root) .. "/", "")
  end
  return vim.fn.fnamemodify(abs, ":~:.")
end

--- @param is_visual boolean  whether the keymap was triggered from visual mode
--- @return number|nil start line
--- @return number|nil end line
local function get_range(is_visual)
  if not is_visual then
    return nil, nil
  end
  -- "v" = visual-start line, "." = cursor line — valid while still in visual mode
  local s = vim.fn.line("v")
  local e = vim.fn.line(".")
  if s > e then
    s, e = e, s
  end
  if s > 0 and e > 0 then
    return s, e
  end
  return nil, nil
end

function M.yank_ref(is_visual)
  local path = relative_path()
  local s, e = get_range(is_visual)
  if s then
    local ref = string.format("@%s#L%d-%d", path, s, e)
    vim.fn.setreg("+", ref)
    vim.notify(ref)
  else
    local ref = "@" .. path
    vim.fn.setreg("+", ref)
    vim.notify(ref)
  end
end

function M.yank_ref_abs(is_visual)
  local path = vim.fn.expand("%:p")
  local s, e = get_range(is_visual)
  if s then
    local ref = string.format("@%s#L%d-%d", path, s, e)
    vim.fn.setreg("+", ref)
    vim.notify(ref)
  else
    local ref = "@" .. path
    vim.fn.setreg("+", ref)
    vim.notify(ref)
  end
end

function M.yank_xml_empty(is_visual)
  local filepath = vim.fn.expand("%:p")
  local s, e = get_range(is_visual)
  if not s then
    s = vim.fn.line(".")
    e = s
  end
  local xml = string.format('<content filepath="@%s" lines="L%d-%d">\n  \n</content>', filepath, s, e)
  vim.fn.setreg("+", xml)
  vim.notify(string.format("Copied ref: @%s L%d-%d", filepath, s, e))
end

function M.yank_xml_full(is_visual)
  local filepath = vim.fn.expand("%:p")
  local s, e = get_range(is_visual)
  local lines
  if s then
    lines = vim.fn.getline(s, e)
  else
    s = vim.fn.line(".")
    e = s
    lines = { vim.fn.getline(s) }
  end
  local content = table.concat(lines, "\n")
  local xml = string.format('<content filepath="%s" lines="L%d-%d">\n%s\n</content>', filepath, s, e, content)
  vim.fn.setreg("+", xml)
  vim.notify(string.format("Copied: %s L%d-%d", filepath, s, e))
end

return M
