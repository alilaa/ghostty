# GhosnTTy: restart-in-place after GPU reset (step 2b)

Repo: `/home/anton/src/ghostty`, branch `anton/linux-project-tabs-navigation`
(GhosnTTy = Ghostty fork, GTK apprt, OpenGL renderer, Linux only).
Do not commit/push, do not open issues/PRs. Run `zig fmt` on changed files.
Build like CI: `contrib/ghosntty/ci/build.sh`; targeted tests via
`zig build test -Dtest-filter=<name>`.

## Background / why

Under WSL2 (Mesa d3d12 → Intel Iris Xe) Windows periodically TDRs the GPU
(LiveKernelEvent 141). Every GL context in the process is lost: Ghostty's
per-surface EGL contexts AND GTK's GSK context (tab bar turns into black
boxes). GTK cannot recover its display-wide GL context, so in-process
recovery is impossible. A fresh process renders fine.

Commit `201a966f2` ("log gpu resets") added detection in
`src/renderer/OpenGL.zig`: contexts are created with
`EGL_LOSE_CONTEXT_ON_RESET`, `glGetGraphicsResetStatus` is polled in
`drawFrameEnd` → `checkGpuReset()` which logs once:
`GPU reset detected, this surface can no longer render cause=... time=...`.

Goal: on GPU reset (and on a manual keybind), **execve() the same binary in
place, keeping PID, child processes and PTYs**, and restore windows, tabs,
splits, titles and terminal contents (incl. scrollback) in the new process.
Running shells/nvim/ssh must not notice anything except a SIGWINCH.

## Why this works

- `execve` keeps the PID → shells stay *our* children (waitpid/pidfd still
  work), no SIGHUP because PTY masters stay open.
- Only the PTY master fds need to survive: `src/pty.zig` sets `FD_CLOEXEC`
  on the master; clear it right before exec. Everything else (Wayland,
  D-Bus, EGL, pipes, eventfds) is CLOEXEC and is dropped → fresh GPU state.
- `xev.Process.init(pid)` (used in `termio/Exec.zig threadEnter`) is a
  pidfd and works for any existing child, including zombies that exited
  during the restart gap (exit is then reported immediately).

## Components

### 1. Triggers
- New keybind action `restart_in_place` (`src/input/Binding.zig` +
  docs, apprt action plumbing, handled in
  `src/apprt/gtk/class/application.zig`). Primary test vehicle.
- Optional debug action `debug_simulate_gpu_reset` that goes through the
  exact same automatic path.
- Automatic: `OpenGL.checkGpuReset()` runs on the renderer thread. On
  first detection send a message to the surface/app mailbox (do NOT touch
  GTK from the render thread) → app-level apprt action `gpu_reset` →
  GTK app schedules a restart on the main loop (debounce ~1–2 s so all
  surfaces/GSK settle and the GPU finishes resetting; coalesce multiple
  surfaces reporting).
- Config: `gpu-reset-action = restart | log` (default `restart` in the
  ghosntty profile, `log` upstream-default), documented in `Config.zig`.
- Loop guard: carry `GHOSNTTY_RESTART_COUNT` + first timestamp in the
  env; if >3 automatic restarts within 60 s, stop auto-restarting and only
  log.

### 2. Snapshot (old process, GTK main thread)
Data model (new file e.g. `src/apprt/gtk/restart.zig`, serialized as JSON
with VT blobs either base64 in the JSON or in a sidecar file):

```
Snapshot {
  version, focused_window,
  windows: [ { width, height, maximized, fullscreen,
               selected_tab, tabs: [ Tab ] } ],
}
Tab { title_override?, project tab metadata (whatever window.zig /
      project_tab_bar.zig keep per tab: color, pinned name, etc.),
      tree: { nodes: [ split{layout, ratio, left, right} | leaf{surface} ],
              zoomed?, focused_surface } }
Surface { pty_fd, pid, cols, rows, width_px, height_px,
          title, title_override?, pwd?, vt_dump (bytes),
          font_size_adjusted? }
```

- Walk `gtk.Application.getWindows()` → each window's `adw.TabView`
  pages in order → `Tab.getSplitTree()` → `datastruct/split_tree.zig`
  nodes (index 0 = root; mirror the node array + `zoomed`).
- Per surface, under the renderer_state mutex:
  - `pty.master` fd and `Command.pid` from `termio.Exec.Subprocess`
    (add an accessor; skip surfaces whose child already exited / show the
    "process exited" overlay – drop them or recreate as fresh shells).
  - VT dump via `terminal/formatter.zig`:
    - `TerminalFormatter` with `emit = .vt`, `extra = .all`
      (palette, modes, scrolling region, tabstops, pwd, modifyOtherKeys,
      cursor, style, hyperlink, protection, kitty keyboard, charsets).
    - It only formats the *active* screen. If the alt screen is active
      (nvim, less, htop): emit primary screen with full scrollback first
      (ScreenFormatter on `screens.primary`, content = all incl. history),
      then `CSI ?1049h`, then the alt screen + extras. Otherwise primary
      with scrollback + extras.
    - Kitty keyboard: formatter only emits the current flags, not the
      push stack. Acceptable for v1; note it.
    - Cap the scrollback in the dump (e.g. last 10k lines or N MB per
      surface, configurable) so restart stays fast.
