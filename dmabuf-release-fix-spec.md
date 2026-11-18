# GhosnTTy: don't reuse exported DMABUF textures until GTK releases them

Repo: `/home/anton/src/ghostty`, branch `anton/linux-project-tabs-navigation`.
Do not commit/push, no issues/PRs. `zig fmt` changed files. Build like CI
(`contrib/ghosntty/ci/build.sh`); targeted tests with
`zig build test -Dtest-filter=<name>`.

## Problem

Under swagway (WSL2, Mesa d3d12, `D3D12_SHARE_RENDER_TARGETS=1`) terminals
occasionally show a frame with cell backgrounds but no glyphs, mostly while
splitting. It stays until the next redraw.

Cause: write-after-read hazard on the exported frame.

- `src/renderer/opengl/Target.zig`: every `FrameState` (3, `swap_chain_count`)
  owns one `export_texture`. `exportDmabuf()` blits the frame into it and
  exports a fresh DMABUF of the *same* texture each frame.
- `generic.zig SwapChain.releaseFrame()` frees the slot as soon as our own
  GPU work is done (`Frame.complete` → `gl.finish` → `frameCompleted`). Three
  frames later we blit into the same `export_texture` again, regardless of
  whether GTK / sway (graphics offload) / swagway's capture is still reading it.
- On resize `FrameState.resize` → `Target.deinit` deletes the texture while
  it may still be displayed.
- Native Linux hides this through dma-resv implicit sync. D3D12 shared handles
  have no implicit sync. Swagway Mesa patches 0004/0005 only fence
  write→read (producer finished before consumer reads), not read→write.
  WezTerm is safe because the EGL Wayland swapchain only reuses a buffer after
  `wl_buffer.release`; Ghostty has no equivalent.

Fix: give exported textures release semantics — a texture handed to the apprt
is never written or deleted until the apprt says it's done with it.

## Design

### 1. Export pool (new, `src/renderer/opengl/ExportPool.zig`)
Move `export_texture` + `export_framebuffer` out of `Target` into a
per-renderer pool owned by `OpenGL` (render thread only, context current).

```
Slot {
  texture, framebuffer, width, height,
  token: *ReleaseToken,   // null when free
  retired: bool,          // wrong size/config; delete once released
}
ReleaseToken {           // heap, shared with the apprt
  refs: std.atomic.Value(u8),     // 2 while in use: pool + consumer
  released: std.atomic.Value(bool),
  wakeup: ?xev.Async,             // render thread wakeup; null after pool deinit
}
```

- `acquire(width, height) ?*Slot`: first sweep (below), then return a free
  slot of the right size; else reuse a free slot of the wrong size (recreate
  textures); else allocate a new slot up to `max_slots` (e.g. 6). If all are
  busy return null.
- `sweep()`: for every slot whose `token.released` is set: drop the pool's
  ref, mark free; if `retired`, delete GL objects and remove the slot.
- On size/config change: free slots are recreated lazily by `acquire`; busy
  slots get `retired = true`.
- `deinit` (render thread exit / `releaseGpuResources`): delete GL objects
  of all slots, and for busy slots drop the pool ref and clear `wakeup`, so a
  late apprt release just frees the token. Deleting the GL texture while GTK
  still holds the DMABUF is fine: the imported D3D12/dma-buf keeps the memory
  alive; we only must not *write* it.
- `ReleaseToken.release()` (any thread): `released.store(true)`, notify
  `wakeup` if set, decrement `refs`, free on 0. Must be idempotent per owner.

### 2. Present path (`src/renderer/OpenGL.zig present`, `opengl/Target.zig`)
- `Target` keeps only the render `framebuffer`/`texture`.
- `Target.exportDmabuf` takes the destination slot instead of using its own
  export texture: blit framebuffer → `slot.framebuffer`, create EGLImage from
  `slot.texture`, export.
- `present()`: `pool.acquire(w, h)`. If null (consumer holds everything) fall
  back to CPU readback for this frame (`readPixelsAlloc`, `.memory`) and log
  at debug with a rate-limited counter. Do not block the render thread.
- Attach the token to the result: `Dmabuf` gets `release: ?*ReleaseToken`.
  `Dmabuf.deinit()` closes fds AND calls `release`. Every path that drops a
  frame then releases it correctly:
  - `LatestFrame.push` replacing an unconsumed frame (`old.deinit()`),
  - `LatestFrame.deinit`,
  - errors in `render_surface.zig rebuildDmabufTexture` (planes.deinit only
    closes fds today — make sure the token is released on that path too).
- `gl.finish()` in `Frame.complete` stays: guarantees our writes are done
  before the consumer reads (complements Mesa 0004/0005).

### 3. GTK side (`src/apprt/gtk/class/render_surface.zig`)
- `rebuildDmabufTexture`: move the token into the heap `Planes` holder passed
  to `builder.build`; `dmabufDestroy` closes fds and calls
  `token.release()`. GTK calls the destroy notify only after the
  `GdkTexture` is finalized, which with graphics offload happens after sway's
  `wl_buffer.release` — exactly the semantics we need.
- If `builder.build` fails, release immediately.
- `unrealize`/dispose unrefs `priv.texture` → normal destroy path.
- Memory frames are unchanged.

### 4. Swap chain (`src/renderer/generic.zig`)
- No semaphore changes; FrameState still frees after `gl.finish`. Only the
  export texture lifetime moves to the pool.
- Wake on release: render thread `xev.Async` (existing draw/wakeup async is
  fine) so a frame that fell back or was skipped is redrawn promptly once a
  slot frees; avoids a frozen last frame when the pool was exhausted.
- `releaseGpuResources()` / `setVisible(false)`: call `pool.deinit` semantics
  above (hidden window: GTK may hold a texture indefinitely — don't wait).

### 5. Metal / other backends
`ExportedFrame`/`Dmabuf` are OpenGL+GTK only; keep Metal untouched. Make the
token optional so non-GTK apprts compile unchanged.

## Size estimate
~200–300 lines: ExportPool ~120, Target/OpenGL present ~50, Dmabuf + token
~30, render_surface ~30, generic wakeup/teardown ~30, tests ~60.

## Risks
- Leaking tokens/slots if any drop path skips `release` → pool exhaustion →
  permanent CPU fallback. Mitigate: debug log of busy slot count; a test.
- Use-after-free if the apprt releases after renderer teardown → token is
  independently refcounted, pool clears `wakeup` on deinit.
- Extra GPU memory: up to `max_slots` × w×h×4 per surface (~15 MB per slot at
  2560x1440), normally 2–3 slots.
- Upstream divergence in a hot path; but this is generic (not WSL-specific)
  and upstreamable.

## Testing
- Unit tests (no GL): pool state machine with a fake slot backend —
  acquire/release ordering, exhaustion → null, retire-on-resize deletes only
  after release, release after deinit frees token, double-release safe.
- Manual on swagway: several splits with fast output (`yes`, Copilot CLI
  spinner, nvim scrolling), repeatedly create/close/resize splits for a few
  minutes; expect zero textless frames. Compare with the build before.
- Swagway's "textless frame" redraw test (Mesa 0004/0005 measurements) run
  against Ghostty if available.
- Check CPU-fallback debug counter stays ~0 in normal use; GPU memory stable
  after many resizes (no slot leak).
