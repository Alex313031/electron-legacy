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
