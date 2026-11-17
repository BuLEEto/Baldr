# Spike: `win32_triangle` — Win32 window + Vulkan triangle, pure Odin

Windows counterpart of `spikes/wl_triangle`. Same renderer, same shaders,
same swapchain policy; only the window system differs.

**Result: works.** A `RegisterClassExW`/`CreateWindowExW` window with a
per-monitor-v2 DPI context and a dark title bar opens, `vulkan-1.dll` is loaded
at runtime with `core:dynlib`, a Vulkan 1.3 dynamic-rendering pipeline draws the
coloured triangle through `VK_KHR_win32_surface`, a FIFO swapchain paces frames
to the 60 Hz panel (57–59 fps, ~4 % of one core) without a busy loop, maximize /
restore / minimize / a real interactive corner-drag all recreate the swapchain
correctly (including *during* Windows' modal size loop, via `WM_TIMER`), and
`WM_CLOSE` exits cleanly. No SDL/GLFW, no C compiled into the tree; the only
link-time dependencies are the system import libraries `core:sys/windows`
already uses (User32, Gdi32, Dwmapi, Kernel32). `vendor:vulkan` has no foreign
import block, so `vulkan-1.dll` is not linked — it is `LoadLibrary`'d.

Verified 2026-09-08 on: Windows 11 Home 26200.9168, Intel(R) UHD Graphics
(Vulkan 1.4.323, driver `Intel Corporation 101.7082`), 1920×1080 @ 60 Hz,
96 dpi (100 %), Odin `dev-2026-08-nightly:902106f` on the box; cross-checked on
Linux with `dev-2026-06-nightly:7ab61e4` (`-target:windows_amd64`). No Vulkan
SDK and no validation layers exist on the box, so "zero validation errors"
could not be measured (the code enables `VK_LAYER_KHRONOS_validation` when it
is present, exactly like the Wayland spike).

## Commands

Local (Linux) — keeps the tree buildable; every file is `#+build windows`:

```bash
odin check spikes/win32_triangle -collection:baldr=. -target:windows_amd64 -vet -strict-style
tools/win-sync.sh            # tar the repo over ssh into C:\baldr (excludes .git, build)
```

Remote build + run in the SSH session (session 0; see "Session 0" below):

```bash
ssh -o BatchMode=yes win-build 'C:\odin\dist\odin.exe build C:\baldr\spikes\win32_triangle -collection:baldr=C:\baldr -out:C:\baldr\build\win32_triangle.exe -debug'
ssh -o BatchMode=yes win-build 'C:\baldr\build\win32_triangle.exe --seconds 3 --log C:\baldr\build\win32_triangle_s0.log'
```

Remote run on the *interactive desktop* (session 1) with a screenshot — a
scheduled task with `-LogonType Interactive`, driven by
`tools/run_spike.ps1` (all helper scripts live in `spikes/win32_triangle/tools/`
and arrive on the box with `win-sync.sh`; they need nothing but PowerShell 5):

```bash
# plain 4 s run, screenshot 1.8 s in
ssh -o BatchMode=yes win-build 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\baldr\spikes\win32_triangle\tools\run_spike.ps1 -SpikeArgs "--seconds 4" -Shot 1800'
# maximize at frame 60, restore 120 frames later, screenshot while maximized
ssh -o BatchMode=yes win-build 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\baldr\spikes\win32_triangle\tools\run_spike.ps1 -SpikeArgs "--maximize --seconds 5" -Shot 2200'
# minimize at frame 60 (rendering pauses, loop sleeps), timed restore after 2 s
ssh -o BatchMode=yes win-build 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\baldr\spikes\win32_triangle\tools\run_spike.ps1 -SpikeArgs "--minimize --seconds 6" -Shot 0'
# inject a real bottom-right corner drag (+240,+160 px in 16 steps) 1.5 s in: modal size loop
ssh -o BatchMode=yes win-build 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\baldr\spikes\win32_triangle\tools\run_spike.ps1 -SpikeArgs "--seconds 8" -Extra drag_spike.ps1 -ExtraDelay 1500 -Shot 5000'
# a run without --seconds keeps going; close it gracefully (posts WM_CLOSE from session 1)
ssh -o BatchMode=yes win-build 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\baldr\spikes\win32_triangle\tools\run_spike.ps1 -SpikeArgs "" -Extra close_spike.ps1 -ExtraDelay 5000 -Shot 0'
# fetch the screenshot
scp -q -o BatchMode=yes 'win-build:C:/baldr/build/win32_triangle.png' build/win32_triangle.png
```

`run_spike.ps1` registers `BaldrSpike` (+ `BaldrShot`, `BaldrExtra`), starts
them at the requested offsets, polls the log for `closing`, prints the log and
the helper logs, and unregisters every task. `--log <path>` is essential: stdout
of a scheduled task is invisible.

Program CLI: `win32_triangle.exe [--seconds N] [--frames N] [--log <path>]
[--maximize] [--minimize]`. Exit 0 normally, 1 on a setup or repeated present
failure, 2 on bad arguments, 3 if a validation layer reported errors. `Esc`
closes the window.

## Screenshots (in `build/`, git-ignored)

| File | Shows |
|---|---|
| `build/win32_triangle.png` | 800×600 window, dark title bar "Baldr spike", triangle on the pulsing grey clear colour; the spike's own console behind it |
| `build/win32_triangle_max.png` | the same window maximized (`WM_SIZE 1920x1009`), taken 2.2 s into `--maximize` |
| `build/win32_triangle_drag.png` | the window at 1040×760 after the injected corner drag, triangle re-rendered from within the modal loop |

All three were captured from the interactive session with `tools/shot.ps1`
(`System.Drawing` `CopyFromScreen`) and copied back with `scp`.

## Typical output

A run in the interactive session with no `--seconds`, ended 3¼ minutes later
by a `WM_CLOSE` posted from another process (the file log; stdout is identical):

```
win32_triangle +0.001s: start: ["C:\\baldr\\build\\win32_triangle.exe", "--log", "C:\\baldr\\build\\win32_triangle.log"]
win32_triangle +0.002s: dpi awareness: per-monitor v2
win32_triangle +0.008s: dark title bar: DWMWA_USE_IMMERSIVE_DARK_MODE ok
win32_triangle +0.047s: window created: client 800x600 px (logical 800x600), dpi 96 (100%), hwnd 0x704EC
win32_triangle +0.127s: vulkan instance 1.3 (vulkan-1.dll via core:dynlib), validation layer: not installed
win32_triangle +0.127s: win32 surface created (VK_KHR_win32_surface)
win32_triangle +0.145s: device: Intel(R) UHD Graphics (Vulkan 1.4.323, driver 0.405.2986), driver: Intel Corporation 101.7082, queue family 0, core 1.3 dynamic rendering
win32_triangle +0.147s: pipeline created (dynamic rendering, dynamic viewport/scissor)
win32_triangle +0.186s: swapchain created: 800x600, 2 images (minImageCount 2), B8G8R8A8_SRGB/SRGB_NONLINEAR, FIFO
win32_triangle +0.189s: first frame presented (800x600)
win32_triangle +196.784s: closing (WM_CLOSE): 11628 frames in 196.78s (59.1 fps), 0 resize events, 0 swapchain recreations, cpu 8.41s
```

(59.1 fps sustained for 196 s on the 60 Hz panel, 8.4 s of CPU = 4.3 % of a
core. `--seconds 4` runs look the same up to the `closing` line.)

`--maximize --seconds 5`:

```
win32_triangle +1.150s: requested SW_MAXIMIZE (expect WM_SIZE maximized)
win32_triangle +1.169s: WM_SIZE 1920x1009 (maximized)
win32_triangle +1.252s: resize -> swapchain 1920x1009 (2 images)
win32_triangle +3.189s: requested SW_RESTORE (expect WM_SIZE restored)
win32_triangle +3.207s: WM_SIZE 800x600 (restored)
win32_triangle +3.262s: resize -> swapchain 800x600 (2 images)
win32_triangle +5.016s: closing (--seconds 5.0 elapsed): 289 frames in 5.02s (57.6 fps), 2 resize events, 2 swapchain recreations, cpu 0.39s
```

`--minimize --seconds 6` (no frames while minimized; the loop sleeps in
`MsgWaitForMultipleObjectsEx`):

```
win32_triangle +1.144s: requested SW_MINIMIZE (expect WM_SIZE minimized, then an idle wait)
win32_triangle +1.149s: WM_SIZE minimized: rendering paused
win32_triangle +3.197s: requested SW_RESTORE after 2 s minimized (cpu so far 0.23s)
win32_triangle +3.210s: WM_SIZE 800x600 (restored)
win32_triangle +6.012s: closing (--seconds 6.0 elapsed): 227 frames in 6.01s (37.8 fps), 1 resize events, 1 swapchain recreations, cpu 0.45s
```

Injected corner drag (`--seconds 10`, `drag_spike.ps1` at 2 s; 13 of the 16
`WM_SIZE … (dragging)` / `resize -> swapchain` pairs elided):

```
win32_triangle +2.870s: WM_ENTERSIZEMOVE: render timer on (10 ms)
win32_triangle +3.124s: WM_SIZE 815x610 (dragging)
win32_triangle +3.163s: resize -> swapchain 815x610 (2 images)
win32_triangle +3.166s: WM_SIZE 830x620 (dragging)
win32_triangle +3.194s: resize -> swapchain 830x620 (2 images)
…
win32_triangle +4.055s: WM_SIZE 1040x760 (dragging)
win32_triangle +4.088s: resize -> swapchain 1040x760 (2 images)
win32_triangle +4.311s: WM_EXITSIZEMOVE: render timer off, client 1040x760
win32_triangle +10.001s: closing (--seconds 10.0 elapsed): 575 frames in 10.00s (57.5 fps), 16 resize events, 16 swapchain recreations, cpu 0.78s
```

(The repeat run that produced `build/win32_triangle_drag.png` — `--seconds 8`,
drag at 1.5 s — gave 455 frames, 56.8 fps, 16 recreations, 0.62 s CPU.)

Session 0 (`ssh win-build 'win32_triangle.exe --seconds 3 …'`) for comparison:

```
win32_triangle +0.001s: dpi awareness: SetProcessDpiAwarenessContext failed (error 5); current awareness PER_MONITOR_AWARE, per-monitor-v2 already active: false
…
win32_triangle +0.140s: first frame presented (800x600)
win32_triangle +2.001s: closing (--seconds 2.0 elapsed): 21531 frames in 2.00s (10761.0 fps), 0 resize events, 0 swapchain recreations, cpu 3.78s
```

## Files

| File | Lines | What |
|---|---:|---|
| `main.odin` | 263 | CLI, milestone log (stdout + `--log` file, elapsed-time prefix), `render_frame`, limits, idle loop, `--maximize`/`--minimize` drivers, teardown |
| `win.odin` | 220 | DPI context, class + window creation sized to a *logical* 800×600 client, dark title bar, `wnd_proc` (WM_SIZE, WM_DPICHANGED, WM_ENTER/EXITSIZEMOVE, WM_TIMER, WM_PAINT, WM_GETMINMAXINFO, WM_KEYDOWN, WM_CLOSE, WM_DESTROY), `PeekMessage` drain, `MsgWaitForMultipleObjectsEx` wait; local foreign block for three user32 procs `core:sys/windows` lacks |
| `vk.odin` | 712 | `spikes/wl_triangle/vk.odin` with: `vulkan-1.dll` instead of `libvulkan.so.1`, `vk_create_win32_surface` instead of the Wayland one, `VK_KHR_win32_surface`, `fmt.eprint*` → `log_err*` so failures reach the log file, `driver_info` from `VkPhysicalDeviceDriverProperties`, `min_image_count` recorded, one comment on `currentExtent`. Everything else — instance/device bootstrap, pipeline, swapchain lifecycle, per-image semaphores / per-slot fences / image-fence table, `minImageCount` as-is — is byte-identical |
| `shaders/tri.vert(.spv)`, `tri.frag(.spv)` | 11 + 4 | copied from the Wayland spike; `.spv` `#load`ed as `[]u32` (no glslc on the box) |
| `tools/run_spike.ps1` | 60 | scheduled-task harness for the interactive session (see Commands) |
| `tools/shot.ps1`, `drag_spike.ps1`, `close_spike.ps1` | 10 + 30 + 12 | screenshot, injected corner drag (`SetCursorPos` + `mouse_event`), graceful close (`PostMessage WM_CLOSE`) |

## What worked exactly as planned

- **`core:dynlib` + `vendor:vulkan` on Windows**: `load_library("vulkan-1.dll")`,
  `symbol_address(… "vkGetInstanceProcAddr")`, `vk.load_proc_addresses_global`
  — identical to Linux. `vk.HINSTANCE`/`vk.HWND` alias the `core:sys/windows`
  types when `ODIN_OS == .Windows`, so the HWND goes into
  `Win32SurfaceCreateInfoKHR` with no cast.
- **The renderer transferred unchanged.** The Wayland spike's swapchain policy
  (FIFO, `caps.minImageCount`, `B8G8R8A8_SRGB`, `oldSwapchain` handoff,
  `DeviceWaitIdle` before destroying per-image resources, dynamic
  viewport/scissor) needed no Windows tweak; the `currentExtent` branch already
  handled the Win32 case (client size, not `0xFFFFFFFF`).
- **FIFO paces without spinning**: the idle loop is *drain queue → draw*, and
  the draw blocks inside `vkAcquireNextImageKHR`/`vkQueuePresentKHR` until the
  next vblank. 57–59 fps on a 60 Hz panel, 4 % CPU over 197 s. When there is
  nothing to draw (minimized) the loop sleeps in
  `MsgWaitForMultipleObjectsEx(0, nil, timeout, QS_ALLINPUT, MWMO_INPUTAVAILABLE)`.
- **Modal size loop**: `WM_ENTERSIZEMOVE` → `SetTimer(hwnd, 1, USER_TIMER_MINIMUM)`;
  `WM_TIMER` → `render_frame` (which recreates the swapchain if `WM_SIZE` came
  in); `WM_EXITSIZEMOVE` → `KillTimer`. During the injected drag Windows
  delivered a `WM_SIZE` every ~65 ms (the drag step) and the timer-driven frame
  followed each within ~35 ms — the window content tracks the frame while
  dragging, which is exactly the thing naive `GetMessage` loops get wrong.
- **DPI**: `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)` succeeds in
  the interactive session; `GetDpiForWindow` = 96; the frame is sized with
  `AdjustWindowRectExForDpi` so the client is exactly 800×600 *logical* px
  (logical pixels everywhere outside `gpu/`).
- **Dark title bar**: `DwmSetWindowAttribute(hwnd, 20 /*DWMWA_USE_IMMERSIVE_DARK_MODE*/, &TRUE, 4)`
  before `ShowWindow` — visible in all three screenshots.
- **Clean exit paths**: `--seconds`, `--frames`, `WM_CLOSE` (posted from
  another process — same path as the title-bar ✕), `Esc`; all `DestroyWindow`
  → `WM_DESTROY` → `PostQuitMessage` → `WM_QUIT` → `vk_shutdown` →
  `UnregisterClassW`, exit 0.
- **Linker**: the default Odin toolchain on the box (radlink / bundled
  lld-link, Windows SDK 10.0.26100 import libs, no MSVC) linked User32, Gdi32,
  Dwmapi and Kernel32 from the `foreign import "system:…lib"` lines in
  `core:sys/windows` and this spike without any flags. `-debug` produces a
  `.pdb`.

## Gotchas

1. **Session 0 lies about presentation.** From the SSH shell (service session,
   no interactive window station) *everything succeeds* — window, surface,
   device, swapchain, `vkQueuePresentKHR` returns `SUCCESS` — but nothing is
   composited or vsynced: 10 761 "fps" and 1.9 CPU-seconds per wall second.
   A green session-0 run therefore proves API plumbing only; frame pacing and
   pixels must be checked in session 1 via a scheduled task with
   `-LogonType Interactive` (`tools/run_spike.ps1`). The console user is
   `(Get-CimInstance Win32_ComputerSystem).UserName`; if that is empty nobody is
   logged on and the visible run is impossible.
2. **DPI awareness is pre-set in session 0.** `SetProcessDpiAwarenessContext`
   fails there with `ERROR_ACCESS_DENIED` (5) and
   `GetThreadDpiAwarenessContext` already reports `PER_MONITOR_AWARE` (v1, not
   v2) before `main` runs; the exe has no manifest (checked with `findstr
   dpiAware`) and the same binary succeeds in session 1. Whatever sets it, the
   backend must treat `ERROR_ACCESS_DENIED` as "already set", query the actual
   context, and carry on.
3. **`core:sys/windows` gaps** (both dev-2026-06 and dev-2026-08):
   `MsgWaitForMultipleObjectsEx`, `GetAwarenessFromDpiAwarenessContext`,
   `AreDpiAwarenessContextsEqual` are missing (`MsgWaitForMultipleObjects`
   without `Ex` exists). A four-line `foreign import user32 "system:User32.lib"`
   block in `win.odin` covers them — same library core already links, so the
   dependency rule is untouched. Candidates for an upstream PR.
4. **Order of window setup matters**: DPI context → `RegisterClassExW` →
   `CreateWindowExW` (hidden, provisional size) → `GetDpiForWindow` →
   `AdjustWindowRectExForDpi` + `SetWindowPos` → `DwmSetWindowAttribute` →
   `ShowWindow`. Doing the dark-mode call after `ShowWindow` can leave the bar
   light until the window is next activated; the DPI cannot be known before
   the window exists (it depends on which monitor it lands on).
5. **`WM_SIZE` is sent synchronously from inside `SetWindowPos`/the modal
   loop**, before the message pump returns. The handler only records size +
   `resize_needed`; the swapchain is recreated on the next `render_frame`.
   Creation-time `WM_SIZE`s (during `CreateWindowExW` and the DPI resize)
   arrive before Vulkan exists — ignore them for statistics and let the first
   `vk_create_swapchain` use `GetClientRect`.
6. **`WM_PAINT` → `ValidateRect(hwnd, nil)`**, never `BeginPaint`-less
   `DefWindowProc`, otherwise USER re-posts `WM_PAINT` forever and the idle
   loop never idles. The class has `CS_HREDRAW|CS_VREDRAW` and a dark class
   brush so the pre-first-frame window is not white; a real backend should
   drop `CS_H/VREDRAW` and answer `WM_ERASEBKGND` with 1 once Vulkan is
   presenting, to avoid the one-frame flash on newly exposed area during a
   drag.
7. **Swapchain differences vs Mesa/Wayland**: `minImageCount` is **2** here
   (4 on Mesa Wayland); `currentExtent` equals the client rect and is **0×0
   while minimized** — never create a swapchain then (the spike pauses on
   `SIZE_MINIMIZED` and sleeps on the message queue). `maxImageCount` is
   non-zero. `B8G8R8A8_SRGB`/`SRGB_NONLINEAR` and `OPAQUE` composite alpha are
   offered; `FIFO` is honoured at exactly the refresh rate.
8. **Intel's `driverVersion` is not `MAKE_VERSION`-encoded** (decodes to
   `0.405.2986`). Use `VkPhysicalDeviceDriverProperties` (1.2 core) —
   `driverName`/`driverInfo` give `Intel Corporation 101.7082`.
