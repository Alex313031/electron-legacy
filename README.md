# gh-pages — node headers for Electron for Legacy Windows

**Live at <https://thorium.rocks/electron-legacy/>**

This is an **orphan branch**. It shares no history with `main` or `alex` and
contains no source code — only the static tree GitHub Pages serves. If you are
looking for the build scripts and patches, switch to
[`main`](https://github.com/Alex313031/electron-legacy/tree/main).

## What it is for

Native modules are compiled by `node-gyp`, which needs the Electron headers and
the Windows import libraries for whatever version you are building against. It
fetches them from `npm_config_disturl`, and it expects a **directory tree** —
it asks for paths like `v44.10.2/win-x64/node.lib` underneath that URL.

GitHub release assets are flat, so `<release>/v44.10.2/win-x64/node.lib` cannot
exist there. Hence this branch. It is the only reason it exists.

```sh
npm config set disturl https://thorium.rocks/electron-legacy/headers
```

Use the custom domain rather than `alex313031.github.io`: that host answers,
but with a 301 to **http://**`thorium.rocks`, so `node-gyp` would pull the
headers, the import libraries *and* `SHASUMS256.txt` over an unencrypted hop —
leaving the checksums guarding against corruption but not substitution.

## Layout

Four files per version, which is exactly what `node-gyp` requests:

| Path | Purpose |
|---|---|
| `headers/v<version>/node-v<version>-headers.tar.gz` | headers |
| `headers/v<version>/SHASUMS256.txt` | verifies the other three |
| `headers/v<version>/win-x64/node.lib` | 64-bit import library |
| `headers/v<version>/win-x86/node.lib` | 32-bit import library |

## Things that look wrong but are not

**Directory URLs 404.** `https://thorium.rocks/electron-legacy/headers/v44.10.2/`
returns 404 and that is expected: `.nojekyll` is set and GitHub Pages generates
no directory listings. `node-gyp` only ever requests files, so this costs
nothing. `index.html` links the files individually for humans.

**`.gitignore` is not cruft.** This branch has no `checkout/` or `tools/`, so
those appear as untracked when you switch to it, and a `git clean -fd` while on
`gh-pages` would delete the entire Chromium checkout. Note it only stops
`git clean -fd`; the `-x` flag overrides ignore rules, so `git clean -fdx` still
removes `checkout/`. The real protection is keeping the checkout outside the
repo, which `build.sh` supports via `ROOT_PATH`.

**No `iojs-*`, no `x64/`, no root `node.lib`.** Upstream still publishes those.
`node-gyp` only ever names them for targets whose major version is 1–3 —
`isNamedForLegacyIojs` in `process-release.js` — which was an Electron 3-era
compatibility hack, since Electron 3's version numbers collided with io.js's.
This fork will never be in that range, so they are dead weight: omitting them
takes each version from 9.0 MB to 2.9 MB, which matters because every clone of
this branch carries every version forever.

## Adding a version

`build.sh --package` leaves the full upstream-shaped tree in
`checkout/dist/headers/v<version>/`. Copy across only the four paths above,
then regenerate the manifest **without** `-b`:

```sh
find . -type f ! -name 'SHASUMS256*' | sed 's|^\./||' | sort | xargs sha256sum --
```

The `-b` flag matters: it prefixes names with `*`, and `node-gyp`'s
`downloadShasums()` strips a leading `./` and nothing else. With `*` every key
becomes `*node-v<version>-headers.tar.gz` while it looks up
`node-v<version>-headers.tar.gz`, gets `undefined`, and the build dies with
`local checksum <sha> not match remote undefined`. Upstream's own headers
manifest is likewise plain text, while the release `SHASUMS256.txt` does use
`-b` because `sumchecker` expects it.

Finally, add the version to the table in `index.html`.
