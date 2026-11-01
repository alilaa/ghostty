-- Adapter for this fork. A persistent helper holds one D-Bus connection;
-- movement never starts a shell, gdbus, or another Ghostty process.
local M = {}
local job, serial, pending, partial = nil, 0, {}, ""
local configured = false
local claimed = false
local last_project, last_root
local bridge = vim.fs.normalize(vim.fs.joinpath(
  vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "..", "..", "editor_bridge.py"
))

local function detect()
  return vim.env.GHOSTTY_CONTROL_BUS ~= nil and vim.env.GHOSTTY_SURFACE_ID ~= nil
end

local function start()
  if job then return true end
  job = vim.fn.jobstart({ "python3", bridge }, {
    on_stdout = function(_, data)
      partial = partial .. table.concat(data, "\n")
      while true do
        local stop = partial:find("\n", 1, true)
        if not stop then break end
        local line = partial:sub(1, stop - 1)
        partial = partial:sub(stop + 1)
        local ok, response = pcall(vim.json.decode, line)
        if ok and type(response) == "table" and response.id and pending[response.id] then
          pending[response.id].response = response
        end
      end
    end,
    on_exit = function(id)
      if job == id then job, claimed, partial = nil, false, "" end
    end,
  })
  if job <= 0 then job = nil; return false end
  return true
end

local function call(operation, value, amount)
  if not detect() or not start() then return false end
  serial = serial + 1
  local id = serial
  local entry = {}
  pending[id] = entry
  local ok = pcall(vim.fn.chansend, job, vim.json.encode({
    id = id, operation = operation, value = value or "", amount = amount or 0,
  }) .. "\n")
  if ok then vim.wait(200, function() return entry.response ~= nil or job == nil end, 1) end
  pending[id] = nil
  return entry.response ~= nil and entry.response.performed == true
end

local function claim()
  claimed = call("editor", "on")
  return claimed
end

local function release()
  if job then call("editor", "off") end
  claimed = false
end

function M.project(name)
  if not name or name == last_project then return end
  if call("project", name) then last_project = name end
end

local function project_for_buffer()
  local buffer = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buffer)
  local source = name:match("^oil://(.+)$")
  if not source and vim.bo[buffer].buftype == "" and not name:match("^%a[%w.+-]*://") then
    source = name ~= "" and name or vim.uv.cwd()
  end
  local root = source and vim.fs.root(source, ".git") or nil
  if root then last_root = root end
  local project = vim.fs.basename(last_root or vim.uv.cwd() or "nvim")
  for _, prefix in ipairs({
    { "^property[%.%-]meps[%.%-]", "P.M." },
    { "^property[%.%-]", "P." },
    { "^meps[%.%-]", "M." },
  }) do
    local _, last = project:lower():find(prefix[1])
    if last then project = prefix[2] .. project:sub(last + 1); break end
  end
  M.project(project)
end

local backend = {
  name = "ghostty-linux",
  protocol_version = "3.0.0",
  detect = detect,
  move = function(direction) return call("move", direction) end,
  resize = function(direction, opts) return call("resize", direction, (opts or {}).amount or 3) end,
}

function M.setup(opts)
  if configured or not detect() then return false end
  configured = true
  opts = opts or {}
  if opts.bridge then bridge = opts.bridge end
  local splits = require("smart-splits")
  if splits.PROTOCOL_VERSION then
    splits.setup({ mux = { backend = backend }, move = { at_edge = "stop" } })
  else
    -- Compatibility with older smart-splits versions.
    -- This process is in Ghostty; WezTerm sessions keep their original setup.
    local mux = require("smart-splits.mux")
    mux.__mux = {
      type = "ghostty",
      is_in_session = detect,
      update_mux_layout_details = function() end,
    }
    mux.is_enabled = detect
    mux.move_pane = function(direction) return call("move", direction) end
    mux.resize_pane = function(direction, amount) return call("resize", direction, amount or 3) end
    require("smart-splits.config").at_edge = "stop"
  end
  local group = vim.api.nvim_create_augroup("GhosttyEditorControl", { clear = true })
  vim.api.nvim_create_autocmd({ "VimEnter", "VimResume", "FocusGained" }, {
    group = group, callback = function() claim() end,
  })
  vim.api.nvim_create_autocmd("VimSuspend", { group = group, callback = release })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group, callback = function()
      release()
      if job then pcall(vim.fn.chanclose, job, "stdin") end
    end,
  })
  vim.api.nvim_create_autocmd({ "VimEnter", "BufEnter", "DirChanged" }, {
    group = group, callback = project_for_buffer,
  })
  if vim.v.vim_did_enter == 1 then claim(); project_for_buffer() end
  return true
end

return M