9. **First launch stalled 2 s** between `CreateDevice` and `CreateSwapchainKHR`
   (session 0 only, first run after build; 40 ms every run since). Looks like
   a cold driver shader/pipeline cache; worth remembering when timing startup.
10. **Windows Terminal ignores `-WindowStyle Hidden`.** Helper scripts run via
    a scheduled task popped a terminal over the spike window (it landed on the
    first drag screenshot). `conhost.exe --headless powershell.exe …` fixes it.
    The spike itself is a console-subsystem exe so its own console appears
    behind the window; the toolkit's apps will use `-subsystem:windows`.
11. **PowerShell traps in the harness**: `$Args`/`$args` are automatic variables
    — a `param([string]$Args)` or `function f($args)` silently receives nothing
    (cost one runaway instance, closed via `close_spike.ps1`);
    `FindWindowW` through `Add-Type -MemberDefinition` returned 0 for the
    window while `(Get-Process win32_triangle).MainWindowHandle` finds it;
    cmd.exe's `if not exist X mkdir X && …` binds the whole `&&` chain to the
    `if` body; scheduled-task result `0x41301` = still running.
12. **Odin**: `win.LOWORD/HIWORD` take `#any_int`; `IDC_ARROW` is typed
    `cstring` — pass `win.LPCWSTR(win._IDC_ARROW)` to `LoadCursorW`;
    `GetModuleHandleW` returns `HMODULE` (distinct) — cast to `HINSTANCE`;
    `HRESULT` is a distinct `LONG`, test `>= 0`; `DWMWINDOWATTRIBUTE` is an
    enum but `DwmSetWindowAttribute` takes `DWORD` — cast;
    `core:os` is the os2-style API (`os.open(path, {.Write, .Create, .Append})`
    → `FILE_APPEND_DATA`, unbuffered `WriteFile`, so the log is readable while
    the process runs); a `switch msg { case win.WM_TIMER: if … { return 0 } }`
    falls out to `DefWindowProcW` naturally (no fallthrough).
