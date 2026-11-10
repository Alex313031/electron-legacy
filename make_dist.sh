#!/bin/bash
# make_dist.sh -- TEMPORARY, not part of the build. Delete when the release is up.
#
# Fills checkout/dist/v<version>/ with the upstream Electron artifacts this repo
# does not build, leaving everything we did build untouched, then merges
# SHASUMS256.txt so a single upload of that directory serves every platform.
#
# Consumers on win32 ia32/x64 keep using the checksums bundled in the npm
# package; anything else needs electron_use_remote_checksums=1, which makes
# @electron/get fetch the merged SHASUMS256.txt from the release instead.
#
# The upstream manifest is the source of truth for what exists: SHASUMS256.txt
# lists every hashed asset, so there is no need for the GitHub API or gh.
#
# Re-runnable. Files already present are left alone, and the merge always
# rebuilds from a pristine copy of our own SHASUMS256.txt, so running twice
# cannot merge a merge. Note that `build.sh --package` regenerates
# SHASUMS256.txt from scratch -- re-run this afterwards if that happens.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$HERE"

DRY_RUN=0
SKIP_SYMBOLS=1
JOBS=4

usage() {
  cat <<EOF
Usage: ${0##*/} [-n] [--with-symbols] [-j N]

  -n, --dry-run        list what would be downloaded, with sizes, and stop
  --with-symbols       also fetch the debug artifacts, which are skipped by
                       default: *-symbols, *-pdb, *-dsym*, *-debug,
                       *-toolchain-profile, xcache-*. They are most of the
                       bytes and only describe upstream's binaries -- notably
                       the win32-x64 ones would NOT match the win32-x64
                       electron.zip this release ships, which is ours
  -j N                 parallel downloads (default $JOBS)
  -h, --help           this help
EOF
}

die() { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case $1 in
    -n|--dry-run) DRY_RUN=1 ;;
    --with-symbols) SKIP_SYMBOLS=0 ;;
    -s|--skip-symbols) SKIP_SYMBOLS=1 ;;  # now the default; kept so it still works
    -j) shift; JOBS=${1:-} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument '$1'" ;;
  esac
  shift
done
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || die "-j needs a positive integer"

command -v curl >/dev/null || die "curl not found"

# Keep in step with the build rather than hardcoding a version here.
VERSION=$(grep -m1 '^ELECTRON_VERSION=' build.sh | cut -d'"' -f2)
[ -n "$VERSION" ] || die "could not read ELECTRON_VERSION from build.sh"
DIST="checkout/dist/v$VERSION"
[ -d "$DIST" ] || die "$DIST does not exist -- run ./build.sh --package first"

BASE="https://github.com/electron/electron/releases/download/v$VERSION"
MERGED="$DIST/SHASUMS256.txt"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

printf 'upstream manifest: %s/SHASUMS256.txt\n' "$BASE"
curl -fsSL --retry 3 -o "$tmp/upstream.sha" "$BASE/SHASUMS256.txt" \
  || die "could not fetch upstream SHASUMS256.txt for v$VERSION"

# What upstream has that we do not. Our files win on name collision, which is
# the whole point: our win32-x64 zips replace upstream's.
python3 - "$tmp/upstream.sha" "$DIST" "$SKIP_SYMBOLS" > "$tmp/todo" <<'PY'
import sys, os, re
manifest, dist, skip_symbols = sys.argv[1], sys.argv[2], sys.argv[3] == '1'
SYMBOLS = re.compile(r'(-symbols\.|-pdb\.|-dsym|-debug\.|-toolchain-profile\.|^xcache-)')
have = set(os.listdir(dist))
for line in open(manifest):
    line = line.rstrip('\n')
    if not line.strip():
        continue
    _, name = line.split(' *', 1)
    if name in have or name == 'SHASUMS256.txt':
        continue
    if skip_symbols and SYMBOLS.search(name):
        continue
    print(name)
PY

count=$(wc -l < "$tmp/todo")
if [ "$count" -eq 0 ]; then
  printf 'nothing to download; every upstream artifact is already present\n'
