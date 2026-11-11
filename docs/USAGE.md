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

The binary downloads on first use rather than during `npm install` — the same as
upstream Electron since v44. To fetch it ahead of time, run `npx install-electron`.

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
