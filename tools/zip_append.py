#!/usr/bin/env python3
# Copyright (c) 2026 Alex313031
"""Add files to an existing zip, replacing entries with the same name.

Usage: zip_append.py <archive.zip> <file>=<name-in-zip> [<file>=<name-in-zip> ...]

Used by build.sh to add mksnapshot_args and gen/v8/embedded.S to
mksnapshot.zip, as Electron's release CI does (Git Bash has no `zip`).
"""

import os
import shutil
import sys
import tempfile
import zipfile


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    archive = argv[1]
    adds = {}
    for spec in argv[2:]:
        src, sep, name = spec.partition("=")
        if not sep or not name:
            sys.exit(f"error: expected <file>=<name-in-zip>, got {spec!r}")
        if not os.path.isfile(src):
            sys.exit(f"error: {src} not found")
        adds[name.replace("\\", "/")] = src

    fd, tmp = tempfile.mkstemp(suffix=".zip", dir=os.path.dirname(os.path.abspath(archive)))
    os.close(fd)
    try:
        with zipfile.ZipFile(archive) as zin, \
             zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
            for info in zin.infolist():
                if info.filename not in adds:
                    zout.writestr(info, zin.read(info.filename))
            for name, src in adds.items():
                zout.write(src, name)
        shutil.move(tmp, archive)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


if __name__ == "__main__":
    main(sys.argv)
