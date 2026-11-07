#!/usr/bin/env bash

# Copyright (c) 2026 Alex313031

# For building NodeJS + Installer for Windows 7, separate from Electron.
#
# Standalone: copy this directory (the .patch files and series next to it)
# anywhere, run it, and it clones Node, patches it, and builds an .msi.

# Fetch, patch, build and package NodeJS for legacy Windows.
# Requires Python 3.9+, Git bash, NASM, and Visual Studio 2022 with Windows SDK 10.0.22621.x installed.

set -u -o pipefail

SCRIPTNAME=$(basename "$0")
SCRIPTVER="1.0.2"

export HERE=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Node release tag to build.
NODE_VERSION="v24.22.2"

ROOT_PATH="${ROOT_PATH:-$HERE}"

# Where to clone Node sources
SRC_PATH="$ROOT_PATH/src"

# Where node src lives once it's cloned
NODE_PATH="$SRC_PATH/node"

# Patch series to apply on top of the checkout
PATCHES_PATH="$HERE"

# Log file from this script
# Beside the script, not under src/: src/ doesn't exist on a first run, and
# everything that logs redirects into this file. (.gitignore covers it.)
LOG_FILE="$ROOT_PATH/build.log"

# Where to put finalized distribution .msi
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
  --package                   Package built binaries into dist/ for distribution.
  -d, --download-sources      Only download sources, then exit; for making local modifications.
                              Discards any local changes in src/ (it resets to $NODE_VERSION).
  -p, --patch                 Only apply patches to already-downloaded sources, then exit; needs no arch.
                              Patches that are already applied are skipped.
  -s, --sync                  Re-sync existing sources before building (same reset as -d).
                              Without an arch it just syncs, then exits.
  --clean                     Removes build artifacts from out dir (only <arch>'s, if given).
  --debug                     Make a debug build (no installer).

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

apply_series() {
  local dir="$1"
  local series="$PATCHES_PATH/series"
  local applied=0 skipped=0
  # Same leniency upstream's apply_patches.bat used.
  local flags=(--ignore-space-change --whitespace=nowarn)

  if [ ! -f "$series" ]; then
    log "${YEL} No %s, nothing to apply${c0}\n" "$series"
    return 0
  fi
  [ -d "$dir" ] || error_exit "Patch target '$dir' doesn't exist; are sources downloaded?"

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
  execute "" "Unable to clean Node" git -C "$NODE_PATH" clean -fd
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
    local flags=("$ARCH" full-icu download-all no-cctest clang-cl ltcg)
    [ "$DO_PACKAGE" = true ] && flags+=(msi)
    vcbuild "${flags[@]}"
  fi
}

package() {
  # vcbuild writes node-v<version>-<arch>.msi into the checkout root.
  local msi="$NODE_PATH/node-${NODE_VERSION}-${ARCH}.msi"
  [ -f "$msi" ] || error_exit "No installer at $msi; was this a release build?"
  create_dir "$DIST_PATH"
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
  # LTO and PGO compile with clang's -flto/-fprofile-*, which cl.exe rejects.
  log "${CYA} Note: ltcg needs the ClangCL toolset installed in Visual Studio.${c0}\n"
  if [ "$ARCH" = x86 ] && [ "$DO_PACKAGE" = true ]; then
    error_exit "Node's MSI project only defines x64 and ARM64; there is no x86 installer"
  fi
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
    [ "$ONLY_DOWNLOAD" = true ] && fetch_sources
    [ "$ONLY_PATCH" = true ] && apply_patches
    exit 0
  fi

  [ -n "$ARCH" ] || arg_error "No architecture given"
  check_prereqs

  if [ "$DO_SYNC" = true ] || [ ! -d "$NODE_PATH/.git" ]; then
    fetch_sources
  fi
  apply_patches
  build_node
  [ "$DO_PACKAGE" = true ] && package
  log "${GRE}${bold} Done. node.exe is in %s${c0}\n" "$NODE_PATH/out"
}

main "$@"