13. **Not exercised**: `WM_DPICHANGED` (single monitor at 100 %; the handler
    applies the suggested rect and is the documented pattern), multi-monitor,
    `WM_SETTINGCHANGE`/theme changes, validation layers (none installed),
    high-DPI (so the `800*dpi/96` sizing ran with dpi = 96).

## What to carry into `platform/win32` and `gpu`

**platform/win32**
- The event loop is `win_pump_messages` + `win_wait_messages`: drain with
  `PeekMessageW(PM_REMOVE)`, then either present (FIFO blocks → vsync pacing)
  or `MsgWaitForMultipleObjectsEx(handles, timeout, QS_ALLINPUT,
  MWMO_INPUTAVAILABLE)` with the wake event / IOCP / timer handles in the
  array — the "one wait for everything" shape. Never render from a plain
  `GetMessage` loop.
- Keep the `WM_ENTERSIZEMOVE`/`WM_EXITSIZEMOVE` `SetTimer` trick; render from
  `WM_TIMER` and treat `WM_SIZE` as "record + mark dirty", never "recreate
  now". Also handle `WM_SIZE(SIZE_MINIMIZED)` as "surface has no extent".
- Window creation order from gotcha 4; DPI is per window (`GetDpiForWindow`),
  the toolkit's logical→physical scale is `dpi/96`, and `WM_DPICHANGED` must
  apply the suggested rect. Treat `SetProcessDpiAwarenessContext` failure as
  informational (gotcha 2).
