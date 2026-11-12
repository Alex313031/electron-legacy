# Building

How to use the scripts in this repo to build Electron Legacy from source.

## Prerequisites
See https://www.electronjs.org/docs/latest/development/build-instructions-windows#prerequisites

 - [Git](https://git-scm.com/install/windows) (with Git Bash to run the build script on Windows)
 - [Visual Studio 2022](https://aka.ms/vs/17/release/vs_community.exe) or [2026](https://visualstudio.microsoft.com/downloads/), with the 10.0.26100.0 Win SDK installed and [debugging tools installed](https://chromium.googlesource.com/chromium/src/+/main/docs/windows_build_instructions.md#visual-studio).
 - [NASM](https://www.nasm.us/)
 - [NodeJS](https://nodejs.org/en/download) 22.x or higher. One can also build NodeJS (*with Windows 7 support too!*) right here in this repo using [build_node.sh](../patches/node/build_node.sh).

## Compiling
To make a release build and package it:

```bash
./build.sh x64 --package # or x86 for 32 bit build
```

The script automates downloading, patching, and building/packaging Electron, in general automating
the official instructions as per [Here](https://www.electronjs.org/docs/latest/development/build-instructions-gn) for compiling.

That leaves the release zips in `checkout/dist/v<version>/`. To build the `electron` npm package
that [Usage](./USAGE.md) installs, run `--npm` afterwards:

```bash
./build.sh --npm
```

It assembles `npm_package/` from the patched `src/electron/npm` sources plus what `--package` left
in `dist/` — the typings, the version, and the checksums of the very zips you are about to upload.
Run it after `--package`, not before, or those checksums describe binaries that no longer exist.

See `./build.sh --help` for all options.

### Windows Vista and XP

A normal release build targets Windows 7 and later. Vista and XP need `--xp`:

```bash
./build.sh x86 --xp          # or x64
```

It builds into its own `out/XP-<arch>`, so switching between an XP and a normal build stays
incremental, and links `third_party/winwrap` to supply Win32 functions the older OS doesn't export.

**Vista and XP** both work as of 44.11.1. Launch with `--no-sandbox --disable-gpu` for now: the
sandbox and the GPU process are the parts still being worked out, and everything else — windows,
rendering, networking, Node — runs. See [TODO.md](../TODO.md).

The `eglCreateContext ES 3.0 failed with error EGL_BAD_ATTRIBUTE` messages logged on Vista are
harmless — D3D9 only goes up to ES 2.0 and the automatic retry succeeds.

On XP, ANGLE's D3D9 backend also needs `d3dcompiler_43.dll` from the
[DirectX End-User Runtime](https://www.microsoft.com/en-us/download/details.aspx?id=35) — the
`d3dcompiler_47.dll` shipped alongside Electron is itself built against Vista APIs and cannot load
there.

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
