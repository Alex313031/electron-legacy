#!/usr/bin/env bash

# Copyright (c) 2026 Alex313031

# For building NodeJS + Installer for Windows 7, separate from Electron.
#
# Standalone: copy this directory (the .patch files and standalone_series next
# to it) anywhere, run it, and it clones Node, patches it, and builds it. With
# --package it also produces the .zip upstream publishes and, for x64, the .msi.

# Fetch, patch, build and package NodeJS for legacy Windows.
# Requires Python 3.9+, Git bash, NASM, and Visual Studio 2022 with Windows SDK 10.0.22621.x installed.

set -u -o pipefail

SCRIPTNAME=$(basename "$0")
SCRIPTVER="1.0.8"

export HERE=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Node release tag to build.
NODE_VERSION="v24.22.3"

ROOT_PATH="${ROOT_PATH:-$HERE}"

# Where to clone Node sources
SRC_PATH="$ROOT_PATH/src"

# Where node src lives once it's cloned
NODE_PATH="$SRC_PATH/node"

# winwrap supplies the Win32 functions XP does not export. It lives inside the
# Node tree rather than beside it, because GYP resolves a dependency relative
# to <(DEPTH) and reaching outside the tree from there is awkward --
# deps/winwrap is the layout winwrap.gyp documents.
WINWRAP_URL="https://github.com/Alex313031/winwrap.git"
# Pinned to a commit rather than following main, so a given checkout of this
# repository always builds against the same winwrap: this is 0.5.0. Electron's
# pin is in patches/other/18-winwrap-library.patch; bump the two together.
WINWRAP_REV="73a59911382a69c27db85c43452dc08b92a004fb"
WINWRAP_PATH="$NODE_PATH/deps/winwrap"

# Patch series to apply on top of the checkout
PATCHES_PATH="$HERE"

# The list of patches to apply, in order. Not `series`, which is the subset
# the Electron build applies to its own copy of Node: that build has to do
# without the GYP-side patches this one depends on. See the header of each.
SERIES_FILE="$PATCHES_PATH/standalone_series"

# Log file from this script
# Beside the script, not under src/: src/ doesn't exist on a first run, and
# everything that logs redirects into this file. (.gitignore covers it.)
LOG_FILE="$ROOT_PATH/build.log"

# Where to put the finished packages: the .zip, its symbols, and the .msi
DIST_PATH="$HERE/dist"

# Set Node source URL
NODE_URL="https://github.com/nodejs/node.git"

# Controls minimum Windows target, (unused currently)
WIN32_WINNT="0x0600"

# Custom Ninja status line.
export NINJA_SUMMARIZE_BUILD=1
export NINJA_STATUS="[%r processes, %f/%t @ %o/s | %e sec. ] "

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) HOST_OS=windows ;;
  Linux*) HOST_OS=linux ;;
  *) HOST_OS=unsupported ;;
esac

# Options, set by parse_args
ARCH=""
VERBOSE=0
IS_DEBUG=false
# Empty rather than true or false, because the default depends on the
# architecture and that is not known until the arguments have been read. An
# explicit --ltcg or --no-ltcg fills it in; resolve_ltcg decides otherwise.
USE_LTCG=""
DO_PACKAGE=false
DO_CLEAN=false
DO_SYNC=false
ONLY_DOWNLOAD=false
ONLY_PATCH=false

# Colors
YEL='\033[1;33m' # Yellow
CYA='\033[1;96m' # Cyan
RED='\033[1;31m' # Red
GRE='\033[1;32m' # Green
c0='\033[0;00m'  # Reset Text
bold='\033[1;37m' # Bold Text
underline='\033[4m' # Underline Text

