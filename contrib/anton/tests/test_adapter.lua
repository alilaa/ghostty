-- Run from the repository root, once with GHOSTTY_TEST_BACKEND=v2 and v3.
local root = vim.uv.cwd() .. "/contrib/anton"
vim.opt.runtimepath:append(root .. "/nvim")
vim.env.GHOSTTY_CONTROL_BUS = ":1.42"
vim.env.GHOSTTY_SURFACE_ID = "0xfedcba9876543210"
local trace = vim.fn.tempname()
vim.env.GHOSTTY_BRIDGE_TRACE = trace
local mux, config, backend = {}, {}, nil
package.loaded["smart-splits.mux"] = mux
package.loaded["smart-splits.config"] = config
package.loaded["smart-splits"] = {
  PROTOCOL_VERSION = vim.env.GHOSTTY_TEST_BACKEND == "v3" and "3.0.0" or nil,
  setup = function(opts) backend = opts.mux.backend end,
}
local control = require("ghostty_control")
assert(control.setup({ bridge = root .. "/tests/fake_bridge.py" }))
vim.api.nvim_exec_autocmds("VimEnter", {})
local move = backend and backend.move or mux.move_pane
local resize = backend and backend.resize or mux.resize_pane
assert(move("right") == true)
assert(move("left") == false, "The actual failure must reach smart-splits")
if backend then assert(resize("down", { amount = 7 })) else assert(resize("down", 7)) end
control.project("unicode å;$(literal)")
control.project("unicode å;$(literal)")
vim.api.nvim_exec_autocmds("VimSuspend", {})
vim.api.nvim_exec_autocmds("VimResume", {})
vim.api.nvim_exec_autocmds("FocusGained", {})
vim.api.nvim_exec_autocmds("FocusGained", {})
local claims, projects, resizes = 0, 0, 0
for _, line in ipairs(vim.fn.readfile(trace)) do
  local r = vim.json.decode(line)
  if r.operation == "editor" and r.value == "on" then claims = claims + 1 end
  if r.operation == "project" and r.value == "unicode å;$(literal)" then projects = projects + 1 end
  if r.operation == "resize" and r.amount == 7 then resizes = resizes + 1 end
end
assert(claims >= 4, "Lifecycle autocmds must survive returning true from claim")
assert(projects == 1, "Repeated identical project titles should be cached")
assert(resizes == 1, "The requested cell count must survive the adapter")
vim.api.nvim_exec_autocmds("VimLeavePre", {})
vim.fn.delete(trace)
print("Ghostty adapter " .. (vim.env.GHOSTTY_TEST_BACKEND or "v2") .. ": passed")
vim.cmd("qa!")
