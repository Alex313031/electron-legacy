#!/usr/bin/env python3
# Copyright (c) 2026 Alex313031
"""Import a patch set from e3kskoy7wqk/Electron-for-windows-7 into this repo's layout.

Upstream ships each version as a flat directory of hash-named diffs, with
commit_hashes.txt (applied bottom-to-top by apply_patches.bat) and a
commit_message_<hash>.txt per diff. This script converts that into:

  <out>/chromium/series                       apply order, relative to chromium/
  <out>/chromium/<area>/NNNN-<slug>.patch     <area> = most-touched top-level dir
  <out>/electron/series, NN-<slug>.patch      applied in src/electron
  <out>/node/series, NN-<slug>.patch          applied in src/third_party/electron_node
  <out>/other/series, NN-<slug>.patch         applied in src/, after chromium/ (our own
                                              additions: XP, cross-building, SIMD, ...)
  <out>/upstream-map.tsv                      provenance: new path -> original file/commit(s)

Each .patch gets a short plain-text header (title, upstream commits, origin)
before the original diff. git apply ignores text before the first diff header.
The diff body is copied byte-for-byte (some patches contain CRLF on purpose).

Accepts upstream's layout (vXX/ with chromium/, electron/,
third_party/electron_node/ and loose root patches) as well as the flattened
layout (chromium/, electron/, node/, other/).

Usage:
  tools/import_upstream_patches.py <upstream_dir> <out_dir> --origin "e3kskoy7wqk/Electron-for-windows-7 v44.2.0"
"""

import argparse
import collections
import re
import subprocess
import sys
from pathlib import Path

# Patches that have no commit_message file: give them a readable title.
# Keyed by original file name. Unknown files fall back to a title derived
# from the file name (and a warning).
TITLES = {
    "rust01.diff": "Rust std: use the win7 code paths unconditionally",
    "rust02.diff": "Rust std: stub out Windows APIs missing on Windows 7",
    "disable-redraw-lock.patch": "Disable redraw lock (dropped from Electron, restored)",
    "RoOriginateLanguageException.diff": "nearby: don't call RoOriginateLanguageException",
    "chore_drop_support_for_Windows_7__8__8.1_(#36427).diff":
        "Revert \"chore: drop support for Windows 7 / 8 / 8.1 (#36427)\"",
    "GetCurrentPackageFullName.diff": "Load GetCurrentPackageFullName dynamically",
    "fix_crash_caused_by_gethostnamew_on_windows_7.patch":
        "Fix crash caused by GetHostNameW on Windows 7",
    "fix_crash_uv_get_process_title_on_windows_7.diff":
        "Fix crash in uv_get_process_title on Windows 7",
    "FR_add_real-time_clock_version_of_uv_hrtime()_#1674.diff":
        "Fall back to GetSystemTimeAsFileTime when the precise variant is missing",
}

# Apply order for the non-chromium series (upstream gives none). Files not
# listed here are appended alphabetically.
ORDER = {
    "electron": [
        "chore_drop_support_for_Windows_7__8__8.1_(#36427).diff",
        "GetCurrentPackageFullName.diff",
    ],
    "node": [
        "fix_crash_caused_by_gethostnamew_on_windows_7.patch",
        "fix_crash_uv_get_process_title_on_windows_7.diff",
        "FR_add_real-time_clock_version_of_uv_hrtime()_#1674.diff",
    ],
}

# Loose upstream patches (applied from src/) that go into our own other/
# series instead of chromium/. other/ is for this repo's own additions that
# aren't upstream Chromium reverts. Other loose patches join chromium/.
OTHER_PATCHES = [
    "disable-redraw-lock.patch",
]

# Width of each series' numeric prefix. chromium/ numbers by global position
# over 300+ patches, so it needs four digits; the others number from 1 within
# a series short enough that two read better.
SEQ_DIGITS = {"chromium": 4}
DEFAULT_SEQ_DIGITS = 2

