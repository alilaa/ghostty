GhosnTTy for **Ubuntu 26.04, x86-64**.

- Compact project-colored bottom tabs; no new-tab button. Use Ctrl+Shift+U.
- Stable Codex colors across spinner titles, with red attention states.
- Ctrl+H/J/K/L navigation and Ctrl+Arrow resizing across Neovim and terminal splits.
- Kanagawa palette and a bundled WezTerm-style profile on fresh installs.

Download the `.deb` and install it with:

```sh
sudo apt install ./ghosntty_*_ubuntu26.04_amd64.deb
ghosntty
```

The package installs alongside upstream Ghostty and preserves existing
`~/.config/ghostty` files. To try the bundled profile explicitly:

```sh
ghosntty --config-default-files=false --config-file=/usr/share/ghosntty/profile/config.ghostty
```

Neovim with smart-splits also needs this setup after loading smart-splits:

```lua
if vim.env.GHOSTTY_NVIM_RUNTIME then
  vim.opt.runtimepath:append(vim.env.GHOSTTY_NVIM_RUNTIME)
  require("ghostty_control").setup()
end
```

The custom bar supports keyboard tab reordering; mouse drag/reorder, detach,
and tab context menus are not implemented. The editor bridge supports local
desktop sessions, not SSH or nested multiplexers. Personal wallpaper and
dotfiles are not bundled. AI-assisted implementation with OpenAI Codex.
