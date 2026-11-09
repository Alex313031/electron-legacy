# TODO

 - Build and test the 32 bit Windows build. Targeting is restored (see
   `patches/other/07-restore-32-bit.patch`) and `gn gen` plus a smoke compile work, but it has
   never been built all the way through, so expect the usual x86 Chromium quirks
 - Restore 32 bit Linux support. [#51816](https://github.com/electron/electron/pull/51816) dropped
   `linux-armv7l` alongside `win32-ia32`; only the Windows half is restored so far
 - Collect a `win-x86` PGO profile. Electron only ever published 64 bit ones, so
   `assets/args/release_x86.gn` sets `chrome_pgo_phase = 0` and 32 bit builds give up the PGO
   speedup. This is the only difference between the x86 and x64 GN args besides `target_cpu`
 - Release 44.10.2. It is built and packaged in `checkout/dist/v44.10.2/`, but only `v44.2.0` is
   tagged, so the install ref in the README still points there. npm has no subdirectory support for
   git dependencies, so the package has to sit at the root of whatever ref consumers install: keep
   the source on `v44.10.2-src`, `git subtree split --prefix=npm_package`, tag that commit
   `v44.10.2`, and attach `dist/v44.10.2/*.zip` to its release. Re-run `./build.sh --npm` first, or
   the checksums describe binaries nobody can download
 - PR the two fixes that aren't legacy-Windows specific:
   - the missing `//chrome/browser/ui/tabs:features` dependency (`patches/other/06`), which breaks
     the final link of Electron 44.2.0 on any host
   - defining `mksnapshot` and `v8_context_snapshot_generator` in the target toolchain (part of
     `patches/other/03`), without which a cross-OS build ships host binaries in `mksnapshot.zip`
 - Linux and macOS builds
 - Host `dist/headers/` as a directory tree (a `gh-pages` branch would do). Release assets are
   flat, so `<disturl>/v<version>/win-x64/node.lib` cannot exist there, and without it
   `npm_config_disturl` can't resolve -- native modules won't build against our Electron. Not
   needed for apps that only consume the zips, but a hard blocker for anything that rebuilds
   native modules, i.e. the VSCodium item below
 - Split `patches/node/` into its own repo and add it back as a submodule. Watch out that
   `build.sh` would silently skip the node series if the submodule isn't checked out
 - Restore XP/Vista support
 - Restore pre CR23 UI eyedrop on menu
 - Fetch the Widevine CDM rather than being handed one. `patches/other/14` loads a CDM from
   `--widevine-cdm-path` and reads its `manifest.json` the way Chrome reads a component-updated
   one, but nothing downloads it: `BrowserProcessImpl::component_updater()` returns nullptr and
   Chromium's installer policy lives in `chrome/browser/component_updater`, which Electron doesn't
   link. Either a small fetcher against the component-update endpoint, or a real
   `ComponentUpdateService`. L1/L2 stays out of reach either way without VMP signing certs
