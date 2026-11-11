#!/usr/bin/env python3
"""Report imports a PE needs that a reference set of system DLLs does not export.

Written for the XP/Vista work. A statically imported symbol that the target OS
does not export is fatal at load, before any of our code runs -- which is how
Vista rejected Electron over TryAcquireSRWLockExclusive. Finding those one boot
at a time is slow; electron.exe alone imports several hundred kernel32
functions. This answers the whole question in one pass, given DLLs copied off
the target machine.

  tools/check_win_imports.py --system-dlls ~/vista-dlls \\
      checkout/src/out/Release-x86/electron.exe

Exit status is non-zero if anything is missing from a *static* import, which is
the fatal class. Delay imports are reported separately: they resolve on first
use, so they break a feature rather than the process, and Chromium gates most
of them behind runtime version checks anyway.

Only name-based matching is done. Export forwarders count as exported (that is
how Vista's kernel32 re-exports parts of ntdll), because the loader resolves
them transparently.
"""

import argparse
import os
import sys

try:
    import pefile
except ImportError:
    sys.exit('need pefile: pip install pefile')


# DLLs that ship beside the binary rather than coming from the OS, so a
# reference copy is neither expected nor meaningful.
OURS = {
    'ffmpeg.dll', 'dxcompiler.dll', 'dxil.dll', 'd3dcompiler_47.dll',
    'vulkan-1.dll', 'vk_swiftshader.dll', 'libegl.dll', 'libglesv2.dll',
    'electron.exe',
}


def load_exports(dirpath):
    """{dll name: set of exported symbol names} for every PE in dirpath."""
    index = {}
    for entry in sorted(os.listdir(dirpath)):
        path = os.path.join(dirpath, entry)
        if not os.path.isfile(path):
            continue
        try:
            pe = pefile.PE(path, fast_load=True)
            pe.parse_data_directories(
                directories=[pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_EXPORT']])
        except Exception as exc:
            print(f'  ! skipping {entry}: {exc}', file=sys.stderr)
            continue
        names = set()
        for exp in getattr(getattr(pe, 'DIRECTORY_ENTRY_EXPORT', None), 'symbols', []) or []:
            if exp.name:
                names.add(exp.name.decode(errors='replace'))
        index[entry.lower()] = names
        pe.close()
    return index


def load_imports(path):
    """[(dll, symbol, 'STATIC'|'delay')] for one PE. Ordinals become #N."""
    pe = pefile.PE(path, fast_load=True)
    pe.parse_data_directories(directories=[
        pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_IMPORT'],
        pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT']])
    out = []
    for attr, kind in (('DIRECTORY_ENTRY_IMPORT', 'STATIC'),
                       ('DIRECTORY_ENTRY_DELAY_IMPORT', 'delay')):
        for entry in getattr(pe, attr, []) or []:
            dll = entry.dll.decode(errors='replace').lower()
            for imp in entry.imports:
                name = (imp.name.decode(errors='replace') if imp.name
                        else f'#{imp.ordinal}')
                out.append((dll, name, kind))
    pe.close()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--system-dlls', required=True,
                    help='directory of DLLs copied off the target OS')
    ap.add_argument('binaries', nargs='+')
    args = ap.parse_args()

    print(f'reference DLLs from {args.system_dlls}')
    exports = load_exports(args.system_dlls)
    for dll in sorted(exports):
        print(f'  {dll:34s} {len(exports[dll]):6d} exports')
    if not exports:
        sys.exit('no readable PEs in --system-dlls')

    fatal = 0
    for binary in args.binaries:
        print(f'\n=== {binary} ===')
        try:
            imports = load_imports(binary)
        except Exception as exc:
            print(f'  ! cannot read: {exc}')
            continue

        missing = {'STATIC': [], 'delay': []}
        no_reference = {}
        for dll, sym, kind in imports:
            if dll in OURS:
                continue
            if dll not in exports:
                no_reference.setdefault(dll, set()).add(kind)
                continue
            if sym.startswith('#'):
                continue          # ordinal import, cannot match by name
            if sym not in exports[dll]:
                missing[kind].append((dll, sym))

        for kind, label in (('STATIC', 'FATAL AT LOAD -- static imports not exported'),
                            ('delay', 'fails on first use -- delay imports not exported')):
            rows = sorted(set(missing[kind]))
            if rows:
                print(f'\n  {label} ({len(rows)}):')
                for dll, sym in rows:
                    print(f'    {dll}!{sym}')
            else:
                print(f'\n  {label}: none')
        fatal += len(set(missing['STATIC']))

        if no_reference:
            print(f'\n  no reference copy provided, cannot judge ({len(no_reference)}):')
            for dll in sorted(no_reference):
                kinds = '+'.join(sorted(no_reference[dll]))
                hint = '  <-- api-set, absent before Win8' if dll.startswith('api-ms-win') else ''
                print(f'    {dll:44s} [{kinds}]{hint}')

    print()
    if fatal:
        print(f'{fatal} static import(s) would stop the process loading.')
        return 1
    print('No static import problems found against this reference set.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
