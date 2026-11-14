# How the Electron source works

A medium-to-high level tour of the `electron/electron` repository: how it grafts
itself onto Chromium, how it patches its upstreams, how a build is assembled,
and how the pieces fit together at runtime.

Written against the Electron **44.11.1** tree (Chromium 152.0.7977.169, Node
v24.22.2). Specific line numbers are deliberately avoided; file paths and target
names are given so you can go look. Everything here describes the *Electron*
repo, not Chromium, and not this repo's own build scripts.

---

## Contents

1. [The one-sentence version](#1-the-one-sentence-version)
2. [Repository layout](#2-repository-layout)
3. [How Electron becomes a subdirectory of Chromium](#3-how-electron-becomes-a-subdirectory-of-chromium)
4. [The patch system](#4-the-patch-system)
5. [How the build is wired into Chromium's GN graph](#5-how-the-build-is-wired-into-chromiums-gn-graph)
6. [The JavaScript build pipeline](#6-the-javascript-build-pipeline)
7. [Node.js integration](#7-nodejs-integration)
8. [Process model and startup](#8-process-model-and-startup)
9. [The C++/JavaScript binding layer](#9-the-cjavascript-binding-layer)
10. [The main-process object model](#10-the-main-process-object-model)
11. [Renderer side: preload, context isolation, sandbox](#11-renderer-side-preload-context-isolation-sandbox)
12. [IPC](#12-ipc)
13. [App packaging: ASAR, resources, fuses](#13-app-packaging-asar-resources-fuses)
14. [Docs as a source of truth](#14-docs-as-a-source-of-truth)
15. [Tests](#15-tests)
16. [Release artifacts](#16-release-artifacts)
17. [Mental model summary](#17-mental-model-summary)

---

## 1. The one-sentence version

Electron is a [Chromium](https://www.chromium.org/) embedder: it supplies its own
`ContentMainDelegate`/`ContentBrowserClient`/`ContentRendererClient`
implementations, links [Node.js](https://nodejs.org/) into the same processes,
marries libuv's event loop to Chromium's message loop, and exposes the result
to JavaScript through a set of `gin`-based native bindings plus a TypeScript
layer compiled into the binary.

It is *not* a library sitting on top of Chromium's public API; it lives inside
the Chromium source tree as `src/electron`, participates in Chromium's GN
build, and maintains a few hundred patches against its upstreams.

---

## 2. Repository layout

```text
electron/
├── BUILD.gn              GN targets: electron_lib, electron_app, dist zips, ...
├── DEPS                  pins Chromium/Node/nan/...; declares gclient hooks
├── filenames*.gni        the actual source-file lists, split out of BUILD.gn
├── buildflags/           Electron's own GN args -> buildflags.h
├── build/                build templates and helper scripts (asar, tsc, webpack,
│                         js2c, fuses, paks, zip, symbols)
├── chromium_src/         BUILD.gn that compiles selected //chrome sources
├── patches/              patch sets for Chromium, Node, V8, and 12 others
├── script/               Python/JS tooling (patches, release, lint, spec runner)
├── shell/                the C++ core
│   ├── app/              process entry points + ContentMainDelegate
│   ├── browser/          main process: APIs, windows, net, extensions, ...
│   ├── renderer/         renderer process: clients, preload, context bridge
│   ├── common/           shared: node bindings, gin helpers, asar, converters
│   ├── services/node/    the Node utility-process service
│   └── utility/          utility process client
├── lib/                  TypeScript, per process type
├── default_app/          the app you get when you run `electron` with no app
├── docs/                 API reference (also the source of electron.d.ts)
├── spec/                 the test suite (Mocha/Chai)
├── npm/                  the `electron` npm package (a downloader shim)
└── typings/              internal ambient types
```

Rough proportions in this tree: `shell/` ~7.7 MB of C++, `lib/` ~830 KB of
TypeScript, `docs/` ~15 MB of Markdown, `spec/` ~13 MB of tests, `patches/`
~2.7 MB.

Two useful observations:

- **`filenames.gni` holds the source lists.** `BUILD.gn` references
  `filenames.lib_sources` and friends rather than listing files inline. There
  are also generated/derived lists (`filenames.auto.gni`,
  `filenames.hunspell.gni`, `filenames.libcxx.gni`).
- **`shell/` mirrors Chromium's process separation.** `browser/`, `renderer/`,
  `common/`, `utility/` mean exactly what they mean in Chromium, and the same
  rule applies: `browser/` code must not be linked into a renderer, and
  anything shared goes in `common/`.

---

## 3. How Electron becomes a subdirectory of Chromium

This is the part that surprises people: **Electron's `DEPS` declares Chromium as
a dependency of Electron**, and the resulting checkout has Electron nested
inside Chromium.

### The inversion

A normal Chromium checkout has `.gclient` naming `src` as its solution. An
Electron checkout names `src/electron`:

```python
solutions = [
  {
    "name": "src/electron",
    "url": "https://github.com/electron/electron.git",
    "deps_file": "DEPS",
    "managed": False,
  },
]
```

gclient resolves every DEPS path **relative to the directory containing
`.gclient`**, not relative to the solution. So when `src/electron/DEPS` says:

```python
deps = {
  'src': {
    'url': Var("chromium_git") + '/chromium/src.git@' + Var("chromium_version"),
    'condition': 'checkout_chromium and process_deps',
  },
  'src/third_party/electron_node': {
    'url': Var("nodejs_git") + '/node.git@' + Var("node_version"),
  },
  'src/third_party/nan': { ... },
  'src/third_party/squirrel.mac': { ... },
  'src/third_party/pyyaml': { ... },
}
```

...Chromium lands at `src/`, Node at `src/third_party/electron_node`, and
Electron itself is already at `src/electron`. The final layout:

```text
<root>/
├── .gclient
└── src/                          <- Chromium (its own git repo)
    ├── electron/                 <- this repo (its own git repo)
    ├── third_party/
    │   ├── electron_node/        <- Node.js (its own git repo)
    │   ├── nan/
    │   └── ...all Chromium third_party...
    └── ...all of Chromium...
```

Three directives make this work:

| Directive | Effect |
|---|---|
| `recursedeps = ['src']` | After checking out Chromium, process *its* DEPS too, so all ~580 Chromium dependencies are fetched as normal. |
| `gclient_gn_args_from = 'src'` | Take the GN args gclient derives from DEPS vars from Chromium's DEPS, not Electron's. |
| `vars = { 'chromium_version': ..., 'node_version': ... }` | Electron pins the exact upstream revisions. Bumping Chromium is a one-line change plus however much patch refreshing it demands. |

Because `src/` is a real Chromium checkout, everything Chromium-native works
unchanged: `gn`, `autoninja`, `vpython3`, the `third_party/llvm-build` toolchain,
`vs_toolchain.py`, the sysroots.

A practical consequence: **Electron's DEPS vars can switch off large parts of
the checkout.** `checkout_chromium`, `checkout_node`, `checkout_nan`,
`checkout_pyyaml`, `install_sysroot`, `apply_patches`, `use_mtime_cache`,
`process_deps` are all gclient vars with sensible defaults that in-house
builders are expected to override. Notably `checkout_pgo_profiles` defaults to
**False** here; Electron does not consume Chrome's published PGO profiles,
because they can't describe Electron's code; it uses its own
(`script/pgo/`, `build/pgo_profiles/`).

### The hooks

`DEPS` declares one `pre_deps_hooks` entry and a series of `hooks`. In order:

| Hook | What it does |
|---|---|
| `generate_mtime_cache` (pre-deps) | Records mtimes of every file the patches touch, before the sync disturbs them. |
| `patch_chromium` | Runs `script/apply_all_patches.py patches/config.json`: the whole patch system, see below. |
| `apply_mtime_cache` | Restores those mtimes afterwards. |
| `electron_npm_deps` | `yarn install --immutable` inside `src/electron`. |
| `gen_siso_revision` | Writes `build/siso_revision` to match the Siso commit this Chromium pins. |
| `sysroot_*` | Chromium's Linux sysroots (gated on `install_sysroot`). |
| `electron_pgo_profiles_*` | Downloads Electron's own PGO profiles per platform, plus `v8-builtins`. |

The mtime dance exists purely for build speed: `git am` rewrites every patched
file, so without it, a re-sync would make Ninja consider hundreds of
translation units dirty even when the content is unchanged.
`script/patches-mtime-cache.py` walks the `+++` lines of every patch to find
which files to track and hashes them, so a file whose *content* actually changed
still gets a fresh mtime.

---

## 4. The patch system

Everything outside `src/electron` that Electron needs to modify is modified via
patches. 663 patches across 21 targets in this tree:

| Target | Patches | Repo |
|---|---:|---|
| `chromium` | 402 | `src` |
| `v8` | 66 | `src/v8` |
| `node` | 64 | `src/third_party/electron_node` |
| `angle` | 54 | `src/third_party/angle` |
| `skia` | 14 | `src/third_party/skia` |
| `dawn` | 12 | `src/third_party/dawn` |
| `nan` | 11 | `src/third_party/nan` |
| `pdfium` | 10 | `src/third_party/pdfium` |
| `devtools_frontend` | 8 | `src/third_party/devtools-frontend/src` |
| `ffmpeg` | 4 | `src/third_party/ffmpeg` |
| `fontconfig` | 3 | `src/third_party/fontconfig/src` |
| `boringssl`, `libyuv`, `ReactiveObjC`, `squirrel.mac`, `webrtc` | 2 each | ... |
| `icu`, `libaom`, `libvpx`, `perfetto`, `sqlite` | 1 each | ... |

Do not trust those numbers for long. They are a snapshot of one point release,
and the count climbs steeply within a release line as security fixes are
backported: 44.10.2 -> 44.11.1 added **136 patches** without moving the pinned
Chromium or Node revision at all: `chromium` +70, `v8` +35, `angle` +8. Many
are literally named `cherry-pick-<sha>.patch`. The structure is what is stable
here; the arithmetic is not.

`patches/config.json` is the source of truth for which targets exist and where
each applies, and each directory's `.patches` file for the order within it.
Counting `*.patch` per `patch_dir` reproduces this table; note those paths are
relative to the gclient root, not to `src/electron`.

### Configuration

`patches/config.json` is a flat list of `{patch_dir, repo}` pairs; that's the
entire mapping from a patch directory to the git repo it applies to.

### Ordering: the `.patches` file

Each patch directory contains a `.patches` file listing filenames in apply
order, one per line. Patch files are named for *what they do*
(`build_gn.patch`, `feat_add_support_for_...`), **not numbered**. The docs
explain why: numeric prefixes cause constant conflicts when two PRs each append
a patch, and churn when one is inserted or deleted mid-series.

By convention the filename prefix mirrors the commit-message prefix: `feat_`
(25), `fix_` (42), `build_` (12), `chore_` (16), `refactor_` (6), `revert_` (4).

### Apply: patches become commits

`script/apply_all_patches.py` reads the config and, for each target:

- `script/lib/patches.py` concatenates the patch files in `.patches` order into
  one big mbox stream. As it goes it injects two trailers into each commit
  message (`Patch-Dir:` and `Patch-Filename:`) immediately before the first
  `diff -`/`---` line.
- `script/lib/git.py` saves the current `HEAD` to a ref
  (`refs/patches/upstream-head`) so the export side knows where the patch series
  begins, then pipes the stream to a single `git am --keep-non-patch --keep-cr`.

So **after a sync, each patch is a real git commit** in the target repo, authored
by its original author and committed by "Electron Scripts". That's what makes
the workflow work: you edit the Chromium tree directly, commit, and export.

Details worth knowing:

- Targets are independent git repos, so they're patched **in parallel** via a
  thread pool. On `roller/*` branches it forces a single worker, because
  conflicts are expected there and interleaved output from 15 repos is
  unreadable.
- `ELECTRON_USE_THREE_WAY_MERGE_FOR_PATCHES` in the environment switches `git am`
  to 3-way mode. That's what `e sync --3` sets, and it's the normal mode during
  a Chromium roll.
- `import_patches` upgrades the index to version 4 first, which roughly halves
  index size in a repo the size of Chromium.

### Export: commits become patches

`script/export_all_patches.py` is the inverse. For each target it finds the
patch range (`upstream-head..HEAD`), runs `git format-patch`, splits the result,
**deletes the existing `.patch` files** so removed commits disappear, and
rewrites both the patch files and `.patches`.

A `--dry-run` mode compares what *would* be exported against what's on disk and
exits non-zero on any mismatch; that's the CI check which ensures nobody edits
the Chromium tree without exporting.

### Why patches at all

`docs/development/patches.md` is unusually explicit, and worth reading in full.
It requires every patch to justify its existence as one of exactly three things:

1. Temporary: intended to be upstreamed or removed (link the upstream CL).
2. Needed to compile in the Electron environment and not upstreamable (e.g.
   removing references to Chrome's `Profile`).
3. A deliberate Electron-specific behaviour change incompatible with upstream.

The stated goal is to keep the count minimal and to upstream whenever possible.
That framing explains the shape of the patch set: a lot of small
`#if`-guard-style edits and some genuinely structural reverts.

---

## 5. How the build is wired into Chromium's GN graph

### The entry point

`build/args/all.gn` contains the two lines that connect everything:

```gn
is_electron_build = true
root_extra_deps = [ "//electron" ]
```

`root_extra_deps` is a stock Chromium mechanism: anything listed there gets
pulled into the root build target. So `//electron:electron` becomes part of the
graph and everything follows from its deps.

`is_electron_build` and `is_mas_build` are declared in Chromium's
`build/config/BUILDCONFIG.gn` by `patches/chromium/build_gn.patch`, so they're
visible in every GN file without an explicit import; that's the entire reason
for that patch.

### The target graph

Simplified, the important targets in `BUILD.gn`:

```text
group("electron")
└── executable("electron_app")              the shipped binary
    ├── electron_app_link_deps
    │   └── source_set("electron_lib")      ~all of shell/ plus deps
    │       ├── chromium_src:chrome         selected //chrome sources
    │       ├── chromium_src:chrome_spellchecker
    │       ├── shell/common:mojo           generated mojom bindings
    │       ├── //third_party/electron_node:libnode
    │       ├── //electron/buildflags
    │       ├── :electron_js2c              the JS bundles as C++ arrays
    │       ├── :electron_fuses
    │       ├── :resources / :packed_resources
    │       └── ...a long list of //content, //components, //ui, //net, ...
    └── :packed_resources                   .pak files

group("electron_dist_zip")       the release zip
group("electron_chromedriver_zip")
group("electron_mksnapshot_zip")
group("node_headers")            headers for native modules
group("testing_build") / group("release_build")
```

`electron_lib` is where the bulk lives; `electron_app` is a thin executable with
the platform entry point (`shell/app/electron_main_win.cc`,
`electron_main_linux.cc`, `electron_main_mac.cc`) plus platform resources.

On macOS the picture is more involved: the framework/helper-app bundle
structure means a pile of `bundle_data` targets, `electron_helper_app`
templates, `stripped_framework`, lproj dirs and so on. On Windows and Linux it's
a single executable plus data files.

### `chromium_src/`

Electron depends on parts of `//chrome` that aren't in the content layer and
aren't separately linkable. Rather than patch `//chrome/BUILD.gn`,
`chromium_src/BUILD.gn` declares its own `static_library("chrome")` that lists
individual `//chrome/...` source files and compiles them in Electron's context.
It's visibility-restricted to `//electron:electron_lib`.

This is a notable design choice: it keeps the dependency explicit and reviewable
(you can see exactly which Chrome files Electron uses) and avoids a patch that
would conflict on every Chromium roll.

### Generated-at-build-time bits

Several things in `BUILD.gn` are code generators rather than compilation:

| Target | Produces |
|---|---|
| `electron_js2c` | `electron_natives.cc`, the JS bundles as C++ byte arrays |
| `electron_fuses` | `fuses.h`/`fuses.cc` from `build/fuses/fuses.json5` |
| `generate_config_gypi` | `config.gypi` so native modules see Node's build config |
| `electron_version_args`, `electron_version_header` | version constants |
| `electron_generate_node_defines` | Node's `#define`s re-exported for Electron |
| `generate_node_headers`, `tar_node_headers` | the node-gyp header tarball |
| `electron_win_resource_files`, `electron_win32_resources` | the Windows `.rc` |
| `mksnapshot_checksum_gen` | hash of the V8 context snapshot, for integrity |

### Version determination

`BUILD.gn` prefers the `override_electron_version` GN arg. If it's empty it
falls back to deriving the version from git: `script/get-git-ref-paths.py`
resolves the real locations of `HEAD` and `packed-refs` (so it works in a `git
worktree`, where `.git` is a file), registers them as build inputs, and
`script/get-git-version.py` runs `git describe --tags`. Source tarballs and
no-history checkouts must pass `override_electron_version` explicitly.

---

## 6. The JavaScript build pipeline

Electron's own JavaScript is TypeScript in `lib/`, and it ends up **compiled
into the binary** as C++ string data, not shipped as files.

The pipeline, per process type:

```text
lib/<target>/init.ts  --tsc + webpack-->  <target>.bundle.js  --js2c-->  electron_natives.cc
                                                                              |
                                                              linked into electron_lib
                                                                              |
                                                    loaded at runtime as a builtin module
```

### Per-target bundles

There is one webpack config per process type in `build/webpack/`:

`webpack.config.browser.js`, `renderer.js`, `sandboxed_renderer.js`,
`isolated_renderer.js`, `worker.js`, `utility.js`, `preload_realm.js`,
`node.js`. Each is driven by the shared `webpack.config.base.js`, which takes
flags describing the target environment:

- `alwaysHasNode`: whether Node builtins are available
- `targetDeletesNodeGlobals`: if so, `ProvidePlugin` re-supplies `Buffer`,
  `global`, `process` from an internal shim
- `loadElectronFromAlternateTarget`: which `api/exports/electron.ts` to use
- `wrapInitWithProfilingTimeout`, `wrapInitWithTryCatch`: wrapper behaviour

Two details with real consequences:

- **GN buildflags are injected into the JS.** The base config parses the
  generated `buildflags.h` for `#define BUILDFLAG_INTERNAL_X() (0|1)` and
  defines `X` as a JS boolean, so TypeScript can write
  `BUILDFLAG(ENABLE_PDF_VIEWER)` and have it dead-code-eliminated at bundle
  time, exactly like C++.
- **`@electron/internal/...`** is a webpack alias for `lib/`. Internal modules
  import each other through it, which keeps them unreachable from app code.

Production (`is_official_build`) runs webpack in `production` mode with Terser;
otherwise `development`.

### js2c

`build/js2c.py` drives Node's own `node_js2c` tool over the bundles to produce
`$root_gen_dir/electron_natives.cc`. Because it reuses Node's generator, the
bundles are registered in the same builtin-module table as Node's own internal
JS, so the C++ side can `require()` them by name.

Note `electron_js2c_toolchain`: on a cross build the generator must run on the
host, so it's built in the host toolchain.

There is also an optional V8 code-cache step
(`electron_generate_js2c_code_cache`, `electron_natives_codecache` targets)
which precompiles the bundles so startup skips parsing.

### The `electron` module

`lib/browser/api/module-list.ts` (and the renderer/utility equivalents) is a
plain array of `{ name, loader }` pairs with lazy `require()` thunks:

```ts
export const browserModuleList: ElectronInternal.ModuleEntry[] = [
  { name: 'app', loader: () => require('./app') },
  { name: 'BrowserWindow', loader: () => require('./browser-window') },
  { name: 'ipcMain', loader: () => require('./ipc-main') },
  ...
];
```

`lib/*/api/exports/electron.ts` turns that list into the `electron` module's
exports with lazy getters, so requiring `electron` doesn't instantiate every
API.

---

## 7. Node.js integration

Node lives at `src/third_party/electron_node` and is built as a **library**
(`//third_party/electron_node:libnode`) rather than an executable. That's what
`patches/node/build_add_gn_build_files.patch` is for: Node's own build system is
GYP/`configure`-based, so Electron adds GN build files to it.

Other notable node patch themes, from their filenames:

- `build_allow_unbundling_of_node_js_dependencies`: use Chromium's zlib,
  BoringSSL etc. instead of Node's bundled copies (`node_openssl_path =
  "//third_party/boringssl"` in `build/args/all.gn`).
- `build_modify_js2c_py_to_allow_injection_of_original-fs_and_custom_embedder_js`:
  the hook Electron's own js2c step relies on.
- `electron_enable_node_startup_snapshot_generation_in_chromium_s_v8` and
  `electron_build-time_v8_code_cache_for_the_electron_js2c_bundles`: startup
  performance.
- `chore_allow_the_node_entrypoint_to_be_a_builtin_module`: so Electron's
  bundled `init` can be the entry point.
- A cluster of `api_*` patches tracking V8 API deprecations, which is the
  recurring cost of Node and Chromium pinning *different* V8 expectations while
  sharing one V8.

### The event loop problem

This is the single most interesting piece of engineering in the project.

Node is built around libuv's event loop; Chromium is built around its own
`base::MessagePump`. Both want to own the thread. Electron's answer, in
`shell/common/node_bindings.{h,cc}`:

- A dedicated **embed thread** (`EmbedThreadRunner`) does the blocking wait. It
  loops: wait on a semaphore -> call `PollEvents()` (which blocks in
  `epoll`/`kqueue`/`GetQueuedCompletionStatus`, implemented per platform in
  `node_bindings_linux.cc`, `_mac.cc`, `_win.cc`) -> `WakeupMainThread()`.
- `WakeupMainThread()` posts a task to Chromium's loop, which calls
  `UvRunOnce()` (a single non-blocking `uv_run(UV_RUN_NOWAIT)` on the main
  thread), then signals the semaphore to let the embed thread poll again.

So **all libuv callbacks still run on the main thread**, inside a Chromium task;
the extra thread only ever blocks in the poll syscall. A dummy `uv_async_t` is
kept registered so libuv never considers the loop finished and exits.

There's a documented subtlety on Windows: the IOCP handle doesn't change for the
process lifetime, so `PrepareEmbedThread` is careful to create exactly one
polling thread per process (there's a VS Code issue linked in the comment).

`UvHandle<T>` in the same header is a small RAII wrapper for `uv_handle_t`
subtypes, because libuv requires a handle to stay alive until its `close_cb`
runs.

### Where Node environments are created

`NodeBindings::BrowserEnvironment` is `{ kBrowser, kRenderer, kUtility, kWorker }`:
one `NodeBindings` subclass behaviour per process type. The main-process
sequence, in `ElectronBrowserMainParts::PostEarlyInitialization()`:

1. Optionally install the WebAssembly trap handler (fuse-gated), *before* the
   isolate exists, since V8 latches that decision.
2. Create `JavascriptEnvironment`: the V8 isolate, with Electron's own
   `MicrotasksRunner` rather than V8's default microtask policy.
3. `node_bindings_->Initialize(isolate, context)`.
4. `node_bindings_->CreateEnvironment(...)` -> the `node::Environment`.
5. `electron_bindings_->BindTo(isolate, node_env_->process_object())`: add the
   Electron-specific `process` properties.
6. Set `unhandled_rejections = "warn-with-error-code"`, so an unhandled
   rejection doesn't kill the main process.

A notable wrinkle: when the embedded Node **startup snapshot** is in use, the
V8 context is created inside `node::CreateEnvironment` via
`Context::FromSnapshot` rather than by `JavascriptEnvironment`, so the code
handles an initially-empty context and enters it afterwards.

`shell/browser/javascript_environment.cc` decides whether to use the embedded
snapshot at all: `NodeSnapshotForThisProcess()` returns the embedded snapshot
only in the browser process, `ELECTRON_RUN_AS_NODE` children, and the utility
process hosting the node service, and only if the loaded V8 blob is the one
this build shipped (checked against build-time constants, not by hashing at
startup). If a custom `electron-mksnapshot` blob is loaded, it falls back to
bootstrapping Node from scratch, because the embedded Node snapshot was built on
top of the stock blob and would silently drop the custom one's contents.

---

## 8. Process model and startup

Electron inherits Chromium's multi-process architecture and adds its own
process types.

| Process | Has Node? | Notes |
|---|---|---|
| **browser** (main) | yes, full | Runs the app's `main` script. One per app. |
| **renderer** | optional | Node only if `nodeIntegration` and not sandboxed; preload runs regardless. |
| **utility** | yes, for the node service | `utilityProcess` API; `shell/services/node/`. |
| **GPU / network / ...** | no | Stock Chromium service processes. |
| **crashpad handler** | no | Re-entry into the same binary. |
| **relauncher** | no | Electron-specific, for `app.relaunch()`. |
| **ELECTRON_RUN_AS_NODE** | it *is* node | Plain Node, no Chromium. |

### Entry point dispatch

Taking Windows (`shell/app/electron_main_win.cc`) as the example, `wWinMain`:

1. **32-bit only:** convert the main thread to a fiber with a 4 MiB stack and
   switch to it. Chromium's main thread needs ~1.5 MiB, but setting the
   executable's stack size would inflate *every* thread (including Windows
   thread-pool threads), so the fiber trick gets a big main stack without that
   cost. `electron_app` correspondingly sets a 0.5 MiB initial stack on x86.
2. Initialise `base::CommandLine` and Electron's own saved copy
   (`ElectronCommandLine`).
3. If the `run_as_node` fuse is enabled **and** `ELECTRON_RUN_AS_NODE` is set ->
   `electron::NodeMain()` and nothing Chromium-related happens at all.
4. If `--type=crashpad-handler` -> run as the Crashpad handler, optionally with
   an `ExitCodeWatcher` on the parent.
5. Otherwise -> `content::ContentMain` with `ElectronMainDelegate`.

Linux and macOS have the same shape minus the fiber and Crashpad specifics;
macOS additionally has the helper-app and login-helper entry points.

### `ElectronMainDelegate`

`shell/app/electron_main_delegate.cc` implements Chromium's
`ContentMainDelegate`. The interesting overrides:

| Override | Role |
|---|---|
| `BasicStartupComplete` | Early command-line/logging setup. |
| `PreSandboxStartup` | Load resources and set up crash reporting, before the sandbox closes. |
| `PreBrowserMain` | Last hook before browser main. |
| `PostEarlyInitialization` | Where the browser's `BrowserMainParts` work happens. |
| `CreateContentClient` / `CreateContentGpuClient` | Electron's `ContentClient`, GPU client. |
| `RunProcess` | Intercepts the `relauncher` process type; everything else falls through to content. |
| `ShouldCreateFeatureList` / `ShouldInitializeMojo` | **Only in child processes**: the browser process does these itself, later, because Node must be initialised first. |
| `ShouldLoadV8Snapshot`, `GetBrowserV8SnapshotFilename` | Snapshot selection, including the browser-specific-snapshot fuse. |
| `InitializeMemorySystem` | PartitionAlloc configuration. |

### `ElectronBrowserMainParts`

`shell/browser/electron_browser_main_parts.cc` is Chromium's `BrowserMainParts`
for Electron, and its ordering is where Node and Chromium are interleaved:

```text
PreEarlyInitialization   -> field trials, prefs
PostEarlyInitialization  -> V8 isolate, Node environment, Electron bindings
PreCreateThreads         -> screen/display init, locale
PostCreateThreads        -> ...
PreMainMessageLoopRun    -> create Browser, run the app's main script
WillRunMainMessageLoop   -> hand the run loop to Electron
PostMainMessageLoopRun   -> teardown
PostDestroyThreads       -> final cleanup
```

The app's JavaScript entry point is reached from `PreMainMessageLoopRun`, by
loading the `browser_init` bundle, which then resolves and runs the user's
`main` from `package.json`.

### `lib/browser/init.ts`

The main-process bootstrap, worth skimming because it explains several
observable behaviours:

- `process.argv.splice(1, 1)`: drops the app path so `process.argv` looks like
  a normal Node script's.
- Installs a default `uncaughtException` handler that shows a native error
  dialog, but only if the app hasn't added its own listener.
- Overrides `process.exit` to route through `app.exit`, so Chromium shuts down
  properly.
- On Windows, if an `update.exe` sits next to the binary (the Squirrel layout),
  derives and sets the AppUserModelId automatically.
- Resolves the app: walks `appSearchPaths` (passed from C++ as a hidden value)
  looking for `package.json`, possibly restricted to ASAR archives by the
  `only_load_app_from_asar` fuse, and falls back to `default_app` if nothing is
  found.
- Requires `rpc-server` and `guest-view-manager` to set up internal IPC.

---

## 9. The C++/JavaScript binding layer

### Two mechanisms

**1. Builtin bindings.** C++ modules register themselves with Node's builtin
table via `NODE_LINKED_BINDING_CONTEXT_AWARE(name, Initialize)`; there are 54
of them in this tree, named `electron_browser_*`, `electron_renderer_*`,
`electron_common_*`, `electron_utility_*`. JavaScript reaches them with
`process._linkedBinding('electron_browser_app')`. `NodeBindings::
RegisterBuiltinBindings()` pulls in the set appropriate to the process type.

**2. `gin`/`gin_helper` wrappers.** For object-oriented APIs, C++ classes derive
from `gin::Wrappable` (or Electron's `gin_helper::Wrappable`) and describe their
JS surface declaratively:

```cpp
void BaseWindow::BuildPrototype(v8::Isolate* isolate,
                                v8::Local<v8::FunctionTemplate> prototype) {
  prototype->SetClassName(gin::StringToV8(isolate, "BaseWindow"));
  gin_helper::Destroyable::MakeDestroyable(isolate, prototype);
  gin_helper::ObjectTemplateBuilder(isolate, prototype->PrototypeTemplate())
      .SetMethod("show", &BaseWindow::Show)
      .SetMethod("isVisible", &BaseWindow::IsVisible)
      ...
}
```

`shell/common/gin_helper/` is Electron's extension of Chromium's `gin`:

| Piece | Purpose |
|---|---|
| `object_template_builder` / `function_template` | Bind C++ methods, with automatic argument conversion |
| `dictionary`, `persistent_dictionary` | Ergonomic `v8::Object` access |
| `event_emitter`, `event_emitter_template`, `event` | Make a native object a Node `EventEmitter` |
| `promise` | Return a JS promise from C++ |
| `callback` | Hold and invoke JS functions safely |
| `wrappable`, `handle`, `constructible`, `constructor` | Object lifetime and construction |
| `destroyable` | The `.destroy()` / `isDestroyed()` convention |
| `cleaned_up_at_exit`, `self_keep_alive`, `pinnable` | Shutdown and GC interaction |
| `error_thrower` | Throwing JS exceptions from C++ |
| `trackable_object` | ID-based lookup of native objects across IPC |
| `locker` | `v8::Locker` discipline where Node and Chromium both touch the isolate |

Type conversion is `gin::Converter<T>` specialisations, in
`shell/common/gin_converters/`, a file per type family (`net`, `gfx`,
`file_path`, `value`, `image`, `callback`, ...). That's the layer that lets a
method signature like `void SetBounds(const gfx::Rect&)` be called from JS with
a plain object.

### The usual shape of an API

Most APIs are split between the two layers:

```text
docs/api/browser-window.md       documentation (and the .d.ts source)
lib/browser/api/browser-window.ts  JS-side ergonomics, events, defaults
shell/browser/api/electron_api_base_window.cc   native implementation
shell/browser/native_window_views.cc            platform behaviour
```

`shell/browser/api/` holds 55 native modules (104 files counting headers),
`lib/browser/api/` 44 TypeScript ones.
The TypeScript layer is doing real work: argument massaging, deprecations,
convenience events, and composing native pieces into the documented API.

---

## 10. The main-process object model

Key abstractions in `shell/browser/`:

| Class | Role |
|---|---|
| `Browser` | The app singleton: lifecycle, activation, dock/taskbar. Backs the `app` module. |
| `ElectronBrowserClient` | Electron's `ContentBrowserClient` (~2100 lines). The main place Chromium asks "what should happen here?" and Electron answers. |
| `ElectronBrowserContext` | A `BrowserContext`, i.e. a `session`. Multiple can exist; partitions and in-memory sessions are contexts. |
| `WebContents` (`api/electron_api_web_contents.cc`) | The biggest single file (~5300 lines). Wraps `content::WebContents` and exposes the whole page-level API. |
| `NativeWindow` + `NativeWindowViews` / `NativeWindowMac` | Platform window abstraction behind `BrowserWindow`. `views` on Windows/Linux, Cocoa on macOS. |
| `InspectableWebContents` | Hosts DevTools for a `WebContents`. |
| `ElectronPermissionManager` | Routes permission requests to `session.setPermissionRequestHandler`. |
| `ElectronURLLoaderFactory`, `ProxyingURLLoaderFactory` | Custom protocols and `webRequest` interception, in the network-service world. |

Subsystem directories under `shell/browser/`: `extensions/` (a trimmed
`//extensions` integration), `osr/` (offscreen rendering via a custom
`RenderWidgetHostView` and a video consumer), `notifications/`, `printing/`,
`net/`, `ui/` (menus, tray, views), plus `hid/`, `serial/`, `usb/`,
`bluetooth/`, `webauthn/`, `file_system_access/`, `media/`, `badging/`,
`metrics/`, `tracing/` and per-platform `win/`, `mac/`, `linux/`.

---

## 11. Renderer side: preload, context isolation, sandbox

`shell/renderer/` has several client classes because the renderer's shape
depends on configuration:

| Class | When |
|---|---|
| `RendererClientBase` | Shared base. |
| `ElectronRendererClient` | Unsandboxed renderer with Node integration. |
| `ElectronSandboxedRendererClient` | Sandboxed renderer: no Node, preload only. |
| `WebWorkerObserver` | Node in a Web Worker. |
| `ServiceWorkerData` | Service worker support. |
| `preload_realm_context` | The separate V8 realm for sandboxed preloads. |

### Script context setup

`ElectronRendererClient::DidCreateScriptContext` is where a renderer's Node
environment appears. Roughly:

1. Decide whether this frame should load a preload at all (main frame, or a
   devtools extension, or subframe support explicitly enabled).
2. First time only: `node_bindings_->Initialize` + `SetUpIsolate`. There's a
   detail here worth noting: `SetUpIsolate` installs Node's WebAssembly
   streaming callback, whose JS half never gets installed in a renderer, so
   Blink's is explicitly reinstated with
   `blink::WasmResponseExtensions::Initialize`.
3. `node::InitializeContext(renderer_context)`.
4. **Defer the frame's body load**, run the preload, then undefer, so an async
   or ESM preload isn't racing the document.

### Context isolation and the context bridge

With `contextIsolation` on (the default), the preload runs in a *separate V8
context* from the page. `shell/renderer/api/electron_api_context_bridge.cc` is
the machinery for moving values between those contexts:

- `ExposeAPIInWorld`: the `contextBridge.exposeInMainWorld` implementation.
- `PassValueToOtherContext`: deep-copies primitives/arrays/objects across the
  context boundary.
- `CreateProxyForAPI`: for functions and objects with behaviour, creates a
  proxy in the target context that calls back into the source context.

The point is that no object reference ever crosses: the page gets proxies and
copies, so it can't reach the preload's prototypes or the Node realm.

### Other renderer pieces

`lib/renderer/window-setup.ts` reimplements `window.open`, `window.opener`,
history methods etc. so they route through Electron's window management.
`lib/renderer/security-warnings.ts` produces those console warnings about
`nodeIntegration` and CSP. `lib/renderer/web-view/` implements the `<webview>`
tag, paired with `lib/browser/guest-view-manager.ts` on the other side.

---

## 12. IPC

Electron's IPC is **Mojo** under the hood, not Chromium's legacy IPC.
`shell/common/api/api.mojom` defines the interfaces:

```text
interface ElectronRenderer {            browser -> renderer
  Message(bool internal, string channel, SerializedValue arguments);
  ReceivePostMessage(string channel, TransferableMessage message);
  TakeHeapSnapshot(handle file) => (bool success);
};

interface ElectronApiIPC { ... }        renderer -> browser
interface ElectronFrameStartup {        browser -> renderer, once
  SetStartupData(RendererStartupData data);
};
```

Points of interest:

- **`bool internal`** on `Message` is how Electron separates its own internal
  IPC (`ipcRendererInternal` / `ipcMainInternal`, used by `<webview>`, window
  setup, the guest view manager) from app IPC (`ipcRenderer` / `ipcMain`). Both
  ride the same pipe; the flag keeps app code from seeing internal traffic.
- **`SerializedValue`** carries a `BigBuffer`; arguments are serialised with
  V8's structured-clone, not JSON, which is why `ipcRenderer.send` supports
  `Map`, `Set`, `ArrayBuffer` and so on but not functions.
- **`RendererStartupData`** delivers preload scripts *with their contents and
  code cache* at startup, rather than having the renderer read files itself:
  important for sandboxed renderers, which can't.
- `MessagePortMain` / `postMessage` use Blink's `TransferableMessage`, so real
  `MessagePort` transfer works.

`shell/common/plugin.mojom`, `web_contents_utility.mojom` and
`shell/services/node/public/mojom/node_service.mojom` cover plugins, misc
WebContents utilities, and the utility-process Node service respectively.

JS-side dispatch lives in `lib/browser/ipc-dispatch.ts`,
`lib/browser/ipc-main-impl.ts`, `lib/renderer/ipc-renderer-*.ts`.

---

## 13. App packaging: ASAR, resources, fuses

### ASAR

ASAR is Electron's archive format: a concatenated blob with a JSON header.
`shell/common/asar/` implements reading it, and crucially **integrates it into
Node's `fs`**: `asar_util.cc` plus Node-side patches make
`require('/path/app.asar/index.js')` and `fs.readFileSync` inside an archive
work transparently.

`archive.cc` also supports integrity checking; `integrity_digest.h` and the
`embedded_asar_integrity_validation` fuse let a packaged app verify its archive
against a build-time hash. `scoped_temporary_file.cc` exists because some
platform APIs need a real file path, so files are extracted on demand.

`build/asar.gni` provides an `asar()` GN template (built on a `node_action()`
template) used to produce `default_app.asar`.

### Resources

`build/electron_paks.gni` repacks Chromium's `.pak` resource bundles plus
Electron's own into `resources.pak`, `chrome_100_percent.pak`,
`chrome_200_percent.pak` and the per-locale `locales/*.pak`. These are listed in
`electron_app`'s `data`, so they're part of the output and the zip.

There's an optional resource-allowlist mechanism
(`electron_use_resource_allowlist`, `electron_resource_allowlist_check`) that
tracks which grit resource IDs the linked binary actually references and repacks
only those, with a check target that fails if an unshipped resource is
referenced.

### Fuses

`build/fuses/fuses.json5` lists build-time-flippable, post-build-editable
feature bits:

```json5
{
  "run_as_node": "1",
  "cookie_encryption": "0",
  "node_options": "1",
  "node_cli_inspect": "1",
  "embedded_asar_integrity_validation": "0",
  "only_load_app_from_asar": "0",
  "load_browser_process_specific_v8_snapshot": "0",
  "grant_file_protocol_extra_privileges": "1",
  "wasm_trap_handlers": "1"
}
```

`build/fuses/build.py` generates `fuses.h`/`fuses.cc` containing a
`kFuseWire` byte array prefixed with a sentinel string
(`dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX`). Because the sentinel is findable in the
binary, tooling (`@electron/fuses`) can flip fuses in an *already built*
Electron without rebuilding; that's how app packagers harden a distribution.
C++ reads them as `electron::fuses::IsRunAsNodeEnabled()` etc.

The schema comment is emphatic that fuses must never be removed or redefined,
only marked removed; the wire format is a compatibility surface.

---

## 14. Docs as a source of truth

`docs/api/*.md` (78 files) is not just prose; it's parsed:

```text
docs/api/*.md --electron-docs-parser--> electron-api.json
                                              |
                            electron-typescript-definitions
                                              |
                                        electron.d.ts
```

Driven by the `create-api-json` and `create-typescript-definitions` npm
scripts, with `gn-typescript-definitions` wiring it into the build. So the
published TypeScript types are *generated from the documentation*, which is why
the docs follow such a rigid structural convention and why there's a
`lint:api-history` check validating the API-history YAML blocks against
`docs/api-history.schema.json`.

Practical implication: adding an API means writing the doc, or the types won't
exist. `docs/development/creating-api.md` describes the full checklist.

---

## 15. Tests

`spec/` is the main suite: Mocha + Chai + Sinon, 82 top-level `*-spec.ts`
files plus fixtures and helpers, run by
`script/spec-runner.js` against a built Electron. Tests run *inside* Electron,
so they exercise real windows, real IPC and real sessions.

Adjacent runners exist for the upstreams: `script/node-spec-runner.js` runs
Node's own test suite against Electron's Node (with
`ci_ensure_node_tests_set_electron_run_as_node.patch` making that work), and
`script/nan-spec-runner.js` checks native-module compatibility.

`build/args/native_tests.gn` + `//electron/spec-chromium:spec` cover
Chromium-level native tests.

---

## 16. Release artifacts

The `dist_zip` template in `BUILD.gn` produces the release set:

| Target | Contents |
|---|---|
| `electron_dist_zip` | the app itself: binary, resources, locales, licenses |
| `electron_chromedriver_zip` | ChromeDriver built against this Electron |
| `electron_mksnapshot_zip` | `mksnapshot` + `v8_context_snapshot_generator`, so apps can build custom V8 snapshots |
| `electron_ffmpeg_zip` | a codec-free `ffmpeg` built with `build/args/ffmpeg.gn` |
| `node_headers` / `tar_node_headers` | headers for `node-gyp` native modules |
| `hunspell_dictionaries_zip`, `libcxx_headers_zip`, `libcxxabi_headers_zip`, `electron_xcache_zip` | supporting artifacts |
| `electron_symbols` | breakpad/dSYM symbols for crash analysis |

`script/release/` handles GitHub release creation and asset upload;
`script/zip_manifests/` holds expected zip contents so CI can detect accidental
additions or removals.

What consumers install from npm is just `npm/`, a ~4-file package whose
`install.js` uses `@electron/get` to download the matching
`electron-v<version>-<platform>-<arch>.zip` from the GitHub release and unpack
it. The npm package contains no Electron binary itself.

---

## 17. Mental model summary

If you remember five things:

1. **Electron owns the checkout, Chromium is a dependency of it.** `.gclient`
   points at `src/electron`; `recursedeps` pulls Chromium's own DEPS in behind
   it. That's why Electron ends up *inside* Chromium rather than beside it.

2. **Patches are git commits, not a build step.** `gclient sync` runs
   `apply_all_patches.py`, which `git am`s each patch set onto its target repo
   and records the pre-patch `HEAD` in a ref. You edit the upstream tree
   directly and export; the `.patches` file holds the order.

3. **The build is Chromium's build.** `root_extra_deps = [ "//electron" ]` is
   the whole hook. `electron_lib` is the body, `electron_app` is the executable,
   and Electron's TypeScript is compiled into the binary as C++ byte arrays via
   webpack -> js2c.

4. **Node and Chromium share a thread by cooperating, not by one winning.** A
   dedicated thread blocks in libuv's poll; the main thread runs
   `uv_run(UV_RUN_NOWAIT)` inside a Chromium task when woken. All callbacks,
   both sides, run on the main thread.

5. **Every API exists in three or four places at once**: `docs/api/*.md` (which
   generates the types), `lib/*/api/*.ts` (ergonomics), `shell/*/api/*.cc`
   (implementation), and often a platform file under `shell/browser/`. Changing
   one usually means touching several.

---

## Where to look next

| Question | File |
|---|---|
| Why does this patch exist? | `docs/development/patches.md`, then the patch's own commit message |
| What's in the checkout and why? | `docs/development/source-code-directory-structure.md` |
| How do I add an API? | `docs/development/creating-api.md` |
| What are the build args? | `build/args/*.gn`, `buildflags/buildflags.gni` |
| How does startup work? | `shell/app/electron_main_<platform>.cc` -> `electron_main_delegate.cc` -> `shell/browser/electron_browser_main_parts.cc` |
| How is Node attached? | `shell/common/node_bindings.{h,cc}` |
| What does the JS bootstrap do? | `lib/browser/init.ts`, `lib/renderer/init.ts` |
| How does IPC serialise? | `shell/common/api/api.mojom`, `lib/browser/ipc-dispatch.ts` |
| Build/test commands | `CLAUDE.md`, `package.json` scripts |