PATCH_EXTS = (".diff", ".patch")
MSG_LINE = re.compile(r"^(?P<title>.+?)\s{4,}(?P<date>\S.*?)\s{4,}(?P<hash>[0-9a-f]{7,40})$")
PATH_LINE = re.compile(rb"^\+\+\+ b/(\S+)|^--- a/(\S+)", re.M)


def warn(msg):
    print(f"warning: {msg}", file=sys.stderr)


def slugify(title, limit=60):
    slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    if len(slug) > limit:
        slug = slug[:limit].rsplit("-", 1)[0]
    return slug or "patch"


def parse_messages(path):
    """Return [(title, date, hash)] from a commit_message_*.txt file."""
    entries = []
    text = path.read_text(encoding="utf-8", errors="replace").replace("\r", "")
    # A few files lack a newline between entries: split after each 40-char hash.
    text = re.sub(r"([0-9a-f]{40})(?=\S)", r"\1\n", text)
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        m = MSG_LINE.match(line)
        if not m:
            warn(f"{path.name}: unparsed message line: {line!r}")
            entries.append((line, "", ""))
            continue
        entries.append((m["title"].strip(), m["date"].strip(), m["hash"]))
    return entries


def touched_area(body):
    """Most-touched top-level dir (third_party/<x> counts as its own area)."""
    counts = collections.Counter()
    order = []
    for m in PATH_LINE.finditer(body):
        p = (m.group(1) or m.group(2)).decode("utf-8", "replace")
        parts = p.split("/")
        key = "/".join(parts[:2]) if parts[0] == "third_party" and len(parts) > 2 else parts[0]
        if len(parts) == 1:
            key = "root"
        if key not in counts:
            order.append(key)
        counts[key] += 1
    if not counts:
        return "misc"
    best = max(counts.values())
    return next(k for k in order if counts[k] == best)


def header(title, commits, origin):
    lines = [f"Title: {title}"]
    for t, d, h in commits:
        if h:
            lines.append(f"Upstream-Commit: {h} ({d}) {t}")
    lines.append(f"Origin: {origin}")
    return ("\n".join(lines) + "\n\n").encode()


def git_stat(data):
    r = subprocess.run(["git", "apply", "--numstat", "-"], input=data,
                       capture_output=True)
    if r.returncode:
        raise RuntimeError(r.stderr.decode())
    return r.stdout


class Writer:
    def __init__(self, out, origin_label, src_root):
        self.out = out
        self.origin_label = origin_label
        self.src_root = src_root
        self.map_rows = []

    def emit(self, series, seq, area, src, title, commits):
        rel_dir = Path(area) if area else Path()
        digits = SEQ_DIGITS.get(series, DEFAULT_SEQ_DIGITS)
        name = f"{seq:0{digits}d}-{slugify(title)}.patch"
        rel = rel_dir / name
        dest = self.out / series / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        body = src.read_bytes()
        origin = f"{self.origin_label} {src.relative_to(self.src_root).as_posix()}"
        data = header(title, commits, origin) + body
        dest.write_bytes(data)
        # Verify: body preserved exactly, and git parses it the same way.
        assert dest.read_bytes()[len(data) - len(body):] == body
        if git_stat(data) != git_stat(body):
            raise RuntimeError(f"git parses {dest} differently from {src}")
        for t, d, h in commits or [(title, "", "")]:
            self.map_rows.append((series, rel.as_posix(), origin, h, d, t))
        return rel.as_posix()