- `DwmSetWindowAttribute(DWMWA_USE_IMMERSIVE_DARK_MODE)` before `ShowWindow`;
  ignore `HRESULT` failures (older Windows 10). Backdrop/Mica
  (`DWMWA_SYSTEMBACKDROP_TYPE`) is in `core:sys/windows` too.
- Add the three missing user32 procs to a local `sys` shim (or upstream them).
  Everything else needed came from `core:sys/windows` as-is.
- The `Surface` handed to `gpu` exposes `HINSTANCE` + `HWND` as opaque values;
  nothing else about Win32 leaks out.
- For CI-style verification on this box, reuse `tools/run_spike.ps1`: the
  interactive scheduled task + `--log` file + screenshot is the only way to
  see real presentation; session-0 runs validate plumbing only.

**gpu**
- `vk_boot`/`vk_create_instance`/`vk_pick_physical_device`/`vk_create_device`
  are now proven on two OSes with only the DLL name and the surface extension
  differing — factor exactly those two into the platform layer.
- Keep the swapchain policy (FIFO, `minImageCount` as reported — 2 on Intel
  Windows, 4 on Mesa Wayland — `oldSwapchain` handoff, per-image
  `render_finished` semaphores, per-slot fences, image-fence table). Handle
  `currentExtent == 0x0` by skipping, `0xFFFFFFFF` by choosing.
- Report the device with `VkPhysicalDeviceDriverProperties`, not the packed
  `driverVersion`.
- Route renderer diagnostics through a caller-supplied sink (here `log_err*`),
  not `stderr`: on Windows the interesting runs have no visible console.
