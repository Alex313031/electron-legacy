#!/usr/bin/env python3
"""Assemble the npm package from patched sources and a packaged dist/ tree.

Called by build.sh --npm; every input is an explicit path so this makes no
assumptions about the layout around it.

The package is upstream Electron's npm/ directory (patched by
patches/other/09-npm-package.patch) plus the files upstream injects at publish
time, which for us come from the build:

    index.js, cli.js, install.js   src/electron/npm/, verbatim
    package.json                   src/electron/npm/, with "version" written in
    LICENSE                        src/electron/
    README.md                      assets/npm/
    electron.d.ts                  dist/v<version>/
    checksums.json                 from dist/v<version>/SHASUMS256.txt
    abi_version                    node_module_version from the Electron GN args

"version" is the one that has to be right: install.js hands it to
@electron/get, which builds the download URL as
    ${mirror}v${version}/electron-v${version}-${platform}-${arch}.zip
so it decides which release tag a consumer pulls from.
"""

import argparse
import json
import os
import re
import shutil
import sys

# package.json keys in the order npm itself writes them, so the generated file
# does not reorder on every run. Anything not listed keeps its relative order
# after these.
KEY_ORDER = [
    'name', 'version', 'description', 'repository', 'license', 'author',
    'keywords', 'main', 'types', 'bin', 'files', 'scripts', 'dependencies',
    'devDependencies', 'engines',
]

SHASUM_RE = re.compile(r'^([0-9a-f]{64}) \*?(.+)$')
# electron-v44.2.0-win32-x64.zip -> (44.2.0, win32-x64)
ARTIFACT_RE = re.compile(r'^electron-v(\d+\.\d+\.\d+[^-]*)-(.+)\.zip$')


def fail(msg):
    sys.exit(f'error: {msg}')


def read_checksums(shasums):
    """Parse SHASUMS256.txt ("<sha256> *<name>") into {name: sha256}."""
    out = {}
    with open(shasums, encoding='utf-8') as f:
        for line in f:
            m = SHASUM_RE.match(line.strip())
            if m:
                out[m.group(2).strip()] = m.group(1)
    if not out:
        fail(f'no checksums parsed out of {shasums}')
    return out


def check_versions(checksums, version):
    """Every electron zip in dist/ must be the version we are packaging.

    A dist/ directory is reused across runs and across arches, so a stale zip
    from an earlier version is easy to leave behind -- and it would be a zip
    whose checksum we publish under this version's name.
    """
    matched, stale = [], []
    for name in checksums:
        m = ARTIFACT_RE.match(name)
        if not m:
            continue
        (matched if m.group(1) == version else stale).append((name, m.group(2)))

    if stale:
        fail('dist/ holds electron zips for another version:\n  '
             + '\n  '.join(n for n, _ in sorted(stale))
             + f'\nexpected {version}. Remove them, or re-run --package.')
    if not matched:
        fail(f'no electron-v{version}-*.zip in dist/. Run --package first.')
    return sorted(p for _, p in matched)


def read_abi(args_gn):
    """node_module_version from Electron's GN args: the package's ABI."""
    with open(args_gn, encoding='utf-8') as f:
        m = re.search(r'^\s*node_module_version\s*=\s*(\d+)\s*$', f.read(),
                      re.MULTILINE)
    if not m:
        fail(f'no node_module_version in {args_gn}')
    return m.group(1)


def write_package_json(src, dest, version):
    with open(src, encoding='utf-8') as f:
        pkg = json.load(f)

    if 'name' not in pkg:
        fail(f'{src} has no "name"; is patches/other/09-npm-package.patch applied?')

    # Upstream leaves version out of npm/package.json because it is injected at
    # publish time. install.js requires it at runtime, so it is not optional.
    pkg['version'] = version

    ordered = {k: pkg[k] for k in KEY_ORDER if k in pkg}
    ordered.update({k: v for k, v in pkg.items() if k not in ordered})

    with open(dest, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(ordered, f, indent=2)
        f.write('\n')

    return pkg.get('files', [])


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--npm-src', required=True, help='src/electron/npm')
    p.add_argument('--license', required=True, help='src/electron/LICENSE')
    p.add_argument('--readme', required=True, help='assets/npm/README.md')
    p.add_argument('--dist', required=True, help='dist/v<version>')
    p.add_argument('--args-gn', required=True,
                   help='src/electron/build/args/all.gn')
    p.add_argument('--out', required=True, help='npm_package/')
    p.add_argument('--version', required=True)
    args = p.parse_args()

    for path in (args.npm_src, args.dist):
        if not os.path.isdir(path):
            fail(f'{path} is not a directory')

    shasums = os.path.join(args.dist, 'SHASUMS256.txt')
    typings = os.path.join(args.dist, 'electron.d.ts')
    for path in (shasums, typings, args.license, args.readme, args.args_gn):
        if not os.path.isfile(path):
            fail(f'{path} does not exist')

    checksums = read_checksums(shasums)
    platforms = check_versions(checksums, args.version)
    abi = read_abi(args.args_gn)

    os.makedirs(args.out, exist_ok=True)

    for name in ('index.js', 'cli.js', 'install.js'):
        shutil.copyfile(os.path.join(args.npm_src, name),
                        os.path.join(args.out, name))

    files = write_package_json(os.path.join(args.npm_src, 'package.json'),
                               os.path.join(args.out, 'package.json'),
                               args.version)

    shutil.copyfile(args.license, os.path.join(args.out, 'LICENSE'))
    shutil.copyfile(args.readme, os.path.join(args.out, 'README.md'))
    shutil.copyfile(typings, os.path.join(args.out, 'electron.d.ts'))

    with open(os.path.join(args.out, 'checksums.json'), 'w',
              encoding='utf-8', newline='\n') as f:
        json.dump(checksums, f, indent=2)
        f.write('\n')

    with open(os.path.join(args.out, 'abi_version'), 'w',
              encoding='utf-8', newline='\n') as f:
        f.write(f'{abi}\n')

    # "files" is what npm packs, including from a git install, so anything
    # listed and missing is a package that installs broken.
    missing = [n for n in files if not os.path.exists(os.path.join(args.out, n))]
    if missing:
        fail('package.json "files" lists entries that were not staged: '
             + ', '.join(missing))

    print(f'  version       {args.version}')
    print(f'  abi_version   {abi}')
    print(f'  checksums     {len(checksums)} artifacts, '
          f'electron for {", ".join(platforms)}')
    print(f'  electron.d.ts {os.path.getsize(typings) // 1024} KiB')
    print(f'  staged        {", ".join(sorted(files))}')


if __name__ == '__main__':
    main()
