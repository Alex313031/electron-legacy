# Documentation

Docs for [Electron for Legacy Windows](../README.md) — builds of current
Electron that still run on Windows 7/8/8.1, with codec and UI additions
upstream does not ship.

| Doc | What it covers |
|---|---|
| [USAGE.md](./USAGE.md) | Installing the `electron` package in a project, redirecting downloads with `ELECTRON_MIRROR`, and cross-packaging for another platform |
| [BUILDING.md](./BUILDING.md) | Prerequisites, `./build.sh` invocations, packaging, and cross-building for Windows from Linux |
| [CODECS.md](./CODECS.md) | HEVC, AC-3/E-AC-3 and MPEG-2 software decoding, plus [Widevine](./CODECS.md#widevine) CDM loading and why it is L3 only |
| [ELECTRON_DESIGN.md](./ELECTRON_DESIGN.md) | How Electron itself is put together: the patch system, the GN graph, the JS pipeline, Node integration, the C++↔JS binding layer, IPC, packaging. Written against this tree, not a tutorial |

## Elsewhere

- **[Releases](https://github.com/Alex313031/electron-legacy/releases)** — the
  zips, and the tag the npm package installs from
- **[Node headers](https://thorium.rocks/electron-legacy/)** — served for
  `npm_config_disturl` so native modules can be rebuilt against this fork
- **[TODO.md](../TODO.md)** — what is still missing, including XP/Vista support
  and Linux/macOS builds
- **`patches/`** — every change to Chromium, Node and Electron, one commented
  patch at a time; `patches/other/series` is the order they apply in

## A note on scope

These docs describe *this fork*. For the Electron API itself, use
[upstream's documentation](https://www.electronjs.org/docs/latest) — the API is
unchanged here apart from one restored method
(`systemPreferences.isAeroGlassEnabled()`), so upstream's docs apply as written.
