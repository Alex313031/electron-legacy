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

## Generating a patch: do not use `git diff` alone

The whole series lives in the checkout as **uncommitted working-tree changes**.
Nothing is ever committed there, so `git diff` in `checkout/src` compares
against pristine upstream, not against "the tree before my change". A patch
generated with

```sh
git -C checkout/src diff ui/gl/gl_features.cc        # WRONG
```

therefore contains every earlier patch's edits to that file as well as yours.

This does not fail loudly. The over-broad patch still applies to a *pristine*
file, so it looks fine, and `apply_series` skips any patch that reverse-applies
cleanly — so an incremental tree, where it is already applied, never retries it.
It breaks the first time somebody applies the whole series in order from
scratch, which may be weeks later and on somebody else's machine. Both
`other/16` and `other/22` were generated this way and broke exactly that way:
16 had swallowed three `chromium/ui/` patches' edits to `gl_features.cc` and was
four hunks where it needed one line; 22 had swallowed
`chromium/sandbox/0202`'s thunk-selection rewrite into a single hunk of
`interception.cc`.

Snapshot the file first, change it, then diff the two:

```sh
cp checkout/src/ui/gl/gl_features.cc /tmp/before.cc
# ...make the change...
diff -u --label a/ui/gl/gl_features.cc --label b/ui/gl/gl_features.cc \
    /tmp/before.cc checkout/src/ui/gl/gl_features.cc
```

Prepend `diff --git a/<path> b/<path>` so `git apply` sees a normal patch.

Picking your hunks out of a `git diff` **is not a substitute**. A hunk is a
region, not a change: one hunk can hold your three lines and another patch's
forty, and keeping it keeps both. That is precisely how `other/22` broke.

For a file inside a nested git repo — `electron/`, `third_party/angle/`,
`third_party/electron_node/` — `git diff` from `checkout/src` does not see it
at all. Either diff from inside that repo with the path rewritten:

```sh
git -C checkout/src/electron diff --src-prefix=a/electron/ --dst-prefix=b/electron/ BUILD.gn
```

or use the snapshot method above, which does not care.

### Checking it

```sh
git -C checkout/src apply --reverse --check <patch>   # matches the tree exactly
```

That proves the patch describes what is there. It does **not** prove the patch
applies in series order — only a build from scratch does, so run one before
trusting a new patch, or at least confirm the patch does not touch a file an
earlier series already touches.

A patch that fails `--reverse --check` on a fully patched tree is not
necessarily broken: where two patches edit the same region, the earlier one can
no longer be reversed once the later one is in. `other/12` and `other/14` are
both in that state and are fine. The symptom to worry about is the opposite —
a patch that will not apply *forward* during a clean build.

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
