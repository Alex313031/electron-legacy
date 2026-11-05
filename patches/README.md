# Patches

| Directory   | Applied in                      | Order        |
|-------------|---------------------------------|--------------|
| `chromium/` | `src/`                          | `chromium/series` |
| `electron/` | `src/electron/`                 | `electron/series` |
| `node/`     | `src/third_party/electron_node/` | `node/series` |
| `other/`    | `src/`, after `chromium/`       | `other/series` |

`chromium/`, `electron/` and `node/` are imported from upstream (mostly
reverts of upstream changes that dropped Windows 7/8). `other/` is this repo's
own work: anything that isn't an upstream revert (XP/Vista support,
cross-building, SIMD builds, ...). It is flat and numbered by its own `series`.

Apply them **after** `gclient sync` (which runs Electron's own patches), in the
order listed in each `series` file, e.g.:

```sh
while read -r p; do git -C src apply "$PWD/patches/chromium/$p"; done < patches/chromium/series
```

## Layout

Chromium patches are grouped by the top-level directory they touch most
(`base/`, `sandbox/`, `third_party/angle/`, ...). The `NNNN-` prefix is the
global position in `chromium/series`, so order is visible from the file name
alone. Most of these undo an upstream commit that dropped Windows 7/8 support,
so `series` runs newest commit first.

`electron/`, `node/` and `other/` are flat and only a handful of patches each,
so they use a two-digit `NN-` prefix numbered from 1 within their own `series`
rather than Chromium's four.

`third_party/rust-toolchain/*` patch the Rust toolchain that a gclient
runhook downloads, so a later `gclient sync`/`runhooks` will wipe them. Re-apply after.

Patches are byte-exact (some contain intentional CRLF lines); see
`.gitattributes`. Don't let an editor normalize line endings in them.

## Header

Every patch starts with a plain-text header, which `git apply` ignores:

```
Title: <what it does>
Upstream-Commit: <hash> (<date>) <title of the upstream commit>
Origin: <where this patch was imported from>
```

`Upstream-Commit` hashes belong to whatever repo the patch touches (Chromium,
or a third_party repo such as ANGLE or libvpx). Some patches cover several
commits. `upstream-map.tsv` holds the same provenance as one table.

## Importing a new upstream version

```sh
git -C /path/to/Electron-for-windows-7 checkout main
tools/import_upstream_patches.py /path/to/Electron-for-windows-7/vXX.Y.Z /tmp/new-patches \
    --origin "e3kskoy7wqk/Electron-for-windows-7 vXX.Y.Z"
```

Then diff `/tmp/new-patches` against `patches/` to see what changed. The
import only knows about upstream's files, so when you replace `patches/`, keep
your own additions to `other/` and `other/series`.
