# Spike: `wl_triangle` — Wayland toplevel + Vulkan triangle, pure Odin

Feasibility spike for the Linux platform plan.

**Result: works.** A Wayland toplevel opens, a Vulkan 1.3 dynamic-rendering
pipeline draws a coloured triangle, frames are paced by `wl_surface.frame`,
resize (via `--maximize`) recreates the swapchain, `xdg_toplevel.close` exits
cleanly. No SDL/GLFW, no C compiled in-tree, and the binary links only libc/libm:
`libwayland-client.so.0` and `libvulkan.so.1` are `dlopen`'d with `core:dynlib`.

Verified 2026-09-08 on: Odin `dev-2026-06-nightly:7ab61e4`, the reference compositor compositor
(`the compositor`, wlroots-based; `xdg_wm_base` v3, `wl_compositor` v5), AMD RX
7600 XT / RADV (Mesa 25.0.7, Vulkan 1.4.305), 120 Hz output.

## Commands

```bash
# build + run (args after `run` go to the program — build.sh was patched for this)
./build.sh spike wl_triangle run --seconds 3
./build.sh spike wl_triangle run --frames 10
./build.sh spike wl_triangle run --maximize --seconds 4   # exercises the resize path
./build.sh spike wl_triangle run                          # runs until the window is closed

# equivalent raw invocation
odin build spikes/wl_triangle -collection:baldr=. -out:build/wl_triangle -debug && ./build/wl_triangle --seconds 3

# shaders (committed .spv are loaded with #load; only needed if you edit the GLSL)
cd spikes/wl_triangle/shaders && glslc -O tri.vert -o tri.vert.spv && glslc -O tri.frag -o tri.frag.spv

# proof it is not linked against wayland/vulkan
ldd build/wl_triangle          # libm, libc, ld-linux only

# wire trace (very informative — see "Gotchas")
WAYLAND_DEBUG=1 ./build/wl_triangle --frames 2 2>&1 | less
```

Screenshot: `build/wl_triangle.png` (taken with `grim -o DP-1` 1.6 s into a
3 s run; `build/` is git-ignored). `grim` without `-o` fails on this machine
because the compositor's `zwlr_screencopy` replies `failed` for `HDMI-A-1`.

Typical output of `--seconds 3`:

```
wl_triangle: connected (WAYLAND_DISPLAY=wayland-0, fd 3)
wl_triangle: globals bound: wl_compositor v5 (advertised v5), xdg_wm_base v3 (advertised v3)
wl_triangle: configured 800x600 (serial 670186, states:)
wl_triangle: vulkan instance 1.3, validation layer: not installed
wl_triangle: device: AMD Radeon RX 7600 XT (RADV NAVI33) (Vulkan 1.4.305, driver 25.0.7), queue family 0, core 1.3 dynamic rendering
wl_triangle: swapchain created: 800x600, 4 images, B8G8R8A8_SRGB/SRGB_NONLINEAR, FIFO
wl_triangle: first frame presented
wl_triangle: closing (--seconds 3.0 elapsed): 358 frames in 3.00s (119.3 fps)
```

With `--maximize` the extra lines are:

```
wl_triangle: requested set_maximized (expect configure with a new size)
wl_triangle: configure 800x600 -> 2560x1396 (serial 668400, states: maximized)
wl_triangle: resize -> swapchain 2560x1396 (4 images)
```

Exit code 0 in all three modes. `odin build -vet -strict-style` is clean.

## Files

| File | Lines | What |
|---|---:|---|
| `main.odin` | 343 | CLI, registry/xdg listeners, configure handshake, fd-poll event pump, frame-callback pacing, teardown |
| `wl.odin` | 437 | `core:dynlib` load of libwayland-client, ABI structs (`wl_message`, `wl_interface`, `wl_argument`, `wl_array`), hand-written xdg-shell tables, opcode constants, request helpers |
| `vk.odin` | 694 | libvulkan dlopen → `vendor:vulkan` bootstrap, instance (+validation when present), Wayland surface, device pick, dynamic-rendering pipeline, swapchain (re)creation, per-image command buffers, draw/present |
| `shaders/tri.vert`, `tri.frag` | 11 + 4 | vertex-buffer-less triangle via `gl_VertexIndex`; `.spv` committed and `#load`ed as `[]u32` |

