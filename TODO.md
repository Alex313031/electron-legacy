# TODO

 - Build and test the 32 bit Windows build. Targeting is restored (see
   `patches/other/07-restore-32-bit.patch`) and `gn gen` plus a smoke compile work, but it has
   never been built all the way through, so expect the usual x86 Chromium quirks
 - Restore 32 bit Linux support. [#51816](https://github.com/electron/electron/pull/51816) dropped
   `linux-armv7l` alongside `win32-ia32`; only the Windows half is restored so far
 - Collect a `win-x86` PGO profile. Electron only ever published 64 bit ones, so
   `assets/args/release_x86.gn` sets `chrome_pgo_phase = 0` and 32 bit builds give up the PGO
   speedup. This is the only difference between the x86 and x64 GN args besides `target_cpu`
 - Publish. npm has no subdirectory support for git dependencies, so the package has to sit at the
   root of whatever ref consumers install. Keep the source for a release on a `v<version>-src`
   branch, then `git subtree split --prefix=npm_package`, tag that commit `v<version>`, and attach
   the `dist/v<version>/*.zip` files to its release -- that one tag makes both the install URL in
   the README and the mirror in `install.js` resolve, and the release notes point at the `-src`
   branch for the tree it was actually built from. Re-run `./build.sh --npm` for every release
 - PR the two fixes that aren't legacy-Windows specific:
   - the missing `//chrome/browser/ui/tabs:features` dependency (`patches/other/06`), which breaks
     the final link of Electron 44.2.0 on any host
   - defining `mksnapshot` and `v8_context_snapshot_generator` in the target toolchain (part of
     `patches/other/03`), without which a cross-OS build ships host binaries in `mksnapshot.zip`
 - Linux and macOS builds
 - Split `patches/node/` into its own repo and add it back as a submodule. Watch out that
   `build.sh` would silently skip the node series if the submodule isn't checked out
 - Restore XP/Vista support
 - Restore pre CR23 UI
 - Change default asar app to custom branding
 - Add SIMD args/compiler optimization flags from Thorium, including baseline SSE2 not SSE3 for x86 builds.
 - Add HEVC/AC3 patch from Thorium
 - Add component Widevine load patch (it won't be L1 verified because no signature, but at least for testing it will load like Chromium)
