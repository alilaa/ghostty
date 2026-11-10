GhosnTTy for **Arch Linux and Ubuntu 26.04, x86-64**.

- Compact project-colored bottom tabs; no new-tab button. Use Ctrl+Shift+U.
- 22px tab bar with a caret on the current tab and a brief brighten-and-fade flash on tab switch.
- Neovim tabs show the Neovim logo and that instance's working directory.
- One random palette color per Codex tab, stable through spinner updates;
  red only while waiting for input, then back to the same color.
- Ctrl+H/J/K/L navigation and Ctrl+Arrow resizing across Neovim and terminal splits.
- Kanagawa palette and a bundled WezTerm-style profile on fresh installs.

Download the package for your system. On Ubuntu 26.04:

```sh
sudo apt install ./ghosntty_*_ubuntu26.04_amd64.deb
ghosntty
```

On Arch Linux:

```sh
sudo pacman -U ./ghosntty-*-x86_64.pkg.tar.zst
ghosntty
```

The Arch build uses the 2026/10/01 repository snapshot (GTK 4.22.5 and
glibc 2.44). Native runtime dependencies must be installed; the package declares
them. Build manifests record the exact library versions for both platforms.
`SHA256SUMS` covers both packages and their manifests.

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