else
  printf 'probing %d artifact(s) for size...\n' "$count"
  : > "$tmp/sizes"
  while IFS= read -r name; do
    # -L to follow the redirect to the CDN, which is what carries the length.
    len=$(curl -fsSLI --retry 2 "$BASE/$name" \
          | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v+0}')
    printf '%s\t%s\n' "$len" "$name" >> "$tmp/sizes"
  done < "$tmp/todo"

  total=$(awk -F'\t' '{s+=$1} END{print s+0}' "$tmp/sizes")
  printf '\n%-14s %s\n' "SIZE" "ARTIFACT"
  sort -t$'\t' -k1,1nr "$tmp/sizes" \
    | awk -F'\t' '{printf "%-14s %s\n", sprintf("%.1f MiB", $1/1048576), $2}'
  printf '%-14s %d files\n' "$(awk -v t="$total" 'BEGIN{printf "%.2f GiB", t/1073741824}')" "$count"

  avail=$(df -B1 --output=avail "$DIST" | tail -1 | tr -d ' ')
  printf '\ndisk free at %s: %s\n' "$DIST" \
    "$(awk -v a="$avail" 'BEGIN{printf "%.2f GiB", a/1073741824}')"
  if [ "$total" -gt 0 ] && [ "$avail" -lt $((total + 2 * 1024 * 1024 * 1024)) ]; then
    die "not enough free space (want the download plus 2 GiB headroom)"
  fi

  if [ "$DRY_RUN" = 1 ]; then
    printf '\ndry run: nothing downloaded. Drop -n to fetch.\n'
    exit 0
  fi

  # One curl invocation, parallel, resuming anything half-finished.
  : > "$tmp/curlrc"
  while IFS= read -r name; do
    printf 'url = "%s/%s"\noutput = "%s/%s"\n' "$BASE" "$name" "$DIST" "$name" \
      >> "$tmp/curlrc"
  done < "$tmp/todo"
  printf '\ndownloading with %d parallel connections...\n' "$JOBS"
  curl --parallel --parallel-max "$JOBS" --retry 3 --retry-delay 2 \
       --continue-at - --fail --location --progress-bar -K "$tmp/curlrc" \
    || die "one or more downloads failed; re-run to resume"

  # Verify what we just pulled against upstream's own hashes.
  printf '\nverifying downloads...\n'
  grep -F -f <(sed 's/^/ \*/' "$tmp/todo") "$tmp/upstream.sha" > "$tmp/verify.sha" || true
  if [ -s "$tmp/verify.sha" ]; then
    # $tmp is already absolute (mktemp -d), so it survives the cd as-is.
    ( cd "$DIST" && sha256sum -c --quiet "$tmp/verify.sha" ) \
      || die "checksum mismatch on a downloaded file; delete it and re-run"
    printf '  %d file(s) verified\n' "$(wc -l < "$tmp/verify.sha")"
  fi
fi

# Rebuild the manifest by hashing whatever is actually in the directory, rather
# than merging a snapshot of an earlier SHASUMS256.txt. The bytes are the
# truth: a file we built and a file we downloaded hash identically, so this
# needs no record of which is which. It also stays correct as the local build
# set grows -- once linux zips are built here their names collide with
# upstream's, and a snapshot-based merge would publish upstream's hash for your
# binary. Downloads are still verified against upstream's hashes above, so
# nothing is taken on trust.
#
# -b to match upstream's dist manifest: sumchecker, which @electron/get hands
# this to, expects the binary-mode "*" marker. The headers manifest is the
# opposite -- see the note in build.sh's package().
printf '\nhashing %s ...\n' "$DIST"
# Excludes every SHASUMS256* name, not just the manifest itself: an earlier
# version of this script kept its bookkeeping copy in here, and one such stray
# got hashed into the manifest and uploaded to the release before this was
# caught. Nothing named SHASUMS256* is a release artifact.
( cd "$DIST" \
  && find . -maxdepth 1 -type f ! -name 'SHASUMS256*' \
     | sed 's|^\./||' | sort | xargs sha256sum -b -- > SHASUMS256.txt.tmp \
  && mv SHASUMS256.txt.tmp SHASUMS256.txt ) \
  || die "could not write $MERGED"

# Report provenance by comparing against upstream, purely informational.
python3 - "$MERGED" "$tmp/upstream.sha" <<'PY'
import sys
def read(p):
    d = {}
    for line in open(p):
        line = line.rstrip('\n')
        if line.strip():
            h, n = line.split(' *', 1) if ' *' in line else line.split(None, 1)
            d[n.strip()] = h.strip()
    return d
merged, upstream = read(sys.argv[1]), read(sys.argv[2])
same = sum(1 for n, h in merged.items() if upstream.get(n) == h)
print(f'SHASUMS256.txt: {len(merged)} entries '
      f'({len(merged) - same} built here, {same} matching upstream)')
PY

printf '\nupload the whole %s/ to the v%s release.\n' "$DIST" "$VERSION"
