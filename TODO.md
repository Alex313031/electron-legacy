# TODO

 - Restore 32 bit Linux support. [#51816](https://github.com/electron/electron/pull/51816) dropped
   `linux-armv7l` alongside `win32-ia32`; only the Windows half is restored so far
 - Collect a `win-x86` PGO profile. Electron only ever published 64 bit ones, so
   `assets/args/release_x86.gn` sets `chrome_pgo_phase = 0` and 32 bit builds give up the PGO
   speedup. This is the only difference between the x86 and x64 GN args besides `target_cpu`
 - Delete `make_dist.sh`, a throwaway from the 44.10.2 release that pulls the upstream artifacts we
   don't build and merges `SHASUMS256.txt`
 - PR the two fixes that aren't legacy-Windows specific:
   - the missing `//chrome/browser/ui/tabs:features` dependency (`patches/other/06`), which breaks
     the final link of Electron 44.2.0 on any host
   - defining `mksnapshot` and `v8_context_snapshot_generator` in the target toolchain (part of
     `patches/other/03`), without which a cross-OS build ships host binaries in `mksnapshot.zip`
 - Linux and macOS builds
 - Split `patches/node/` into its own repo and add it back as a submodule. Watch out that
   `build.sh` would silently skip the node series if the submodule isn't checked out
 - `wow_helper.exe` is a prebuilt 64-bit binary restored by `patches/chromium/sandbox/0299` and
   now shipped by `patches/other/22`. It is the one file a 32-bit build needs on a 64-bit XP or
   Vista host, and nothing verifies it is present: a packaging change that drops it brings back a
   silent sandbox failure on exactly the platform least likely to be tested. Worth a line in
   `tools/check_win_imports.py`'s caller, or a dist content check
 - Watch for sandbox flakiness elsewhere on XP and Vista. That it works at all was not expected:
   `patches/chromium/sandbox/0202` and `0319` restore the per-version ntdll service-interception
   machinery, and that turns out to be enough. [Supermium](https://github.com/win32ss/supermium)
   disables the utility-process sandbox below Win10 outright, so it may have hit cases this has
   not
 - The XP branch of the GPU sandbox config in `content/browser/gpu/gpu_process_host.cc` (from an
   existing patch in the series) ignores the `[[nodiscard]]` ResultCode from `SetJobLevel` and
   `SetTokenLevel` -- it is the `-Wunused-result` warning in a build. Harmless while the GPU
   works, but it means a sandbox configuration failure on exactly the platform of interest is
   discarded instead of reported
 - Test the D3D9 path on a machine that actually has a Direct3D driver. It has never run: the XP
   guest is VirtualBox, which has not shipped a D3D-capable driver for pre-Vista guests since 5.x,
   so `GetDeviceCaps` answers `D3DERR_NOTAVAILABLE` and ANGLE's D3D9 renderer is rejected before
   it does anything. That says nothing about `patches/other/11-angle-d3d9-port.patch` either way.
   Real XP hardware with a vendor driver, or Guest Additions 4.3.x, would be the first real test.
   `patches/other/19` is needed for it too -- `d3dcompiler_47.dll` from the SDK cannot load on XP,
   so ANGLE has to fall back to the DirectX redistributable's `d3dcompiler_43.dll` -- but that
   blocker only shows up once a device exists to compile shaders for
 - Re-check the Vista GPU process crash. It was last seen before `patches/other/20` and `21`
   landed, so the "Reinitialized the GPU process after a crash" note below may describe a symptom
   that no longer occurs -- D3D9 getting far enough to crash, where it is now either reported
   properly or replaced by SwiftShader. Confirm before spending time on it
 - Find out which GL backend each OS actually ends up on. `patches/other/21` makes the fall back to
   SwiftShader automatic, and it works, but it is silent by design -- so "it renders" does not say
   whether a machine got D3D9 or software. `chrome://gpu` per OS would turn the matrix below from
   "launches" into something meaningful, and would tell us whether the D3D9 port is carrying any
   real load anywhere
 - Remaining non-fatal gaps on XP: 17 delay-loaded `user32`/`advapi32` functions (touch, pointer,
   display config, clipboard listeners, power notifications, `AddConditionalAce`) and a libuv
   `tcp.c` that does not tolerate `SetFileCompletionNotificationModes` failing the way `udp.c`
   does. These fail on first use rather than at load, so they are features missing, not a
   non-starter
 - Decide whether winwrap should dispatch at runtime instead of replacing statically. YY-Thunks
   resolves the real export with a cached `GetProcAddress` and falls back to its own
   implementation, so one binary runs XP through Win11 and uses the real kernel32 where it exists.
   That would also remove the need for a separate `--xp` build: today the Vista shell32 fix only
   ships when `use_winwrap` is on. The catch is that per-function dispatch would bind Vista's
   `AcquireSRWLock*` to the real kernel32 while `TryAcquireSRWLock*` falls back to ours -- the
   mixed state `static_redirects.cc` warns about. The SRWLOCK family would have to resolve as a group
 - Drop `patches/other/15-delayload-failure-diagnostics.patch` before shipping. It turns a silent
   delay-load crash into a modal dialog naming the module; keep it while XP work continues. The
   sandbox diagnostics in `patches/other/22-legacy-sandbox.patch` are worth keeping either way --
   they only replace a DLOG that a release build discards, and a path that logs nothing at all,
   so they cost one ERROR line on a failure that currently produces silence
 - The Vista GPU process recovers after crashing -- the console shows "Reinitialized the GPU
   process after a crash" -- so the D3D9 path is reachable there but not clean. Covered by the
   GPU item above; this is the symptom to look for
 - Add the DLLs Chromium probes with `LoadAllImportsForDll` to `kOptionalModules` in
   `chrome/common/win/delay_load_failure_hook.cc`. `dbghelp.dll` (`base/debug/stack_trace_win.cc`)
   and `oleaut32.dll` (`ui/base/win/scoped_ole_initializer.cc`) are probed exactly like the five
   already listed, but are not allowlisted, so on an OS where they resolve short the hook crashes
   instead of letting the caller handle it
 - Teach `tools/check_win_imports.py` that an unresolvable delay import is fatal too when the
   target DLL is absent from the reference set entirely. It currently reports delay imports as
   non-fatal, which is right for load time and wrong once Chromium's delay-load failure hook is in
   play, and it can only judge DLLs a reference copy was supplied for
 - Tune the menu bar hover highlight if 0.24 opacity is not the pre-Refresh weight.
   `patches/other/04` squares the corners and raises the opacity from Refresh's 0.128,
   which fixes the mismatch against the square menus, but the exact old value was not
   recovered from anywhere -- it was chosen to read as a selection rather than a tint. The
   knobs are `SetHighlightOpacity` and `SetBaseColor` in `submenu_button.cc`
 - Fetch the Widevine CDM rather than being handed one. `patches/other/14` loads a CDM from
   `--widevine-cdm-path` and reads its `manifest.json` the way Chrome reads a component-updated
   one, but nothing downloads it: `BrowserProcessImpl::component_updater()` returns nullptr and
   Chromium's installer policy lives in `chrome/browser/component_updater`, which Electron doesn't
   link. Either a small fetcher against the component-update endpoint, or a real
   `ComponentUpdateService`. L1/L2 stays out of reach either way without VMP signing certs
