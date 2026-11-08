#!/usr/bin/env python3
"""Put the checkout back to stock: drop our patch series, keep Electron's.

Called by build.sh --reset. Entirely local -- no gclient, no network -- so the
series can be replayed from the top in seconds rather than after an hour-long
re-sync.

Why not `gclient revert`: it fetches, and it resets every dependency to the
revision .gclient_entries recorded, which is not necessarily the one checked
out. It also fails outright here, because gclient's nested checkouts
(src/electron, src/third_party/angle, src/third_party/aria-practices, ...) are
untracked trees inside src, and a checkout that would overwrite them aborts.

What this does instead:

  * Our patches are applied with `git apply`, so everything they changed is an
    uncommitted modification in whichever repository owns the file -- and that
    is often not the repository the patch was applied from. chromium/ patches
    are applied from src/, but third_party/angle/*.patch lands in
    src/third_party/angle, its own git checkout. So the repositories are
    discovered per file and reset one by one.

  * `git reset --hard` with no revision, i.e. to HEAD. Electron's own patches
    are commits -- the sync's apply_all_patches hook commits them -- so they
    are part of HEAD and survive. Ours are in the working tree and do not.

  * No `git clean`. Cleaning src would delete those nested checkouts, which is
    exactly how --delete_unversioned_trees destroyed the Electron checkout.
    Files our patches *create* are untracked, so reset leaves them behind;
    they are read out of the patches and removed by name.
"""

import argparse
import os
import re
import subprocess
import sys

NEW_FILE_RE = re.compile(r'^new file mode ', re.MULTILINE)
# Same leniency build.sh's apply_series uses, so the reverse of an applied
# patch is judged the same way the forward application was.
APPLY_FLAGS = ('--ignore-space-change', '--whitespace=nowarn')


def fail(msg):
    sys.exit(f'error: {msg}')


def git(repo, *args):
    return subprocess.run(('git', '-C', repo) + args,
                          capture_output=True, text=True)


def patch_targets(path):
    """Yield (target_path, is_new_file) for every file a patch touches.

    The path comes from the `diff --git a/X b/X` header rather than from
    `+++ b/X`, because a binary file has no `+++` line at all -- it carries a
    "GIT binary patch" payload instead. Reading `+++` missed exactly those, so
    the binaries chromium/sandbox/0299 adds (wow_helper.exe and .pdb) were
    never removed, and the patch then failed to re-apply with "already exists
    in working directory" -- residue that looks just like a rebase conflict.
    """
    with open(path, encoding='utf-8', errors='replace') as f:
        text = f.read()
    # Split on the diff headers so "new file mode" is attributed to the right
    # file; anything before the first one is the prose header.
    for chunk in re.split(r'(?m)^(?=diff --git )', text)[1:]:
        m = re.match(r'diff --git a/(\S+) b/(\S+)', chunk)
        if not m:
            continue
        # A rename gives different a/ and b/ names; the b/ side is what exists
        # afterwards and so what has to go.
        target = m.group(2)
        if target == 'dev/null':
            continue
        yield target, bool(NEW_FILE_RE.search(chunk))


def tracked(repo, path):
    rel = os.path.relpath(path, repo)
    return git(repo, 'ls-files', '--error-unmatch', rel).returncode == 0


def repo_of(path, cache):
    """The git checkout owning path, which may be nested inside another."""
    d = os.path.dirname(path) or path
    while d and not os.path.isdir(d):
        d = os.path.dirname(d)
    if d in cache:
        return cache[d]
    r = git(d, 'rev-parse', '--show-toplevel')
    top = r.stdout.strip() if r.returncode == 0 else None
    cache[d] = top
    return top


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--patches', required=True, help='the patches/ directory')
    p.add_argument('--series', action='append', default=[], metavar='NAME=ROOT',
                   help='series name and the directory it is applied from')
    p.add_argument('--dry-run', action='store_true')
    args = p.parse_args()

    repos, created, cache = set(), [], {}
    # Patches touching files no repository tracks. git reset cannot restore a
    # downloaded dependency like third_party/rust-toolchain -- gclient fetches
    # it as a GCS object, so nothing has a pristine copy to reset to. Those
    # have to be reverse-applied instead, which is only reliable from the top
    # of the stack down (0330 and 0331 overlap: with both applied, 0330 alone
    # will not reverse).
    unmanaged = []

    for spec in args.series:
        name, _, root = spec.partition('=')
        series = os.path.join(args.patches, name, 'series')
        if not os.path.isfile(series):
            continue
        if not os.path.isdir(root):
            fail(f'{root} (for {name}/) is not a directory')

        with open(series, encoding='utf-8') as f:
            entries = [l.strip() for l in f
                       if l.strip() and not l.startswith('#')]

        for entry in entries:
            patch = os.path.join(args.patches, name, entry)
            if not os.path.isfile(patch):
                fail(f'patches/{name}/series lists {entry}, which does not exist')
            needs_reverse = False
            for target, is_new in patch_targets(patch):
                full = os.path.join(root, target)
                if is_new:
                    created.append(full)
                top = repo_of(full, cache)
                if top:
                    repos.add(top)
                    if not is_new and not tracked(top, full):
                        needs_reverse = True
                elif not is_new:
                    needs_reverse = True
            if needs_reverse:
                unmanaged.append((patch, root))

    if not repos:
        fail('no git repositories found for the series; are sources downloaded?')

    if unmanaged:
        print(f'  {len(unmanaged)} patches reach files no repository tracks; '
              f'reverse-applying newest first')
    for patch, root in reversed(unmanaged):
        if git(root, 'apply', '--reverse', '--check', *APPLY_FLAGS,
               patch).returncode != 0:
            continue                      # not applied, nothing to undo
        rel = os.path.relpath(patch, args.patches)
        if args.dry_run:
            print(f'    would reverse {rel}')
            continue
        r = git(root, 'apply', '--reverse', *APPLY_FLAGS, patch)
        if r.returncode != 0:
            fail(f'could not reverse-apply {rel}:\n{r.stderr.strip()}')
        print(f'    reversed {rel}')

    print(f'  {len(repos)} repositories touched by the series')
    for repo in sorted(repos):
        label = repo
        dirty = git(repo, 'status', '--porcelain', '--untracked-files=no').stdout
        n = len([l for l in dirty.splitlines() if l])
        if args.dry_run:
            print(f'    would reset {label} ({n} modified)')
            continue
        r = git(repo, 'reset', '--hard')
        if r.returncode != 0:
            fail(f'git reset --hard failed in {repo}:\n{r.stderr.strip()}')
        if n:
            print(f'    reset {label} ({n} modified)')

    # Only remove created files that are untracked: if one of them is tracked,
    # upstream has since added a file of that name and reset already restored
    # the real thing, which must not be deleted.
    removed = 0
    for path in sorted(set(created)):
        if not os.path.exists(path):
            continue
        top = repo_of(path, cache)
        if top:
            if tracked(top, path):
                continue
        if args.dry_run:
            print(f'    would remove {path}')
        else:
            os.remove(path)
        removed += 1

    print(f'  {removed} file{"" if removed == 1 else "s"} created by the series '
          f'{"would be " if args.dry_run else ""}removed')


if __name__ == '__main__':
    main()