def find_dir(root, *names):
    for n in names:
        if (root / n).is_dir():
            return root / n
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src", type=Path, help="upstream version dir (e.g. v44.2.0)")
    ap.add_argument("out", type=Path, help="output dir (must not exist)")
    ap.add_argument("--origin", required=True,
                    help='label recorded in headers, e.g. "e3kskoy7wqk/Electron-for-windows-7 v44.2.0"')
    args = ap.parse_args()

    src, out = args.src.resolve(), args.out.resolve()
    if out.exists():
        sys.exit(f"error: {out} already exists")
    chromium = find_dir(src, "chromium")
    if not chromium or not (chromium / "commit_hashes.txt").is_file():
        sys.exit(f"error: {src}/chromium/commit_hashes.txt not found")

    w = Writer(out, args.origin, src)

    # --- chromium: reverse of commit_hashes.txt, as apply_patches.bat does.
    hashes = [h.strip() for h in
              (chromium / "commit_hashes.txt").read_text().replace("\r", "").splitlines()
              if h.strip()]
    if len(set(hashes)) != len(hashes):
        sys.exit("error: duplicate entries in commit_hashes.txt")
    on_disk = {p.stem for p in chromium.glob("*.diff")}
    if missing := set(hashes) - on_disk:
        sys.exit(f"error: listed but missing: {sorted(missing)}")
    if unlisted := on_disk - set(hashes):
        sys.exit(f"error: diffs not in commit_hashes.txt: {sorted(unlisted)}")

    series = []
    seq = 0
    for h in reversed(hashes):
        seq += 1
        diff = chromium / f"{h}.diff"
        msg = chromium / f"commit_message_{h}.txt"
        commits = parse_messages(msg) if msg.is_file() else []
        primary = next((c for c in commits if c[2] == h), commits[0] if commits else None)
        if primary:
            title = primary[0]
        elif diff.name in TITLES:
            title = TITLES[diff.name]
        else:
            title = h
            warn(f"{diff.name}: no commit message and no title override")
        area = touched_area(diff.read_bytes())
        series.append(w.emit("chromium", seq, area, diff, title, commits))

    # --- loose patches that apply from src/ (upstream root, or other/).
    extra = sorted(p for d in (src, src / "other") if d.is_dir()
                   for p in d.iterdir() if p.is_file() and p.suffix in PATCH_EXTS)
    other = []
    for p in extra:
        title = TITLES.get(p.name) or p.stem.replace("_", " ")
        if p.name not in TITLES:
            warn(f"{p.name}: no title override")
        if p.name in OTHER_PATCHES:
            other.append((p, title))
            continue
        seq += 1
        series.append(w.emit("chromium", seq, touched_area(p.read_bytes()), p, title, []))
    (out / "chromium" / "series").write_text("\n".join(series) + "\n")

    # --- other/: flat, applied from src/ after chromium/, in OTHER_PATCHES order.
    other.sort(key=lambda pt: OTHER_PATCHES.index(pt[0].name))
    if other:
        lines = [w.emit("other", i, "", p, t, []) for i, (p, t) in enumerate(other, 1)]
        (out / "other" / "series").write_text("\n".join(lines) + "\n")

    # --- electron and node series.
    for name, dirs in (("electron", ("electron",)),
                       ("node", ("node", "third_party/electron_node"))):
        d = find_dir(src, *dirs)
        if not d:
            warn(f"no {name} patches found")
            continue
        files = {p.name: p for p in d.iterdir() if p.is_file() and p.suffix in PATCH_EXTS}
        ordered = [n for n in ORDER.get(name, []) if n in files]
        rest = sorted(set(files) - set(ordered))
        for n in rest:
            warn(f"{name}/{n}: not in ORDER, appended")
        lines = []
        for i, n in enumerate(ordered + rest, 1):
            title = TITLES.get(n) or Path(n).stem.replace("_", " ")
            lines.append(w.emit(name, i, "", files[n], title, []))
        (out / name / "series").write_text("\n".join(lines) + "\n")

    with open(out / "upstream-map.tsv", "w", encoding="utf-8", newline="\n") as f:
        f.write("series\tpatch\torigin\tupstream_commit\tupstream_date\tupstream_title\n")
        for row in w.map_rows:
            f.write("\t".join(row) + "\n")

    total = sum(1 for _ in out.rglob("*.patch"))
    print(f"wrote {total} patches to {out}")


if __name__ == "__main__":
    main()
