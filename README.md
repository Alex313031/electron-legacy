# <img src="assets/electron-logo.svg" width="38"> Electron for Legacy Windows <img src="assets/compatible-with-windows-7.png" width="38"/>

This is a set of build scripts and patches to produce builds of up-to-date [Electron](https://electronjs.org/) supporting legacy
versions of Windows (Currently 7/8/8.1, XP/Vista support planned), with additional enhancements listed below.

## Synopsis

Existing Electron forks for Windows 7 were incomplete and hard to use, in addition I wanted:

 - Cross-compiling support: upstream Electron doesn't support cross building for Windows from Linux, unlike Chromium. Some small patching allows this.
 - 32 bit support: Electron 43.x [was the last](https://github.com/electron/electron/pull/51816) version with 32 bit support. I restored it.
 - TODO: Restore [pre-Chrome Refresh 2023 UI](https://github.com/Alex313031/thorium/blob/main/docs/TH24.md#screenshots) (which affects Electron's UI too): the current menu UI is ugly for native apps that Electron apps are supposed to be.
 - TODO: Compiler optimizations: Port the compiler optimization flags from [Thorium](https://github.com/Alex313031/thorium).
 - TODO: Support more codecs, such as [HEVC](https://en.wikipedia.org/wiki/High_Efficiency_Video_Coding) and [AC3](https://en.wikipedia.org/wiki/Dolby_Digital#Dolby_AC-3).
 - TODO: Windows XP/Vista support.

## Download
Release artifacts are served at [Releases](https://github.com/Alex313031/electron-legacy/releases).

To add it to a project, put it in `devDependencies`:
`"electron": "git+https://github.com/Alex313031/electron-legacy#v44.2.0"`

To override the Electron an existing project already depends on, set the same value under the
`resolutions` and/or `overrides` key instead.

## Building

### Prerequisites
See https://www.electronjs.org/docs/latest/development/build-instructions-windows#prerequisites

 - [Git](https://git-scm.com/install/windows) (with Git Bash to run the build script on Windows)
 - [Visual Studio 2022](https://aka.ms/vs/17/release/vs_community.exe) or [2026](https://visualstudio.microsoft.com/downloads/), with the 10.0.26100.0 Win SDK installed and [debugging tools installed](https://chromium.googlesource.com/chromium/src/+/main/docs/windows_build_instructions.md#visual-studio).
 - [NASM](https://www.nasm.us/)
 - [NodeJS](https://nodejs.org/en/download) 22.x or higher. One can also build NodeJS (*with Windows 7 support too!*) right here in this repo using [build_node.sh](./patches/node/build_node.sh).

### Compiling
To make a release build and package it:

```bash
./build.sh x64 --package # or x86 for 32 bit build
```

The script automates downloading, patching, and building/packaging Electron, in general automating
the official instructions as per [Here](https://www.electronjs.org/docs/latest/development/build-instructions-gn) for compiling.

That leaves the release zips in `checkout/dist/v<version>/`. To build the `electron` npm package
that the [Download](#download) section installs, run `--npm` afterwards:

```bash
./build.sh --npm
```

It assembles `npm_package/` from the patched `src/electron/npm` sources plus what `--package` left
in `dist/` — the typings, the version, and the checksums of the very zips you are about to upload.
Run it after `--package`, not before, or those checksums describe binaries that no longer exist.

See `./build.sh --help` for all options.

### Cross-building from Linux

Experimental, but it is how the releases are made. A Linux host has no Visual Studio to find, so
it builds against the same packaged toolchain Chromium uses, which you point the build at with two
environment variables:

| Variable | What it is |
|---|---|
| `DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL` | Directory (or `http(s)://`/`gs://` URL) holding the toolchain `<zip hash>.zip` |
| `GYP_MSVS_HASH_<toolchain hash>` | Set to that `<zip hash>`, mapping the toolchain Chromium pins to the zip |

`<toolchain hash>` is the `TOOLCHAIN_HASH` Chromium pins in `build/vs_toolchain.py`, and it changes
whenever Chromium rolls the toolchain. You don't have to go looking for it: run the build and it
prints the exact variable name it wants.

The zip is not something you can download — make it once on a Windows machine that has Visual
Studio and the SDK installed, with depot_tools'
[package_from_installed.py](https://chromium.googlesource.com/chromium/tools/depot_tools/+/main/win_toolchain/package_from_installed.py),
then copy it to the Linux host.

Also needed, beyond the list above (no Visual Studio or NASM):

 - **FUSE** (`fusermount`). The Windows SDK needs a case-insensitive filesystem, which
   `vs_toolchain.py` arranges by mounting `ciopfs` over `win_toolchain/vs_files`.
 - Git, Python 3.11+ and NodeJS 22+. depot_tools ships a suitable Python, and `--deps` fetches
   depot_tools itself.

Everything else is the same; `./build.sh x64 --package` cross-builds a Windows release.

## About
For an overview how Electron works, see [electron-design.md](./assets/electron-design.md).

Legacy Windows support is based on patches from [Electron-for-windows-7](https://github.com/e3kskoy7wqk/Electron-for-windows-7). It is worth noting that
the first person to get Electron back working on Win7 was the [Supermium](https://github.com/win32ss/supermium) (Chromium fork that supports XP+) author's
[fork of Electron](https://github.com/win32ss/supermium-electron). Some NodeJS patches for making Node + Installer standalone came from my
[nodejs-win7 repo](https://github.com/Alex313031/nodejs-win7). HEVC/AC3 software decoding support was added from code from Thorium, however the
original sources for these patches come from [ThaUnknown's Electron](https://github.com/ThaUnknown/electron-chromium-codecs) and
[StaZhu's Chromium/Electron HEVC patches](https://github.com/StaZhu/enable-chromium-hevc-hardware-decoding).

## License

The patches and code in this repo are licensed under the [BSD-3 License](./LICENSE.md).

Electron itself uses the [MIT License](https://github.com/electron/electron/blob/main/LICENSE) and other libraries with their own respective licenses.
