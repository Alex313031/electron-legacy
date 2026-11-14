# Electron for Legacy Windows

A drop-in replacement for the [`electron`](https://www.npmjs.com/package/electron)
npm package that installs [electron-legacy](https://github.com/Alex313031/electron-legacy)
builds: up-to-date Electron that still runs on Windows 7, 8, and 8.1.

The package is named `electron`, so `require('electron')`, the `electron` binary
and anything that resolves the `electron` package keep working unchanged.

## Usage

In your `package.json`:

```json
{
  "devDependencies": {
    "electron": "git+https://github.com/Alex313031/electron-legacy#v44.10.2"
  }
}
```

The tag selects the Electron version. Then:

```sh
npm install
npx electron .
```

The binary downloads on first use rather than during `npm install`, the same as
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

## What differs from upstream's package

Almost nothing, which is the idea. `index.js` and `cli.js` are upstream's byte
for byte. `install.js` differs by one option (`mirrorOptions`, pointing
`@electron/get` at this project's releases instead of `electron/electron`'s)
and `package.json` adds the name, description and other metadata that upstream
fills in when it publishes.

Checksums are **not** disabled: `checksums.json` carries the SHA-256 of every
published artifact, taken from the `SHASUMS256.txt` the build produces, so
downloads are verified exactly as they are upstream.

## How this package is built

It is generated, not hand-maintained. The sources are upstream Electron's
`npm/` directory as patched by `patches/other/08-npm-package.patch`, and
everything else comes from the build:

```sh
./build.sh x64 --package     # writes checkout/dist/v<version>/
./build.sh --npm             # assembles this directory from it
```

`--npm` copies the patched `index.js`, `cli.js`, `install.js` and
`package.json`, adds Electron's `LICENSE` and this README, then fills in the
files upstream injects at publish time: the `version` in `package.json`,
`checksums.json` from `SHASUMS256.txt`, `electron.d.ts`, and `abi_version` from
`node_module_version` in the Electron GN args. It refuses to run if `dist/`
holds zips for a different version than it is packaging.

The `version` is the part that matters most: `install.js` hands it to
`@electron/get`, which builds the download URL as

```
${mirror}v${version}/electron-v${version}-${platform}-${arch}.zip
```

so it decides which release tag a consumer downloads from. That URL shape is
also exactly the layout of `dist/`, which means uploading `dist/v<version>/*.zip`
as release assets on the matching tag is all that serving them takes.

Running `--npm` after packaging more than one architecture produces one package
that serves them all, since `dist/` accumulates arches and the checksums cover
whatever is there.

The `v<version>` tag that consumers install carries this package at its root,
because npm has no subdirectory support for git dependencies. It is produced
with `git subtree split --prefix=npm_package`, so it is not the source tree;
that lives on the `v<version>-src` branch, which the release notes link to.

## License

MIT, as upstream Electron. See [LICENSE](LICENSE).
