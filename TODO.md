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
 - Get the sandbox working on XP and Vista. Both need `--no-sandbox` today. The tree's pre-Win10
   support comes from `patches/electron/01-revert-...-windows-7-8-8-1`, so it is Win7-shaped:
   `sandbox/win/` still has XP and Vista branches in places, but nothing has exercised them since
   Chromium dropped XP after M49. Worth comparing notes with
   [Supermium](https://github.com/win32ss/supermium), which solved the same problem
 - Get the GPU process working on XP and Vista. Both need `--disable-gpu` today, and the two fail
   differently: on XP the `d3dcompiler_47.dll` from the Windows SDK cannot load at all (it imports
   `Fls*` and `InitializeCriticalSectionEx`), which kills ANGLE's D3D9 backend before it compiles
   a shader; on Vista it loads and the GPU process crashes for another reason. The XP half is
   handled by `patches/other/19-angle-d3dcompiler-fallback.patch`, which lets ANGLE fall back to
   the `d3dcompiler_43.dll` from the DirectX redistributable, but that is only the first blocker
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
 - Drop `patches/other/15-delayload-failure-diagnostics.patch` before shipping. It is a debugging
   aid for the XP/Vista port that turns a silent delay-load crash into a modal dialog naming the
   module; keep it while XP work continues
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
 - Restore pre CR23 UI eyedrop on menu
 - Fetch the Widevine CDM rather than being handed one. `patches/other/14` loads a CDM from
   `--widevine-cdm-path` and reads its `manifest.json` the way Chrome reads a component-updated
   one, but nothing downloads it: `BrowserProcessImpl::component_updater()` returns nullptr and
   Chromium's installer policy lives in `chrome/browser/component_updater`, which Electron doesn't
   link. Either a small fetcher against the component-update endpoint, or a real
   `ComponentUpdateService`. L1/L2 stays out of reach either way without VMP signing certs
