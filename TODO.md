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
 - Finish XP support. Vista works as of 44.11.1; XP does not launch yet. `third_party/winwrap`
   (`patches/other/15`) supplies 11 of the missing kernel32/shell32 functions, and 29 static
   kernel32 imports remain. They are static, so all 29 have to exist before anything runs --
   there is no partial progress to observe. `tools/check_win_imports.py --system-dlls <xp dlls>
   out/XP-x86/electron.exe` lists them; grouped, they are condition variables (5), `Fls*` (4),
   file information (4), fibers/misc (9), locale and string (2), named pipe process IDs (2),
   `CancelIoEx`/`CancelSynchronousIo` (2), and `InitializeCriticalSectionEx` (1).
   [YY-Thunks](https://github.com/Chuyu-Team/YY-Thunks) (MIT) implements 27 of the 29 and is worth
   adapting rather than reimplementing; only `NeedCurrentDirectoryForExePathW` and
   `RegisterApplicationRestart` are absent there, and both are a few lines. Doing so makes
   `third_party/winwrap` mixed BSD+MIT, so its `LICENSE` and `README.chromium` need the attribution
 - Decide whether winwrap should dispatch at runtime instead of replacing statically. YY-Thunks
   resolves the real export with a cached `GetProcAddress` and falls back to its own
   implementation, so one binary runs XP through Win11 and uses the real kernel32 where it exists.
   That would also remove the need for a separate `--xp` build: today the Vista shell32 fix only
   ships when `use_winwrap` is on. The catch is that per-function dispatch would bind Vista's
   `AcquireSRWLock*` to the real kernel32 while `TryAcquireSRWLock*` falls back to ours -- the
   mixed state `redirects.cc` warns about. The SRWLOCK family would have to resolve as a group
 - Drop `patches/other/16-delayload-failure-diagnostics.patch` before shipping. It is a debugging
   aid for the XP/Vista port that turns a silent delay-load crash into a modal dialog naming the
   module; keep it while XP work continues
 - Chase the GPU process crash on Vista. It recovers -- the console shows "Reinitialized the GPU
   process after a crash" -- but the D3D9 path is not clean yet
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