Validation: `VK_LAYER_KHRONOS_validation` is **not installed** on this machine
(only `INTEL_nullhw`, `MESA_overlay` explicit layers), so "zero validation
errors" could not be measured. The code enables the layer + `VK_EXT_debug_utils`
automatically when present, chains the messenger into `VkInstanceCreateInfo`,
prints WARNING/ERROR messages, and exits 3 if any error was reported.

## What worked exactly as planned

- **dlopen of libwayland-client** with `core:dynlib`, including the exported
  *data* symbols `wl_display_interface`, `wl_registry_interface`,
  `wl_callback_interface`, `wl_compositor_interface`, `wl_surface_interface`
  (+ `wl_seat_interface`, `wl_output_interface` needed by xdg-shell's `types`).
- **Hand-written xdg-shell tables** (`wl_interface`/`wl_message`) derived from the
  XML; the compositor accepted every request and delivered every event.
- **Mesa WSI accepts our proxies**: `vkCreateWaylandSurfaceKHR` with the
  `wl_display*`/`wl_surface*` returned by libwayland works; RADV presents through
  `zwp_linux_dmabuf_v1` + `wp_linux_drm_syncobj_manager_v1`.
- **Frame pacing** via `wl_surface.frame`: our frame request is pending state on
  the surface, so WSI's `commit` inside `vkQueuePresentKHR` carries it. The trace
  shows exactly that: `{Default Queue} -> wl_surface#5.frame(#34)` followed by
  `{mesa vk display queue} -> attach / damage / frame(#35) / commit`, then
  `wl_callback#34.done`. 119 fps on a 120 Hz output, zero busy-looping.
- **fd-based loop**: `prepare_read` → `flush` → `poll(fd, timeout)` →
  `read_events` / `cancel_read` → `dispatch_pending`. This is the loop shape
  the backend wants (one `poll` over Wayland + D-Bus + timers); it also matters because
  Mesa reads the same socket (see Gotchas).
- **Configure → ack → first buffer** ordering; resize via a real compositor
  configure (maximize) with swapchain recreation using `oldSwapchain`.
- **Odin `#c_vararg` through a dlsym'd pointer works**: `set_min_size` is
  marshalled with the variadic `wl_proxy_marshal_flags(..., #c_vararg args: ..any)`
  and appears correctly on the wire (`set_min_size(64, 64)`). Everything else
  uses `wl_proxy_marshal_array_flags` with a `[]wl_argument`, which has a fixed
  ABI and is what generated code should use.

## Gotchas found (ABI, signatures, ordering)

1. **`wl_argument` is an 8-byte union**; the marshaller reads the member named
   by the signature letter, so a 32-bit member leaving high bytes dirty is fine.
   For a `n` (new_id) slot pass `{o = nil}`: `wl_proxy_marshal_array_flags`
   overwrites it with the proxy it creates. The wire id is written by
   `wl_closure_marshal`, never by the caller.
2. **`wl_registry.bind` signature is `"usun"`**: args are
   `(name, interface->name, version, nil)` and `interface`/`version` are also
   passed as the 3rd/4th parameters of `wl_proxy_marshal_*_flags`. For every
   other constructor pass the *parent's* version (`wl_proxy_get_version(parent)`)
   — that is what wayland-scanner emits; children inherit the parent's version.
3. **Listener structs are indexed by opcode and libwayland `abort()`s on a nil
   entry** (`wl_closure_invoke`). Every event of the interface *as declared in
   our table* needs a non-nil `proc "c"`, even for events newer than the bound
   version (they will never arrive, but the slot must exist).
4. **Signature strings**: leading digit = `since` version (`"3ou"`, `"4iiii"`),
   `?` = nullable (`"?oii"`, `"n?oo"`), letters `i u f s o n a h`. Event args
   arrive as `i32 / u32 / i32(fixed) / cstring / Proxy / Proxy / ^wl_array / i32(fd)`.
   `xdg_toplevel.configure` is `"iia"`; the array holds `u32` state enums.
5. **`types[]` needs runtime patching** when core interfaces come from dlsym: the
   `^wl_interface` for `wl_surface`/`wl_seat`/`wl_output` is only known after
   `dlopen`, so a generated protocol file must either (a) fill its `types` array
   in an `init` proc, or (b) also generate core tables itself and never dlsym
   them (libwayland compares interfaces **by name** in `wl_interface_equal`, so
   private copies are legal). (b) is cleaner for the scanner.
6. **`wl_callback.done` is a destructor event**: the client must
   `wl_proxy_destroy` the callback in the handler. Destructor *requests*
   (`destroy`) must be marshalled with `WL_MARSHAL_FLAG_DESTROY` so libwayland
   frees the proxy after sending.
7. **Wayland `currentExtent` is `0xFFFFFFFF`** — the client chooses the swapchain
   size from the last `xdg_toplevel.configure`; `0x0` means "you pick". A
   commit with a buffer before the first `configure`/`ack_configure` is a
   protocol error, so `vkCreateSwapchainKHR`/present must wait for it.
8. **Mesa WSI shares our socket and creates its own objects on our
   `wl_display`**: named private queues ("mesa formats query", "mesa image count
   query", "mesa vk display queue"), its own registries, binds of
   `zwp_linux_dmabuf_v1` v4, `wp_presentation`, `wp_linux_drm_syncobj_manager_v1`,
   `wp_tearing_control_manager_v1`, plus `attach/damage/frame/commit` on *our*
   `wl_surface` through a proxy wrapper. Consequences: (i) it reads from the fd,
   so the app **must** use the `prepare_read`/`read_events` protocol rather than
   assuming it owns the socket; (ii) WSI dispatches only its queues, so our
   handlers are never re-entered from inside a `vk*` call — default-queue events
   are queued and surface on our next `dispatch_pending`; (iii) never add our
   own `attach`/`commit` to a surface a swapchain owns.
9. **The implicit `VK_LAYER_MESA_device_select` layer opens *extra* Wayland
   connections** during `vkEnumeratePhysicalDevices` (two full
   `connect → get_registry → roundtrip → disconnect` cycles show up in
   `WAYLAND_DEBUG` as a second "Default Queue" with ids #2/#3). Harmless, but
   confusing in traces and a ~1 ms cost.
10. **Semaphore per swapchain image for present**, fence per frame slot, plus a
    per-image "last fence" so re-recording an image's command buffer waits for
    its previous submission. Reusing one `render_finished` semaphore per slot is
    what newer validation layers flag.
11. **Odin**: `dynamic` is a keyword (variable name clash); a default parameter
    can't be `{}` — use `nil` for slices; `#load(path, []u32)` works and the
    data is 4-byte aligned, so no copy is needed for `pCode`; `switch` as the
    last statement of a proc wanted exhaustiveness even with a `case:` —
    an `if` chain sidestepped it.
12. **No server-side decorations were requested**, so the window is bare
    (see screenshot). The reference compositor *does* advertise `zxdg_decoration_manager_v1`;
    GNOME will not, so the CSD fallback stands.
13. `grim`/`zwlr_screencopy` failed for one of three outputs on this compositor
    — use `grim -o <output>`; `HDMI-A-1` replies `failed`.

Globals advertised by this compositor (useful for the platform plan):
`wl_compositor v5, wl_seat v9, wl_output v4, wl_shm v2, wl_subcompositor v1,
wl_data_device_manager v3, xdg_wm_base v3, zxdg_decoration_manager_v1,
wp_fractional_scale_manager_v1, wp_viewporter, wp_cursor_shape_manager_v1,
zwp_text_input_manager_v3, xdg_activation_v1, wp_presentation v2,
zwlr_layer_shell_v1 v4, ext_session_lock_manager_v1, zxdg_output_manager_v1 v3,
zwp_linux_dmabuf_v1 v4, wp_linux_drm_syncobj_manager_v1, wp_content_type_manager_v1,
wp_single_pixel_buffer_manager_v1, zwp_pointer_constraints_v1,
zwp_relative_pointer_manager_v1, zwp_idle_inhibit_manager_v1, zwp_tablet_manager_v2,
zwlr_screencopy_manager_v1 v3, zwlr_data_control_manager_v1 v2, …` — every protocol
the Linux plan asks for is present, including both needed for the
WSI-less dmabuf path (b).

## What to carry into `platform/wayland` and `gpu`

**platform/wayland**
- Keep the `Wl_Api` proc-pointer struct + `sym()` pattern from `wl.odin`; add
  `wl_display_create_queue`, `wl_proxy_set_queue`, `wl_proxy_create_wrapper`,
  `wl_display_dispatch_queue_pending`, `wl_display_roundtrip_queue` when the
  toolkit gets its own queues (dialog/portal threads, clipboard).
- Have `tools/wl_scanner` emit **the core protocol tables too** (gotcha 5), so
  no `wl_*_interface` data symbols are dlsym'd and `types[]` can be static.
  Emit `[]wl_argument` marshalling via `wl_proxy_marshal_array_flags` (fixed
  ABI); the variadic entry point is not needed.
- Generated listener structs must have every event slot filled; generate a
  default no-op `proc "c"` per event so user code overrides only what it needs.
- Generate the `since` version per request/event and check
  `wl_proxy_get_version` before marshalling (e.g. `wl_surface.damage_buffer` v4,
  `set_buffer_scale` v3) — the compositor's `xdg_wm_base` is only v3, so
  `configure_bounds`/`wm_capabilities` never arrive; code must not rely on them.
- The event loop is exactly `pump()` in `main.odin`, generalised to one `poll`
  set: Wayland fd + D-Bus fd + timerfd + eventfd wake. Always
  `dispatch_pending` before blocking (WSI may have queued events for us).
- Configure handling: coalesce `xdg_toplevel.configure` (size + states) and
  `xdg_surface.configure` (serial); ack in the frame that applies it; treat
  `0x0` as "keep/choose". Surface size in *logical* pixels — buffer size comes
  after `fractional-scale`/`viewporter`, not in this spike.
- Frame pacing: one outstanding `wl_surface.frame` per surface, and cancel it
  (destroy the callback) when the swapchain is recreated before presenting,
  otherwise the pending request never fires and the loop stalls.
- The `Surface` object handed to `gpu` must expose `wl_display*` and
  `wl_surface*` as opaque `rawptr`s; nothing else about libwayland leaks out.

**gpu**
- The bootstrap is `vk_boot` + `vk_create_instance` + `vk_create_device` in
  `vk.odin`: dlopen `libvulkan.so.1`, `vk.load_proc_addresses_global`, instance
  1.3 (1.2 fallback), device features via `PhysicalDeviceVulkan13Features`
  (`VK_KHR_dynamic_rendering` on 1.2 hardware), `load_proc_addresses_instance`
  and `_device`. Reuse verbatim.
- Enable `VK_LAYER_KHRONOS_validation` + debug-utils only when enumerated, and
  count errors so CI can fail on them (this box needs the layer installed:
  Debian package `vulkan-validationlayers`).
- Swapchain policy that worked: FIFO, `caps.minImageCount` (4 on Mesa Wayland —
  do not add +1, it only adds latency), `B8G8R8A8_SRGB`, `COLOR_ATTACHMENT`
  usage, `OPAQUE` composite alpha (switch to `PRE_MULTIPLIED` for translucent
  windows — it is in `supportedCompositeAlpha` on Mesa), `oldSwapchain` handoff
  on resize, `DeviceWaitIdle` before destroying per-image resources.
- Sync: per-image `render_finished` semaphores, per-slot `image_available` +
  fence, per-image last-fence table. Timeline semaphores can replace the fences
  later; not needed for correctness here.
- Dynamic viewport/scissor in the pipeline so resize never rebuilds pipelines.
- The dmabuf/WSI-less path (b) is realistic on this compositor: it has
  `zwp_linux_dmabuf_v1` v4 and `wp_linux_drm_syncobj_manager_v1`, which is what
  Mesa itself uses for presentation here.