- Write snapshot to `$XDG_RUNTIME_DIR/ghosntty/restore-<pid>-<ts>.json`,
  mode 0600. Pass path via env `GHOSNTTY_RESTORE`.
- Minimise output loss: hold every surface's renderer_state mutex from
  its snapshot until execve (io-reader threads block in processOutput).
  Bytes already in the io-gather buffers but not parsed are lost; that's
  acceptable for v1 (document). Do NOT stop the termio threads normally –
  `Subprocess.stop()` kills the child.

### 3. Exec
- Never run normal teardown (GL/GTK teardown can hang after a reset, and
  Surface deinit kills children).
- For each restored fd: `fcntl(F_SETFD, flags & ~FD_CLOEXEC)`.
- Reset the signal mask (`sigprocmask(SIG_SETMASK, empty)`) and restore
  default dispositions for signals Ghostty/GLib changed (SIGCHLD, SIGPIPE,
  etc.) – both survive execve.
- `execve("/proc/self/exe", original argv, environ + GHOSNTTY_RESTORE +
  restart counter)`. `/proc/self/exe` works even if the package was
  upgraded and the file replaced. Capture original argv at startup
  (`global.args()`).
- If anything before execve fails: log, re-set CLOEXEC, release locks,
  keep running (no restart).

### 4. Restore (new process)
- Very early (before GApplication registration): read `GHOSNTTY_RESTORE`,
  **unsetenv** it and the counter-only-if-manual (so new shells never
  inherit it), parse, delete the file.
- Single instance / D-Bus: the old bus connection closed at exec, but the
  bus daemon may not have released the name yet. When restoring, register
  with `G_APPLICATION_NON_UNIQUE` (or retry until the name is free) so
  the new process does not forward its activation to a dead instance.
- Instead of the default first window, recreate windows → tabs → split
  trees (build the `SplitTree` from the saved node array; add a
  constructor in `datastruct/split_tree.zig` if needed, plus
  `split_tree.zig setTree`), ratios, zoom, selected tab, focus, window
  size/maximized, title overrides and project tab metadata.
- Each GTK `Surface` gets a restore payload (new optional field next to
  `priv.overrides` in `class/surface.zig`, consumed in `initSurface`),
  passed down to core `Surface.init` (`src/Surface.zig`) →
  `termio.Exec.Config.adopt: ?struct { fd, pid }` and
  `termio.Options.replay: ?[]const u8`.
- `termio/Exec.zig Subprocess.start()`: if `adopt`:
  - skip `Pty.open` and fork; validate fd (`isatty`, `fcntl` OK) and pid
    (`kill(pid, 0)` or pidfd_open), set FD_CLOEXEC again;
  - `self.pty = .{ .master = fd, .slave = -1 }` (make sure nothing
    closes slave -1; the success `defer` in start() closes `pty.slave`);
  - `self.process = .{ .fork_exec = Command{ .pid = pid, path/args
    placeholders } }` so close/killpg/waitpid paths keep working.
  - If validation fails: log and fall back to spawning a fresh shell in
    the saved pwd.
- `termio/Termio.zig init`: create the terminal at the saved cols/rows,
  feed `replay` through `terminal.vtStream()` (pure state stream – must
  NOT write responses to the pty), then the normal resize path reflows
  to the real widget size.
- Force apps to repaint: after the first real resize, set winsize to
  rows-1 then back to rows (`TIOCSWINSZ` twice) so the foreground job
  gets SIGWINCH even if the size didn't change (nvim/htop full redraw).
- If focus reporting (mode 1004) is on, the normal focus path will send
  focus-in; verify.

### 5. Edge cases to handle
- Child exited during the gap → pidfd fires immediately → normal
  "process exited" handling.
- Child running `ssh`, `sudo` password prompt (termios timer must work
  with adopted fd), tmux.
- Surfaces in quick terminal, inspector windows, close-confirmation
  dialogs: skip/ignore, don't crash.
- Very large scrollback → cap.
- Restore when the GPU is still dead: new process fails EGL init the same
  way a fresh launch would; loop guard prevents a restart storm.
- Flatpak: not supported (children are host processes); disable.
- Windows/macOS: compile-out; Linux GTK only.

## Testing
- Unit tests: snapshot JSON round-trip; split-tree rebuild from node
  array; replay round-trip (format terminal → replay into a fresh
  terminal → compare screens, modes, cursor, kitty flags, alt screen);
  Exec adopt with an openpty + forked `sleep` child.
- Manual matrix via `restart_in_place` keybind: plain shell with long
  scrollback; nvim (alt screen, mouse, kitty keyboard, bracketed paste)
  in a split; htop; `yes | head -c 1G` heavy output; 2 windows × several
  tabs × nested splits, zoomed split; ssh session; child exiting right
  as you trigger; project tab bar state; repeated restarts (PID must stay
  the same: `echo $PPID` in a shell before/after).
- Real TDR: Windows SDK `dxcap -forcetdr` (admin) while GhosnTTy is
  running on the d3d12 GPU; expect the "GPU reset detected" log line
  followed by a restart, all shells intact.

## Suggested order
1. Exec adopt + replay in core (testable without GTK).
2. Snapshot/restore data model + split-tree rebuild.
3. GTK snapshot + execve + restore, manual keybind.
4. Automatic trigger from `checkGpuReset`, debounce, loop guard, config.
5. Docs (`Config.zig` option docs, keybind docs).
