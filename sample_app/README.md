# sample_app

A sample app for testing and debugging Electron Legacy.

## About

The window fills itself in at load, so a run on an unfamiliar machine is one
double-click and a screenshot. It reports:

 - **Build** — Electron, Chromium, Node, V8, arch and OS release.
 - **Legacy Windows APIs** — the restored
   [`isAeroGlassEnabled`](../patches/other/10-restore-isaeroglassenabled.patch),
   and whether the renderer really came up sandboxed.
 - **GPU / WebGL** — context availability and the *unmasked* renderer string.
   That string is the point: `patches/other/21` falls back to SwiftShader
   silently, so "it renders" does not say whether a machine got real D3D9 or
   software, and this does.
 - **Codecs** — `canPlayType` and `MediaSource.isTypeSupported` for HEVC, AC-3,
   E-AC-3 and MPEG-2 alongside royalty-free controls. See
   [Codecs](../docs/CODECS.md).
 - **Native node module** — loads `bufferutil` in the main process *and calls
   it*, which is what exercises
   [rebuilding native modules](https://www.electronjs.org/docs/latest/tutorial/using-native-node-modules)
   against the headers at `.npmrc`'s `disturl`.
 - **Command line** — the full argv the process was given.

The notification area icon is there for the same reason. Electron's `Tray` is
`Shell_NotifyIcon` underneath, and it is one of the places XP and Vista differ
most from Win10 — which mouse events arrive, whether a balloon appears or is
turned into a toast, how much of a tooltip survives, what happens when the icon
is replaced. Its menu exposes each of those as something to click, and every
handler logs, so a run leaves a record of what the OS actually did:

| Tray menu | What it is probing |
|---|---|
| Test Balloon | A real `Shell_NotifyIcon` balloon on XP/Vista, a toast from Win8 on. The `balloon-show` / `balloon-click` / `balloon-closed` log lines are the shell confirming it, so silence means the request went nowhere |
| Test Long Tooltip | `NOTIFYICONDATA`'s tooltip is 64 characters in the original struct and 128 in the one XP introduced; truncation at 64 says which is in play |
| Swap Icon | `NIM_MODIFY`, which fails visibly if the icon handle was not kept properly |
| Destroy / Create Tray Icon | `NIM_DELETE` then `NIM_ADD`, repeatedly, without restarting. Create is under **Tools** |

Clicking the icon toggles the window, double-click always shows it, and
middle-click logs (Windows only). `options.disableTray` in the config turns the
whole thing off.

**Tools** adds `chrome://gpu`, `chrome://process-internals`,
`chrome://media-internals`, and a DevTools window attached to the *main*
process (`Ctrl+Shift+F12`).

## Running it

```bash
npm install
npm start          # or: npm run dev  (logs to file, remote debugging on 9222)
```

## Native modules need headers published first

`.npmrc` points `disturl` at this fork's headers. `npm install` can only rebuild
`bufferutil` for an Electron version whose headers are actually there, so a
version still being developed needs `./build.sh <arch> --package` and a
`disturl` aimed at the resulting `dist/headers/` — otherwise the native module
row reports a download failure rather than anything about Electron.

Separately, on **XP** a native module has to be *built* for XP: a default modern
MSVC toolchain targets a later Windows, and the resulting `.node` will not load
there no matter how healthy Electron is. A failure in that row on XP alone is
usually the module's build flags, not this fork.
