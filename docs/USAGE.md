## Usage

To add it to a project, put it in `devDependencies` in your `package.json`:

```json
{
  "devDependencies": {
    "electron": "git+https://github.com/Alex313031/electron-legacy#v44.10.2"
  }
}
```

 - To override the Electron an existing project already depends on, set the same value under the
`resolutions` and/or `overrides` key instead. 

The tag selects the Electron version. Then:

```sh
npm install
npx electron .
```

The binary downloads during `npm install`, through the package's postinstall
script, as Electron's did through v41. Upstream now waits until first use; this
package does not, so after the install it is there in
`node_modules/electron/dist` to inspect or run.

Set `ELECTRON_SKIP_BINARY_DOWNLOAD=1` to install without downloading. The binary
is then fetched on first use instead, or by `npx install-electron`. The same
fallback covers an install that runs no scripts (`--ignore-scripts`, or a
package manager that blocks dependency scripts by default).

### Pointing somewhere else

The release mirror is built into `install.js`, but `@electron/get` reads env and
npm config ahead of it, so nothing here needs editing to redirect it:

```sh
ELECTRON_MIRROR=https://my.host/electron/ npx install-electron
```

`ELECTRON_OVERRIDE_DIST_PATH` works too, for pointing at a local build instead
of a download. `ELECTRON_INSTALL_PLATFORM` and `ELECTRON_INSTALL_ARCH` (or
`npm_config_platform` / `npm_config_arch`) fetch a build for another platform,
which is what packaging tools set when they cross-package.

## Native modules

A native module is a `.node` file: a DLL that loads into Electron and calls Node's C++ or N-API
functions in it. There are two kinds, and they need different things from this fork.

**Modules that ship prebuilt binaries** need nothing. Most N-API modules do this (`bufferutil` and
anything else installed through `node-gyp-build`, `prebuildify` or `node-pre-gyp`): `npm install`
picks the binary for the platform and compiles nothing, and an N-API binary is the same file for
Node and for every Electron version.

**Modules that are compiled on install** are built by `node-gyp`, which downloads two things for
the Electron version it is building against: the headers, and `node.lib`, the import library the
module links to reach the functions inside `electron.exe`. Those come from a *dist URL*.

### The dist URL

```
https://thorium.rocks/electron-legacy/headers
```

This is the headers site for this fork, the counterpart of upstream's
`https://electronjs.org/headers`. It holds, for each released version:

| Path under the dist URL | What it is |
|---|---|
| `v<version>/node-v<version>-headers.tar.gz` | the headers |
| `v<version>/win-x64/node.lib` | import library for 64-bit builds |
| `v<version>/win-x86/node.lib` | import library for 32-bit builds |
| `v<version>/SHASUMS256.txt` | checksums `node-gyp` verifies the other three against |

[The index page](https://thorium.rocks/electron-legacy/) lists the versions that are there. A
version is added by hand after its release, so one that was tagged very recently may not be up
yet. Use this host name and not `alex313031.github.io`, which redirects over plain HTTP.

It is a separate site, and not the GitHub release, because `node-gyp` asks for a directory tree
and release assets are flat. The files are the `gh-pages` branch of this repository, whose README
covers the layout in more detail and how a version is added.

### Compiling against it

`node-gyp` takes everything from npm configuration, so the settings can go in the project's
`.npmrc`:

```ini
runtime=electron
target=44.11.5
disturl=https://thorium.rocks/electron-legacy/headers
```

or in the environment for one command, which is also how to build for the other architecture:

```sh
npm_config_runtime=electron \
npm_config_target=44.11.5 \
npm_config_arch=ia32 \
npm_config_disturl=https://thorium.rocks/electron-legacy/headers \
npm rebuild
```

`target` is the **Electron** version, the same one as the tag in `package.json`, and not the
version of Node inside it. It is what `node-gyp` puts in the paths above; a Node version there
asks this site for a directory it does not have.

[`@electron/rebuild`](https://github.com/electron/rebuild) takes the same two values as flags:

```sh
npx @electron/rebuild --version 44.11.5 --dist-url https://thorium.rocks/electron-legacy/headers
```

### With electron-builder

electron-builder rebuilds native modules itself, in `install-app-deps` and again when packaging,
and it does not read `disturl` from `.npmrc` when it does. Version 24.13.3 sets
`npm_config_disturl` to `https://electronjs.org/headers` in the environment of that rebuild
(`getGypEnv` in `app-builder-lib/out/util/yarn.js`), and npm lets the environment win over
`.npmrc`. So a module electron-builder compiles is compiled against upstream's headers and
`node.lib` for that version number, not this fork's.

To build against this fork's instead, turn its rebuild off and run one of the commands above
before packaging:

```json
{
  "npmRebuild": false
}
```

Modules with prebuilt binaries are not affected either way.

### Before a version is published

`./build.sh <arch> --package` writes the same tree to `checkout/dist/headers/`. Serve that
directory over HTTP and point `disturl` at it to build modules against a version whose headers
are not on the site yet:

```sh
python3 -m http.server --directory checkout/dist/headers 8000
# then: disturl=http://localhost:8000
```

### On Windows XP and Vista

Electron loading is not enough for a native module to load. The module is its own DLL, built by
whatever compiler built it, and a current MSVC toolset targets a newer Windows by default: the
`.node` file is marked as needing it, or imports functions XP does not have, and
`process.dlopen` fails whatever state Electron is in. That applies to prebuilt binaries as much
as to ones compiled locally. A module that has to run there needs to be built for it, with the
subsystem version lowered and without imports XP lacks;
[winwrap](https://github.com/Alex313031/winwrap) and its `tools/check_imports.py` are what this
fork uses for the same problem.

Installing packages at all on Windows 7 and older needs a Node that runs there, since upstream
Node does not: see [node-legacy](https://github.com/Alex313031/node-legacy).

## Menu colors: `--native-colors`
On Windows, menus, the menu bar and tooltips use the fixed colors Chromium had before Chrome
Refresh 2023: white menus with a grey selection in light mode, dark grey in dark mode. Upstream
Electron tints them with the system accent color instead.

To take the user's Windows theme colors, start the app with `--native-colors`, or set it before
`ready`:

```js
app.commandLine.appendSwitch('native-colors');
```

Menus are then drawn in the system menu colors (`COLOR_MENU`, `COLOR_MENUTEXT`, `COLOR_MENUHILIGHT`
and so on) and tooltips in the system tooltip colors. It only applies in light mode; a dark app
keeps Chromium's dark menu.
