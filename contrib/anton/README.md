# Anton's Linux integration

This branch starts from Ghostty v1.4.0. It adds opt-in project-colored tabs
and editor navigation for the GTK application. Both options default to false.
The implementation was written with OpenAI Codex; desktop validation is still
required before using it as the daily terminal.

## Build and launch separately

Use Zig 0.17.0 and the Linux dependencies in [HACKING.md](../../HACKING.md).
The editor adapter additionally needs Python 3 with PyGObject (`gi.repository.Gio`).
Nothing in this directory automatically installs or replaces your terminal.

```sh
zig build -Demit-docs=false
./zig-out/bin/ghostty --class=com.anton.Ghostty \
  --config-default-files=false \
  --config-file="$PWD/contrib/anton/config.ghostty"
```

The sample config enables `gtk-project-tabs` and `gtk-editor-control`, places
tabs at the bottom, and preserves Ctrl+H/J/K/L and Ctrl+Arrow. It also provides
Ctrl+Shift+F12 to reset key tables. Editor control requires restarting Ghostty.

## Neovim

After the existing smart-splits setup, add this to your Neovim configuration
(adjust the checkout path if needed):

```lua
vim.opt.runtimepath:append(vim.fn.expand("~/src/ghostty/contrib/anton/nvim"))
require("ghostty_control").setup()
```

Keep your existing smart-splits movement and resize mappings. The adapter is
inactive outside this fork, so existing WezTerm sessions keep their behavior.
It supports both the smart-splits revision pinned in your dotfiles and its v3
backend interface. The initial adapter uses stop-at-edge semantics.

The adapter derives project titles from Git roots, including oil.nvim paths,
and applies the same organizational prefix abbreviations as your dotfiles.
It preserves the last project when visiting special buffers. Project titles
override the changing pane title, so a Codex spinner does not change identity.

## Implementation

`gtk-project-tabs` uses a separate GTK strip backed by the existing AdwTabView.
It preserves the sixteen-color djb2 palette, contrasting text, hover tint,
active marker, and Codex title-based green/red states. New-tab and close buttons
use the existing tab lifecycle. Keyboard tab switching and reordering continue
to use Ghostty actions. The custom strip does not yet implement drag-to-reorder,
drag-to-detach, or the native tab context menu. Codex detection currently uses
the pane title; foreground-process fallback is not yet implemented.

`gtk-editor-control` exports the versioned D-Bus interface
`com.anton.Ghostty.EditorControl1` at `/com/anton/Ghostty/EditorControl`.
It accepts `Execute(surface: uint64, operation: string, value: string,
amount: uint32) -> performed: bool`. Operations are:

| Operation | Value | Amount |
| --- | --- | --- |
| `editor` | `on` or `off` | ignored |
| `move` | `left`, `right`, `up`, `down` | ignored |
| `resize` | direction | cells, 1–1000 |
| `project` | project title, empty clears override | ignored |

`GHOSTTY_CONTROL_BUS` holds this process's unique D-Bus name, and
`GHOSTTY_SURFACE_ID` identifies the calling pane. Moves and resizes are rejected
if that pane is no longer focused. Resizing converts cells into logical pixels
using the current font and content scale. A failed move returns false to
smart-splits rather than pretending to have moved.

One persistent Python helper per Neovim instance holds the GIO connection. It
exchanges JSON lines over pipes with Lua, without shell command interpolation.
The adapter releases its dedicated key table on suspend/exit. Pipe EOF releases
it after an editor crash; shell command-finish events provide another recovery
path. A user key table above the editor table is preserved until it is popped.
If both the editor and helper are killed without shell integration, use the
recovery shortcut. This first version targets local desktop Neovim sessions;
SSH and nested terminal multiplexers need separate integration.

## Verification

```sh
zig test src/apprt/gtk/control_request.zig
zig test src/apprt/gtk/project_colors.zig
python -m unittest discover -s contrib/anton/tests -p 'test_*.py' -v
GHOSTTY_TEST_BACKEND=v2 nvim --headless -u NONE -l contrib/anton/tests/test_adapter.lua
GHOSTTY_TEST_BACKEND=v3 nvim --headless -u NONE -l contrib/anton/tests/test_adapter.lua
```

For an additional geometry test using the exact smart-splits version in the
dotfiles, point `GHOSTTY_SMART_SPLITS_PATH` at a checkout of commit
`ec76708f1617ef9e2ac353357fe52d2c997a0f06` and run:

```sh
GHOSTTY_SMART_SPLITS_PATH=/path/to/smart-splits.nvim \
  nvim --headless -u NONE -l contrib/anton/tests/test_real_splits.lua
```

Desktop checks still required: movement through a nested Neovim/Ghostty layout;
resize at different display scales; suspend/resume and crash recovery; switching
projects and active tabs; Codex attention titles; closing/reordering tabs; config
reload and disabling the custom strip. The sandbox cannot open a display or
session D-Bus socket, so headless adapter tests use a protocol fixture.
