-- Supply GHOSTTY_SMART_SPLITS_PATH with the pinned smart-splits checkout.
local root = vim.uv.cwd() .. "/contrib/ghosntty"
vim.opt.runtimepath:append(vim.env.GHOSTTY_SMART_SPLITS_PATH)
vim.opt.runtimepath:append(root .. "/nvim")
vim.env.GHOSTTY_CONTROL_BUS = ":1.42"
vim.env.GHOSTTY_SURFACE_ID = "0xfedcba9876543210"
local trace = vim.fn.tempname()
vim.env.GHOSTTY_BRIDGE_TRACE = trace
local splits = require("smart-splits")
splits.setup({ multiplexer_integration = false, at_edge = "stop" })
require("ghostty_control").setup({ bridge = root .. "/tests/fake_bridge.py" })
vim.api.nvim_exec_autocmds("VimEnter", {})
vim.cmd("vsplit")
vim.cmd("wincmd h")
local first = vim.api.nvim_get_current_win()
splits.move_cursor_right()
assert(vim.api.nvim_get_current_win() ~= first, "Move inside Neovim before asking Ghostty")
splits.move_cursor_right()
vim.cmd("only")
splits.resize_down(7)
local move_requests, resize_requests = 0, 0
for _, line in ipairs(vim.fn.readfile(trace)) do
  local r = vim.json.decode(line)
  if r.operation == "move" then
    move_requests = move_requests + 1
    assert(r.value == "right")
  elseif r.operation == "resize" then
    resize_requests = resize_requests + 1
    assert(r.value == "down" and r.amount == 7)
  end
end
assert(move_requests == 1, "Only the movement at the editor edge reaches Ghostty")
assert(resize_requests == 1, "A full-height Neovim window delegates resizing")
vim.api.nvim_exec_autocmds("VimLeavePre", {})
vim.fn.delete(trace)
print("Pinned smart-splits geometry: passed")
vim.cmd("qa!")