show_help() {
  cat <<EOF
Usage:
  $SCRIPTNAME <arch> [options]
  $SCRIPTNAME -d | -p | --deps | --clean [arch]

Builds NodeJS $NODE_VERSION for legacy Windows. With an arch, this
downloads sources (first run only), applies patches, then builds.

Archs:
  x86 | x64 - Select 32 or 64 bit build

Options:
  -h, --help                  Show this help.
  -v, --verbose               Verbose output (always on for the build step).
  --version                   Show script version.
  --package                   Package built binaries into dist/ for distribution: the same
                              node-<version>-win-<arch>.zip upstream publishes, a zip of
                              node.pdb, and on x64 the .msi installer. x86 gets the zips
                              only; Node's installer project has no x86 platform. Needs
                              7z on PATH.
  -d, --download-sources      Only download sources, then exit; for making local modifications.
                              Discards any local changes in src/ (it resets to $NODE_VERSION).
  -p, --patch                 Only apply patches to already-downloaded sources, then exit; needs no arch.
                              Patches that are already applied are skipped.
  -s, --sync                  Re-sync existing sources before building (same reset as -d).
                              Without an arch it just syncs, then exits.
  --clean                     Removes build artifacts from out dir (only <arch>'s, if given).
  --debug                     Make a debug build (cannot be combined with --package).
  --ltcg                      Force link-time code generation on. Already the default for
                              x64; on x86 this re-enables a link that is known to crash.
  --no-ltcg                   Build without link-time code generation. Already the default
                              for x86, where lld-link dies with an access violation.

Environment:
  ROOT_PATH          Where sources and build log go.

For more details about building Node, see
https://github.com/nodejs/node/blob/$NODE_VERSION/BUILDING.md

EOF
}

show_version() {
  printf "\n ${bold} %s Version %s ${c0}\n\n" "$SCRIPTNAME" "$SCRIPTVER"
  exit 0
}

log() {
  # Print a message (printf-style: format then args) to the console with color,
  # and append a color-stripped copy to the log file so build.log stays clean.
  # Unlike execute(), it runs no command and does no error handling. The log
  # write is skipped until the log directory exists (e.g. early arg errors).
  printf "$@"
  if [ -d "$(dirname "$LOG_FILE")" ]; then
    printf "$@" | sed -E 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
  fi
}

warn() {
  log "${YEL} Warning: %s${c0}\n" "$1" >&2
}

error_exit() {
  local error_msg="${1:-An error occurred.}"
  log "${RED} %s${c0}\n" "$error_msg" >&2
  exit 1
}

arg_error() {
  error_exit "$1, see --help for options"
}

execute() {
  local info_msg="$1"
  local error_msg="$2"
  shift 2

  if [ ! "$error_msg" ]; then
    error_msg="error"
  fi

  if [ "$info_msg" ]; then
    log "${CYA} %s${c0}\n" "$info_msg"
  fi
  printf '$ %s\n' "$*" >> "$LOG_FILE"
  if [ "$VERBOSE" == "1" ]; then
    # mirror output to the console as well as the log file
    # (process substitution keeps "$@"'s exit status, unlike a pipe to tee)
    "$@" > >(tee -a "$LOG_FILE") 2>&1 || error_exit "$error_msg, check $LOG_FILE for details."
  else
    "$@" >>"$LOG_FILE" 2>&1 || error_exit "$error_msg, check $LOG_FILE for details."
  fi
}

create_dir() {
  local path="$1"

  local MKDIRFLAGS="-p"
  if [ "$VERBOSE" == "1" ]; then
    MKDIRFLAGS+=" -v"
  fi
  execute "" "Unable to create directory '$path'" \
      mkdir $MKDIRFLAGS "$path"
}

remove_path() {
  local path="$1"

  # Only ever delete build output, never a mistyped or empty path.
  case "$path" in
    "$SRC_PATH"/out|"$SRC_PATH"/out/*|"$DIST_PATH"|"$DIST_PATH"/*) ;;
    *) error_exit "Refusing to remove '$path': not under $SRC_PATH/out or $DIST_PATH" ;;
  esac

  local RMDIRFLAGS="-f -r"
  if [ "$VERBOSE" == "1" ]; then
    RMDIRFLAGS+=" -v"
  fi
  execute "" "Unable to remove path '$path'" \
      rm $RMDIRFLAGS "$path"
}

check_series_complete() {
  # Every patch here is meant to be in standalone_series, and nothing enforces
  # that when one is added. A patch missing from the list is not an error
  # anywhere -- the build just goes ahead without it -- so say so. A warning,
  # not a failure: a patch can legitimately be Electron's alone.
  local shared="$PATCHES_PATH/series"
  local p
  for p in "$PATCHES_PATH"/*.patch; do
    [ -f "$p" ] || continue
    p=$(basename "$p")
    grep -qxF -- "$p" "$SERIES_FILE" && continue
    if [ -f "$shared" ] && grep -qxF -- "$p" "$shared"; then
      warn "$p is in series (Electron's) but not in standalone_series; this build will not have it."
    else
      warn "$p is in neither series nor standalone_series; nothing applies it."
    fi
  done
}

apply_series() {
  local dir="$1"
  local series="$SERIES_FILE"
  local applied=0 skipped=0
  # Same leniency upstream's apply_patches.bat used.
  local flags=(--ignore-space-change --whitespace=nowarn)

  if [ ! -f "$series" ]; then
    log "${YEL} No %s, nothing to apply${c0}\n" "$series"
    return 0
  fi
  [ -d "$dir" ] || error_exit "Patch target '$dir' doesn't exist; are sources downloaded?"

  check_series_complete
  log "${CYA} Applying patches in %s${c0}\n" "$dir"
  local p file
  while IFS= read -r p || [ -n "$p" ]; do
    p="${p%$'\r'}"
    [[ -z "$p" || "$p" == \#* ]] && continue
    file="$PATCHES_PATH/$p"
    [ -f "$file" ] || error_exit "$series lists '$p', which doesn't exist"

    if git -C "$dir" apply --check "${flags[@]}" "$file" >/dev/null 2>&1; then
      execute "" "Failed to apply $p" git -C "$dir" apply "${flags[@]}" "$file"
      [ "$VERBOSE" == "1" ] && log "   applied %s\n" "$p"
      applied=$((applied + 1))
    elif git -C "$dir" apply --reverse --check "${flags[@]}" "$file" >/dev/null 2>&1; then
      [ "$VERBOSE" == "1" ] && log "   already applied %s\n" "$p"
      skipped=$((skipped + 1))
    else
      git -C "$dir" apply --check --verbose "${flags[@]}" "$file" >>"$LOG_FILE" 2>&1
      error_exit "Patch $p does not apply ($applied applied so far), check $LOG_FILE for details."
    fi
  done < "$series"
  log "${GRE} %d applied, %d already applied${c0}\n" "$applied" "$skipped"
}

apply_patches() {
  [ -d "$NODE_PATH" ] || error_exit "No sources in $SRC_PATH, run '$SCRIPTNAME -d' first"

  local tag head
  if tag=$(git -C "$NODE_PATH" rev-parse -q --verify "refs/tags/$NODE_VERSION^{commit}" 2>/dev/null); then
    head=$(git -C "$NODE_PATH" rev-parse HEAD)
    if [ "$tag" != "$head" ]; then
      warn "src/node isn't at $NODE_VERSION, which the patches are for; expect failures."
    fi
  fi

  apply_series "$NODE_PATH"
}

fetch_sources() {
  # Clone Node if it isn't here, otherwise fetch and reset onto the tag.
  create_dir "$SRC_PATH"
  if [ ! -d "$NODE_PATH/.git" ]; then
    execute "Cloning Node $NODE_VERSION into $NODE_PATH (this takes a while)" \
        "Unable to clone Node" \
        git clone --depth 1 --branch "$NODE_VERSION" "$NODE_URL" "$NODE_PATH"
    return 0
  fi
  warn "Syncing resets $NODE_PATH to $NODE_VERSION, discarding local changes."
  execute "Fetching Node $NODE_VERSION" "Unable to fetch Node" \
      git -C "$NODE_PATH" fetch --depth 1 origin "refs/tags/$NODE_VERSION:refs/tags/$NODE_VERSION"
  execute "Resetting to $NODE_VERSION" "Unable to reset Node" \
      git -C "$NODE_PATH" reset --hard "refs/tags/$NODE_VERSION"
  # -e deps/winwrap, or this deletes it: it is untracked as far as Node is
  # concerned, and it is a checkout somebody may well be editing. Re-cloning it
  # on every sync would be cheap but would silently discard that.
  execute "" "Unable to clean Node" git -C "$NODE_PATH" clean -fd -e deps/winwrap
}

fetch_winwrap() {
  # Brings deps/winwrap to WINWRAP_REV, whether that means cloning it or moving
  # a checkout that is already there.
  #
  # The one thing it will not do is disturb work in progress, for the reason
  # the clean exclusion above exists: this is a checkout somebody may well be
  # editing. A tree with uncommitted changes is left where it is, with a
  # warning that the build is not using the pinned revision. A clean tree at
  # another commit is moved, which loses nothing -- the commit it was on is
  # still in its branch and in the reflog.
  if [ -d "$WINWRAP_PATH/.git" ]; then
    local current
    current="$(git -C "$WINWRAP_PATH" rev-parse HEAD 2>/dev/null)"
    if [ "$current" = "$WINWRAP_REV" ]; then
      return 0
    fi
    if [ -n "$(git -C "$WINWRAP_PATH" status --porcelain 2>/dev/null)" ]; then
      warn "winwrap is at ${current:0:7} with uncommitted changes, not the pinned ${WINWRAP_REV:0:7}; leaving it alone"
      return 0
    fi
  else
    create_dir "$WINWRAP_PATH"
    execute "Creating winwrap checkout in $WINWRAP_PATH" "Unable to initialise winwrap" \
        git -C "$WINWRAP_PATH" init -q
    execute "" "Unable to add the winwrap remote" \
        git -C "$WINWRAP_PATH" remote add origin "$WINWRAP_URL"
  fi
  # By commit, which a clone cannot do: clone takes a branch or tag. Fetching
  # the one commit keeps it as shallow as the --depth 1 clone this replaced.
  execute "Fetching winwrap ${WINWRAP_REV:0:7}" "Unable to fetch winwrap $WINWRAP_REV" \
      git -C "$WINWRAP_PATH" fetch --depth 1 origin "$WINWRAP_REV"
  execute "Checking out winwrap ${WINWRAP_REV:0:7}" "Unable to check out winwrap" \
      git -C "$WINWRAP_PATH" -c advice.detachedHead=false checkout -q "$WINWRAP_REV"
}

vcbuild() {
  # vcbuild.bat is a batch file, so hand it to cmd.exe. Three Git Bash details
  # matter here:
  #  - MSYS rewrites arguments that look like Unix paths, so turn that off. The
  #    usual //c spelling only exists to survive that rewriting; with it off the
  #    switch has to be a plain /c, because cmd given //c finds no command to
  #    run and sits waiting on stdin forever.
  #  - the variables have to be exported, not just prefixed onto a shell
  #    function call, since it's cmd.exe's own environment the MSYS runtime
  #    reads them from.
  #  - the build writes straight to the console instead of through execute's
  #    tee: a native toolchain whose stdout is a pipe buffers so heavily that a
  #    working build is indistinguishable from a hung one. Pass `binlog` for a
  #    detailed MSBuild log in out/<config>/node.binlog.
  cd "$NODE_PATH" || error_exit "Unable to enter $NODE_PATH"
  log "${CYA} Building NodeJS for %s (this takes a long time)${c0}\n" "$ARCH"
  log "${CYA} vcbuild.bat %s${c0}\n" "$*"
  printf '$ cmd /c "vcbuild.bat %s"\n' "$*" >> "$LOG_FILE"
  (
    export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
    cmd.exe /c "vcbuild.bat $*"
  ) || error_exit "Build failed; vcbuild's output is above, not in $LOG_FILE"
}

build_node() {
  # "release" is deliberately not passed: it sets ltcg, which collides with an
  # explicit ltcg/lto, and Release is already vcbuild's default.
  if [ "$IS_DEBUG" = true ]; then
    vcbuild "$ARCH" debug full-icu download-all no-cctest clang-cl
  else
    # Whether ltcg is in here is decided by resolve_ltcg, which is also where
    # the reason the 32-bit default differs from the 64-bit one is written down.
    local flags=("$ARCH" full-icu download-all no-cctest clang-cl)
    [ "$USE_LTCG" = true ] && flags+=(ltcg)
    # `package` stages Release/node-<version>-win-<arch>/ -- node.exe, npm,
    # npx, corepack and the rest of what upstream ships -- and compresses it.
    # `msi` builds the installer from the same staging, and is x64 only: the
    # WiX project under tools/msvs/msi defines x64 and ARM64 and nothing else.
    if [ "$DO_PACKAGE" = true ]; then
      flags+=(package)
      [ "$ARCH" != x86 ] && flags+=(msi)
    fi
    vcbuild "${flags[@]}"
  fi
}

package() {
  # Collects what vcbuild's `package` and `msi` steps left behind into dist/.
  #
  # The zip is found by pattern rather than by building its name here: vcbuild
  # names it from FULLVERSION, which it reads out of the source tree and which
  # carries a suffix for anything but a plain release, so the only reliable
  # statement of the name is the file.
  local release="$NODE_PATH/Release"
  local zips=("$release"/node-v*-win-"$ARCH".zip)
  [ -f "${zips[0]}" ] \
    || error_exit "No node-v*-win-$ARCH.zip in $release; was this a release build, and is 7z on PATH?"
  create_dir "$DIST_PATH"

  local zip base
  for zip in "${zips[@]}"; do
    execute "Packaging $(basename "$zip")" "Unable to copy the zip" \
        cp "$zip" "$DIST_PATH/"
    log "${GRE} Zip: %s${c0}\n" "$DIST_PATH/$(basename "$zip")"
  done

  # The symbols. vcbuild calls this node_pdb.zip whatever was built, because
  # upstream publishes it inside a per-architecture directory. dist/ is flat
  # and holds both architectures, so it takes the package's name here.
  if [ -f "$release/node_pdb.zip" ]; then
    base="$(basename "${zips[0]}" .zip)"
    execute "Packaging ${base}-pdb.zip" "Unable to copy the symbols" \
        cp "$release/node_pdb.zip" "$DIST_PATH/${base}-pdb.zip"
    log "${GRE} Symbols: %s${c0}\n" "$DIST_PATH/${base}-pdb.zip"
  else
    warn "No node_pdb.zip in $release; the symbols were not packaged."
  fi

  # The installer, which vcbuild writes into the checkout root. Not on x86:
  # build_node did not ask for one there.
  [ "$ARCH" = x86 ] && return 0
  local msi="$NODE_PATH/node-${NODE_VERSION}-${ARCH}.msi"
  [ -f "$msi" ] || error_exit "No installer at $msi; was this a release build?"
  execute "Packaging $(basename "$msi")" "Unable to copy the installer" \
      cp "$msi" "$DIST_PATH/"
  log "${GRE} Installer: %s${c0}\n" "$DIST_PATH/$(basename "$msi")"
}

clean_out() {
  local d
  for d in Release Debug out; do
    if [ -d "$NODE_PATH/$d" ]; then
      execute "" "Unable to remove $d" rm -rf "$NODE_PATH/$d"
      log "${GRE} Removed %s${c0}\n" "$NODE_PATH/$d"
    fi
  done
}

check_prereqs() {
  [ "$HOST_OS" = windows ] \
    || error_exit "Node's vcbuild.bat only runs on Windows; use Git Bash there"
  command -v git >/dev/null 2>&1 || error_exit "git not found"
  command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1 \
    || error_exit "Python 3.9+ is required, see Node's BUILDING.md"
  [ -n "${VCToolsInstallDir:-}" ] || [ -d "/c/Program Files/Microsoft Visual Studio/2022" ] \
    || warn "Visual Studio 2022 not found in the default location; vcbuild.bat will look for itself."
  # Unconditional because build_node always passes clang-cl, whatever ltcg ends
  # up being. Said plainly rather than tied to ltcg: that was accurate while
  # ltcg was on for every architecture, and would now read as "not needed on
  # x86", where it still is.
  log "${CYA} Note: this build needs the ClangCL toolset installed in Visual Studio.${c0}\n"
  if [ "$DO_PACKAGE" = true ]; then
    # vcbuild runs `7z` by name for the zip and reports "Cannot create" when
    # it is missing -- after the whole build. Better said before it.
    command -v 7z >/dev/null 2>&1 \
      || error_exit "--package needs 7z on PATH (7-Zip's install directory is not added by its installer)"
    [ "$IS_DEBUG" = true ] \
      && error_exit "--package needs a release build; vcbuild only stages and installs Release"
    if [ "$ARCH" = x86 ]; then
      log "${CYA} Note: x86 gets the .zip only. Node's MSI project defines x64 and ARM64, so there is no x86 installer.${c0}\n"
    fi
  fi
}

# Fills in USE_LTCG when neither --ltcg nor --no-ltcg was given, which is a
# per-architecture decision rather than one default.
#
# x64 links with it fine. x86 does not: lld-link exits with 0xC0000005 part way
# through the final link, which MSBuild reports as "lld-link.exe exited with
# code -1073741819". That is the linker faulting, not a diagnostic about the
# program -- there is no undefined symbol, no bad object, nothing to act on, and
# the same tree links cleanly the moment ltcg comes off.
#
# So the 32-bit default is off, because the alternative is a build that spends
# an hour compiling and then dies at the one step that cannot be resumed. ltcg
# is a size and speed optimisation, never a correctness requirement, so the
# cost of defaulting it off is a slightly larger node.exe.
#
# --ltcg still forces it on, which is the point of resolving it here rather
# than refusing the combination: when a newer lld fixes this, trying x86 again
# is one flag and not an edit to this script.
resolve_ltcg() {
  # A debug build passes neither ltcg nor anything it would collide with, so
  # there is nothing to decide and reporting a decision would be misleading.
  # An explicit flag is called out rather than dropped quietly.
  if [ "$IS_DEBUG" = true ]; then
    [ -n "$USE_LTCG" ] && warn "--ltcg/--no-ltcg does not apply to a debug build; ignoring it"
    return 0
  fi
  if [ -n "$USE_LTCG" ]; then
    log "${CYA} ltcg: %s (given explicitly)${c0}\n" "$USE_LTCG"
    return 0
  fi
  case "$ARCH" in
    x86) USE_LTCG=false ;;
    *) USE_LTCG=true ;;
  esac
  log "${CYA} ltcg: %s (default for %s)${c0}\n" "$USE_LTCG" "$ARCH"
}

parse_args() {
  [ $# -eq 0 ] && { show_help; exit 0; }
  while [ $# -gt 0 ]; do
    case "$1" in
      x86|x64)
        [ -n "$ARCH" ] && arg_error "Architecture given twice"
        ARCH="$1" ;;
      -h|--help) show_help; exit 0 ;;
      -v|--verbose) VERBOSE=1 ;;
      --version) show_version ;;
      --package) DO_PACKAGE=true ;;
      -d|--download-sources) ONLY_DOWNLOAD=true ;;
      -p|--patch) ONLY_PATCH=true ;;
      -s|--sync) DO_SYNC=true ;;
      --clean) DO_CLEAN=true ;;
      --debug) IS_DEBUG=true ;;
      --ltcg) USE_LTCG=true ;;
      --no-ltcg) USE_LTCG=false ;;
      *) arg_error "Unknown option '$1'" ;;
    esac
    shift
  done

  # Syncing and patching don't depend on the architecture.
  if [ "$DO_SYNC" = true ] && [ -z "$ARCH" ]; then
    ONLY_DOWNLOAD=true
  fi
}

main() {
  parse_args "$@"
  # Plain mkdir, not create_dir: that logs, and logging needs this to exist.
  mkdir -p "$ROOT_PATH" || error_exit "Unable to create '$ROOT_PATH'"
  printf '\n==== %s: %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$SCRIPTNAME" "$*" >> "$LOG_FILE"

  if [ "$DO_CLEAN" = true ]; then
    clean_out
    exit 0
  fi

  if [ "$ONLY_DOWNLOAD" = true ] || [ "$ONLY_PATCH" = true ]; then
    [ "$ONLY_DOWNLOAD" = true ] && { fetch_sources; fetch_winwrap; }
    [ "$ONLY_PATCH" = true ] && apply_patches
    exit 0
  fi

  [ -n "$ARCH" ] || arg_error "No architecture given"
  resolve_ltcg
  check_prereqs

  if [ "$DO_SYNC" = true ] || [ ! -d "$NODE_PATH/.git" ]; then
    fetch_sources
  fi
  # Unconditional, and a no-op once it is there: a tree synced before winwrap
  # was wired in has none, and so does one cleaned by a copy of this script
  # that predates the exclusion.
  fetch_winwrap
  apply_patches
  build_node
  [ "$DO_PACKAGE" = true ] && package
  log "${GRE}${bold} Done. node.exe is in %s${c0}\n" "$NODE_PATH/out"
}

main "$@"
