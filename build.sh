#!/usr/bin/env bash

# Copyright (c) 2026 Alex313031

# Fetch, patch, build and package Electron for legacy Windows.
# Currently runs on Windows under Git Bash. -d/-p also work on Linux, so
# patches can be developed there; building from Linux (cross-compiling with a
# packaged Visual Studio toolchain, like Chromium does) is planned, see TODO.md.

set -u -o pipefail

SCRIPTNAME=$(basename "$0")
SCRIPTVER="1.3.4"

export HERE=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Electron release the patches in patches/ are made for.
ELECTRON_VERSION="44.11.1"

# The gclient root: .gclient and the state files beside it (.gclient_entries,
# .cipd/, .gcs_entries), plus src/, dist/ and build.log. Kept in a subdirectory
# so the repo itself stays clean; gclient has no way to put that state anywhere
# but next to .gclient, and .gclient cannot live in src/ because both Electron's
# and Chromium's DEPS declare their paths as src/... relative to this directory.
# Override with e.g. `ROOT_PATH=/c/el ./build.sh x64` for a short path on Windows.
ROOT_PATH="${ROOT_PATH:-$HERE/checkout}"

# Where to clone Electron sources
SRC_PATH="$ROOT_PATH/src"
ELECTRON_PATH="$SRC_PATH/electron"

# Patch series to apply on top of the checkout
PATCHES_PATH="$HERE/patches"

# GN args per build config: <release|debug>_<x64|x86>.gn
ARGS_PATH="$HERE/assets/args"

# Log file from this script (NOT Ninja/Siso log files)
LOG_FILE="$ROOT_PATH/build.log"

# Where to put finalized distribution .zips
DIST_PATH="$ROOT_PATH/dist"

# Where --npm assembles the `electron` npm package. Unlike dist/ this lives in
# the repo, not under ROOT_PATH: it is a handful of small files meant to be
# committed and tagged, not build output.
NPM_PATH="$HERE/npm_package"

# Files --npm takes from this repo rather than from the checkout.
NPM_ASSETS="$HERE/assets/npm"

# Set Electron source URL
ELECTRON_URL="https://github.com/electron/electron.git"

# Where to clone depot_tools from, usually leave this alone.
DEPOT_TOOLS_URL="https://chromium.googlesource.com/chromium/tools/depot_tools.git"
# Where depot_tools lives if it isn't already on $PATH.
DEPOT_TOOLS_PATH="${DEPOT_TOOLS_PATH:-$HOME/depot_tools}"

# Max parallel git operations during gclient sync. gclient's own default is
# max(8, CPUs), far too many on big build servers. Override with SYNC_JOBS=N.
MAX_SYNC_JOBS=8

# Electron's gclient hooks run yarn under Node.js; this is its documented minimum.
MIN_NODE_VERSION="22.12.0"

# Chromium's build scripts use syntax that needs this (PEP 604 "X | Y" in
# evaluated annotations is 3.10+); depot_tools ships 3.11, so prefer that over
# whatever Python the host happens to have.
MIN_PYTHON_VERSION="3.11"

# Controls minimum Windows target, (unused currently)
WIN32_WINNT="0x0600"

# Don't auto update depot_tools
export DEPOT_TOOLS_UPDATE=0

# Parts of the build run Go toolchains they ship themselves -- dawn's source
# generator uses third_party/dawn/tools/golang/<platform>/bin/go. GOROOT in the
# environment overrides the GOROOT that binary was built with, so it ends up
# running its own `go` against another installation's standard library and
# tools, and fails with e.g.
#   compile: version "go1.26.4" does not match go tool version "go1.25.0"
# Unset both so each bundled toolchain uses its own, and module/build caches
# land in the default per-user location rather than a GOPATH shared with
# whatever Go the host has installed.
unset GOROOT GOPATH

# Python picks its stdio encoding from the locale, which on Windows is a legacy
# code page (cp1252 on an English install) rather than UTF-8. Electron's
# apply_all_patches.py hook echoes whatever `git am` prints, and `git am` prints
# each patch's subject -- decoded, so an RFC 2047 encoded header in an
# ASCII-looking patch file still yields non-ASCII output. Electron 44 ships one:
# patches/chromium/cherry-pick-69403d85b78b.patch, whose subject separates
# "PowerMonitorDeviceSource" from "Handle IORegisterForSystemPower failure" with
# a fullwidth colon (U+FF1A). Printing it raises UnicodeEncodeError, which
# script/lib/git.py does not catch (it guards only BrokenPipeError), so the hook
# dies and takes the whole gclient sync with it. The patch files themselves are
# read as UTF-8 and fed to git as UTF-8, so stdio is the only locale-dependent
# step; UTF-8 can encode anything, and the next upstream subject with a
# non-Latin-1 character would hit this again, so set it everywhere rather than
# just on Windows.
export PYTHONIOENCODING="${PYTHONIOENCODING:-utf-8}"

# Custom Ninja status line.
export NINJA_SUMMARIZE_BUILD=1
export NINJA_STATUS="[%r processes, %f/%t @ %o/s | %e sec. ] "

# Whatever SISO_LIMITS the caller set, kept so -j can be folded into it
# without stacking up over the several builds a single run can do.
SISO_LIMITS_BASE="${SISO_LIMITS:-}"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) HOST_OS=windows ;;
  Linux*) HOST_OS=linux ;;
  *) HOST_OS=unsupported ;;
esac

# For host executables we look for by name, e.g. ninja.
if [ "$HOST_OS" = windows ]; then
  EXE_SUFFIX=".exe"
else
  EXE_SUFFIX=""
fi

# A Windows host builds with its locally installed Visual Studio, so 0. A Linux
# host has no local VS and must use a packaged toolchain, so 1: with 0,
# vs_toolchain.py's `update` hook silently does nothing, no
# src/build/win_toolchain.json is written, and gn then dies in
# SetEnvironmentAndGetSDKDir with KeyError: 'WINDOWSSDKDIR'. Cross-building also
# needs DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL (dir holding <zip hash>.zip) and
# GYP_MSVS_HASH_<toolchain hash>=<zip hash>; see --help.
if [ "$HOST_OS" = linux ]; then
  export DEPOT_TOOLS_WIN_TOOLCHAIN="${DEPOT_TOOLS_WIN_TOOLCHAIN:-1}"
else
  export DEPOT_TOOLS_WIN_TOOLCHAIN="${DEPOT_TOOLS_WIN_TOOLCHAIN:-0}"
fi

# Options, set by parse_args
ARCH=""
VERBOSE=0
JOBS=""
IS_DEBUG=false
IS_XP=false
DO_DEPS=false
DO_PACKAGE=false
DO_NPM=false
DO_CLEAN=false
DO_SYNC=false
DO_RESET=false
ONLY_DOWNLOAD=false
ONLY_PATCH=false
BUILD_ONLY=false
KEEP_GOING=false
SHALLOW=true

# Patches that apply_series could not apply, collected under --keep-going.
FAILED_PATCHES=()
EXTRA_GN_ARGS=()

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

Builds Electron v$ELECTRON_VERSION for legacy Windows. With an arch, this
downloads sources (first run only), applies patches, then builds.

Archs:
  x86 | x64 - Select 32 or 64 bit build

Options:
  -h, --help                  Show this help.
  -v, --verbose               Verbose output (always on for the build step).
  --version                   Show script version.
  --deps                      Install depot_tools, set git config Chromium
                              needs, and check for Visual Studio and Node.js.
  -j <count>, --jobs <count>  Local job count (default: one per CPU)
                              Passed as -j, plus SISO_LIMITS when Siso drives
                              the build. Without it autoninja picks CPUs + 2.
  --package                   Package built binaries into dist/ for distribution.
  --npm                       Assemble the electron npm package into npm_package/
                              from the patched src/electron/npm sources and what
                              --package left in dist/. Needs no arch; run it
                              after --package.
  -d, --download-sources      Only download sources, then exit; for making local modifications.
                              Discards any local changes in src/ (it resets to v$ELECTRON_VERSION).
  -p, --patch                 Only apply patches to already-downloaded sources, then exit; needs no arch.
                              Patches that are already applied are skipped.
  -k, --keep-going            Don't stop the patch step at the first patch that
                              doesn't apply: skip it, carry on, and list every
                              failure at the end. For rebasing the series onto a
                              new Electron release in one pass instead of one
                              round trip per broken patch. Still fails at the
                              end, and writes no stamp.
  -s, --sync                  Re-sync existing sources before building (same reset as -d).
                              Without an arch it just syncs, then exits.
  -r, --reset                 Put src/ back to stock -- synced sources with
                              Electron's own patches and none of ours -- without
                              re-cloning or re-syncing. Seconds, not the hour a
                              sync costs. Combine with -p to reset and re-apply
                              the series in one go, which is the loop for
                              rebasing onto a new release.
  -b, --build-only            Build src/ exactly as it is: skip syncing and the
                              patch series entirely, go straight to gn gen and
                              the build. For iterating on experimental changes
                              made directly in the checkout.
  --full-history              Download full git history (default: none, which is far
                              smaller and faster). Only affects repos not yet cloned.
  --gn-args "<args>"          Extra GN args, e.g. --gn-args 'symbol_level=0'. Repeatable.
  --clean                     Removes build artifacts from out dir (only <arch>'s, if given).
  --debug                     Make an unoptimized, full symbol debug build.
  --xp                        Build for Windows XP/Vista: uses
                              assets/args/xp_<arch>.gn instead of release_<arch>.gn,
                              which turns on winwrap (see third_party/winwrap).
                              Its own out dir, out/XP-<arch>, so switching
                              between an XP and a normal build stays
                              incremental instead of relinking everything.

Environment:
  ROOT_PATH          Where .gclient, src/, dist/ and build.log go
                     (default: $HERE/checkout)
  SYNC_JOBS          Parallel git operations for gclient sync (default: CPUs, max $MAX_SYNC_JOBS)
  NINJA_BIN          The ninja to build with. Default: the one autoninja would
                     use, i.e. src/third_party/ninja/ninja. Set this to use
                     your own build; autoninja offers no way to, as it never
                     looks on PATH for ninja. Keep it the same for a given out
                     dir -- a ninja that meets another version's build log
                     discards it, which rebuilds the whole tree.
  SISO_LIMITS        Extra Siso resource limits; -j appends local=<count> to it
                     (only when Siso, not Ninja, drives the build)
  DEPOT_TOOLS_PATH   depot_tools location if not on PATH (default: \$HOME/depot_tools)
  vs2022_install     Visual Studio path, if not installed in the default location
  WINDOWSSDKDIR      Windows SDK path, if not installed in the default location

Cross-building from Linux (experimental) uses Chromium's packaged Visual Studio
instead of a local one, and needs both of:
  DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL
                     Directory (or URL) holding the toolchain <zip hash>.zip
  GYP_MSVS_HASH_<toolchain hash>=<zip hash>
                     Maps the toolchain Chromium pins to that zip. The script
                     prints the hash it wants if this is missing.

For more details about building Electron, see
https://www.electronjs.org/docs/latest/development/build-instructions-gn

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

# Run a depot_tools command. On Windows use the .bat wrappers; depot_tools'
# extensionless shell wrappers don't support Git Bash.
dt() {
  local tool="$1"
  shift
  if [ "$HOST_OS" = windows ]; then
    "$DEPOT_TOOLS_PATH/$tool.bat" "$@"
  else
    "$DEPOT_TOOLS_PATH/$tool" "$@"
  fi
}

# Run Python: depot_tools' bundled python3 on Windows, the system one elsewhere.
py() {
  if [ "$HOST_OS" = windows ]; then
    dt python3 "$@"
  else
    python3 "$@"
  fi
}

# Run gn. Prefers the binary DEPS pins in buildtools/, which is version-matched
# to this checkout; depot_tools' gn is just whatever is installed there, and a
# gn older than the checkout rejects newer constructs (e.g. public_inputs in
# devtools-frontend's copy.gni, which needs gn 2486+). Override with GN=<path>.
gn() {
  local bin="${GN:-}"
  if [ -z "$bin" ]; then
    case "$HOST_OS" in
      windows) bin="$SRC_PATH/buildtools/win/gn.exe" ;;
      *)       bin="$SRC_PATH/buildtools/linux64/gn" ;;
    esac
    [ -x "$bin" ] || bin=""
  fi
  if [ -n "$bin" ]; then
    "$bin" "$@"
  else
    dt gn "$@"
  fi
}

cpu_count() {
  printf '%s\n' "$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)"
}

version_ge() {
  # True if version $1 >= $2.
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
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
      --deps) DO_DEPS=true ;;
      -j|--jobs)
        [ $# -ge 2 ] || arg_error "$1 needs a job count"
        JOBS="$2"; shift ;;
      -j*) JOBS="${1#-j}" ;;
      --package) DO_PACKAGE=true ;;
      --npm) DO_NPM=true ;;
      -d|--download-sources) ONLY_DOWNLOAD=true ;;
      -p|--patch) ONLY_PATCH=true ;;
      -s|--sync) DO_SYNC=true ;;
      -r|--reset) DO_RESET=true ;;
      -b|--build-only) BUILD_ONLY=true ;;
      -k|--keep-going) KEEP_GOING=true ;;
      --full-history) SHALLOW=false ;;
      --gn-args)
        [ $# -ge 2 ] || arg_error "$1 needs a value"
        EXTRA_GN_ARGS+=("$2"); shift ;;
      --clean) DO_CLEAN=true ;;
      --debug) IS_DEBUG=true ;;
      --xp) IS_XP=true ;;
      *) arg_error "Unknown option '$1'" ;;
    esac
    shift
  done

  if [ -n "$JOBS" ] && ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    arg_error "Invalid job count '$JOBS'"
  fi
  # Always set, so the build step can report it and autoninja never has to
  # decide between a count and the build tool's own default.
  JOBS="${JOBS:-$(cpu_count)}"

  # --package reads the arch's out dir and names its zips after the arch, so
  # it is the one action that can't run without one. Checked here so it fails
  # outright instead of being silently dropped by a sync-only run below.
  if [ "$DO_PACKAGE" = true ] && [ -z "$ARCH" ]; then
    arg_error "--package needs an architecture"
  fi

  # --build-only is "build what is in src/ right now", so it contradicts every
  # flag whose job is to change what's in there, and it has nothing to build
  # without an arch.
  # -d and --sync both reset the checkout on their way through, so --reset
  # alongside them is asking for the same thing twice; say so rather than
  # silently doing nothing. --build-only is the opposite instruction.
  # --xp selects a different args file and a different out dir, so it cannot
  # also be the debug config: xp_<arch>.gn is the whole configuration, and
  # there is no xp-debug args file to fall back to.
  if [ "$IS_XP" = true ] && [ "$IS_DEBUG" = true ]; then
    arg_error "--xp and --debug select different args files; pick one"
  fi

  if [ "$DO_RESET" = true ]; then
    if [ "$ONLY_DOWNLOAD" = true ] || [ "$DO_SYNC" = true ]; then
      arg_error "--reset is redundant with -d and --sync, which already reset the checkout"
    fi
    if [ "$BUILD_ONLY" = true ]; then
      arg_error "--reset can't be combined with --build-only"
    fi
  fi

  if [ "$BUILD_ONLY" = true ]; then
    if [ "$ONLY_DOWNLOAD" = true ] || [ "$ONLY_PATCH" = true ] || [ "$DO_SYNC" = true ]; then
      arg_error "--build-only can't be combined with -d, -p or --sync"
    fi
    if [ -z "$ARCH" ]; then
      arg_error "--build-only needs an architecture"
    fi
  fi

  # Syncing doesn't depend on the architecture, so --sync without one is a
  # sync-only run rather than an error: the same thing -d does.
  if [ "$DO_SYNC" = true ] && [ -z "$ARCH" ]; then
    ONLY_DOWNLOAD=true
  fi
}

init_log() {
  mkdir -p "$ROOT_PATH" || error_exit "Unable to create '$ROOT_PATH'"
  # Make ROOT_PATH absolute (it may come from the environment), then rederive.
  ROOT_PATH=$(cd -- "$ROOT_PATH" && pwd)
  SRC_PATH="$ROOT_PATH/src"
  ELECTRON_PATH="$SRC_PATH/electron"
  LOG_FILE="$ROOT_PATH/build.log"
  DIST_PATH="$ROOT_PATH/dist"
  printf '\n==== %s: %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$SCRIPTNAME" "$*" >> "$LOG_FILE"
}

check_node() {
  command -v node >/dev/null 2>&1 \
    || error_exit "Node.js >= $MIN_NODE_VERSION is required (Electron's gclient hooks use it), see https://nodejs.org"
  local v
  v=$(node --version | sed 's/^v//')
  version_ge "$v" "$MIN_NODE_VERSION" \
    || error_exit "Node.js $v is too old, Electron needs >= $MIN_NODE_VERSION"
}

check_python() {
  # Checks the Python the build will actually run, which is not necessarily the
  # one this shell finds: on Windows depot_tools ships python3.bat, and Git
  # Bash won't resolve a .bat for the bare name "python3", so `command -v
  # python3` walks past depot_tools to any system Python. gn does look for both
  # python3.exe and python3.bat (see src/.gn), so with depot_tools first on
  # PATH -- which clone_depot_tools now guarantees -- gn picks depot_tools'.
  # py() resolves the same way, so ask it.
  local v
  v=$(py -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null) \
    || error_exit "Unable to run python3; depot_tools ships one, run '$SCRIPTNAME --deps'"
  version_ge "$v" "$MIN_PYTHON_VERSION" \
    || error_exit "python3 is $v, Chromium's build scripts need >= $MIN_PYTHON_VERSION; depot_tools ships one, so check that $DEPOT_TOOLS_PATH comes first on PATH"
}

find_visual_studio() {
  # Prints the Visual Studio install path, if one with the C++ tools is found.
  if [ -n "${vs2022_install:-}" ]; then
    printf '%s\n' "$vs2022_install"
    return 0
  fi
  local vswhere="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
  [ -x "$vswhere" ] || return 1
  local path
  path=$("$vswhere" -latest -products '*' \
      -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
      -property installationPath 2>/dev/null | tr -d '\r')
  [ -n "$path" ] && printf '%s\n' "$path"
}

clone_depot_tools() {
  # Ensure depot_tools is available in path and abort if found, otherwise clone in $HOME
  # and add to $PATH.
  local found
  if found=$(command -v gclient 2>/dev/null); then
    DEPOT_TOOLS_PATH=$(dirname "$found")
    log "${GRE} Using depot_tools from %s${c0}\n" "$DEPOT_TOOLS_PATH"
  else
    if [ ! -d "$DEPOT_TOOLS_PATH/.git" ]; then
      if [ "$DO_DEPS" != true ]; then
        error_exit "depot_tools not found on PATH or in $DEPOT_TOOLS_PATH, run '$SCRIPTNAME --deps' first"
      fi
      execute "Cloning depot_tools into $DEPOT_TOOLS_PATH" "Unable to clone depot_tools" \
          git clone "$DEPOT_TOOLS_URL" "$DEPOT_TOOLS_PATH"
    fi
  fi
  # Always first, even when it was already on PATH: src/.gn sets
  # script_executable = "python3", which gn resolves from PATH at `gn gen` time
  # and bakes into build.ninja as an absolute path. Another Python earlier on
  # PATH (a system C:\Python39, say) then runs every action in the build, and
  # Chromium's scripts need the Python depot_tools ships -- e.g.
  # tools/metrics/histograms/extract_histograms.py annotates with PEP 604
  # "X | Y" unions, which are evaluated at import and need 3.10+.
  export PATH="$DEPOT_TOOLS_PATH:$PATH"
  if [ "$HOST_OS" = windows ] && [ ! -e "$DEPOT_TOOLS_PATH/python3.bat" ]; then
    # First run of a depot_tools command on Windows downloads its Python & Git.
    execute "Bootstrapping depot_tools" "Unable to bootstrap depot_tools" \
        dt gclient --version
  fi
}

install_deps() {
  # Install what can be installed, check what can't (Visual Studio).
  clone_depot_tools

  if [ "$HOST_OS" = windows ]; then
    # Settings from Chromium's Windows build instructions.
    log "${CYA} Setting global git config for Chromium checkouts${c0}\n"
    local kv
    for kv in core.autocrlf=false core.filemode=false core.longpaths=true \
              core.fscache=true core.preloadindex=true branch.autosetuprebase=always; do
      execute "" "Unable to set git config ${kv%%=*}" \
          git config --global "${kv%%=*}" "${kv#*=}"
    done

    local vs
    if vs=$(find_visual_studio); then
      log "${GRE} Found Visual Studio at %s${c0}\n" "$vs"
    else
      warn "Visual Studio 2022 with the C++ desktop workload was not found. Install it (see Chromium's Windows build docs), or set vs2022_install."
    fi
    [ -d "/c/Program Files (x86)/Windows Kits/10/Debuggers" ] \
      || warn "Windows SDK 'Debugging Tools for Windows' not found; they are needed for symbol/PDB packaging."
    warn "Exclude $ROOT_PATH from Windows Security scanning, or it may delete files during sync (crbug.com/441184)."
  fi

  check_node
  log "${GRE} Prerequisites OK.${c0}\n"
}

win_toolchain_hash() {
  # The VS toolchain package Chromium currently pins. It changes with every
  # toolchain roll, so read it rather than hardcoding it. Needs sources.
  sed -nE "s/^TOOLCHAIN_HASH[[:space:]]*=[[:space:]]*'([^']+)'.*/\1/p" \
      "$SRC_PATH/build/vs_toolchain.py" 2>/dev/null | head -n1
}

check_cross_toolchain() {
  # What a Linux host needs before it can target Windows. Checked here, which
  # runs before the sources exist; the pinned-hash half is in
  # check_cross_toolchain_pinned below.
  [ "$DEPOT_TOOLS_WIN_TOOLCHAIN" != 0 ] \
    || error_exit "Cross-building needs DEPOT_TOOLS_WIN_TOOLCHAIN unset or 1; 0 means 'use a local Visual Studio', which this host hasn't got"

  local base="${DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL:-}"
  [ -n "$base" ] \
    || error_exit "Set DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL to the directory holding the toolchain <zip hash>.zip"
  # Only a local directory is checkable; a real URL is gclient's problem.
  case "$base" in
    http://*|https://*|gs://*) ;;
    *)
      [ -d "$base" ] \
        || error_exit "DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL '$base' is not a directory"
      ls "$base"/*.zip >/dev/null 2>&1 \
        || error_exit "No toolchain .zip in '$base'"
      ;;
  esac

  # The Windows SDK needs a case-insensitive filesystem, which vs_toolchain.py
  # arranges with a ciopfs FUSE mount over win_toolchain/vs_files.
  command -v fusermount >/dev/null 2>&1 || command -v fusermount3 >/dev/null 2>&1 \
    || error_exit "fusermount not found; the Windows SDK is unpacked onto a ciopfs FUSE mount"

  warn "Cross-building Windows binaries on Linux is experimental, see TODO.md."
}

check_cross_toolchain_pinned() {
  # Run once the checkout exists: confirm the zip for the pinned toolchain is
  # mapped and present, and unpack it if the gclient hook hasn't.
  local hash zip var
  hash=$(win_toolchain_hash)
  [ -n "$hash" ] \
    || error_exit "Could not read TOOLCHAIN_HASH from $SRC_PATH/build/vs_toolchain.py"

  var="GYP_MSVS_HASH_$hash"
  zip="${!var:-}"
  [ -n "$zip" ] \
    || error_exit "Chromium pins VS toolchain $hash; export $var=<zip hash> (the <zip hash>.zip in \$DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL)"

  local base="$DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL"
  case "$base" in
    http://*|https://*|gs://*) ;;
    *) [ -f "$base/$zip.zip" ] \
         || error_exit "$var=$zip but '$base/$zip.zip' does not exist" ;;
  esac

  # Written by vs_toolchain.py once the zip is unpacked. Without it gn dies in
  # SetEnvironmentAndGetSDKDir with KeyError: 'WINDOWSSDKDIR'.
  if [ ! -f "$SRC_PATH/build/win_toolchain.json" ]; then
    execute "Unpacking VS toolchain $zip (this takes a while)" \
        "Unable to unpack the VS toolchain" \
        py "$SRC_PATH/build/vs_toolchain.py" update --force
  fi
  log "${GRE} Using packaged VS toolchain %s for Chromium's %s${c0}\n" "$zip" "$hash"
}

setup_toolchain() {
  # Make sure we can target Windows from this host before running gn/siso.
  case "$HOST_OS" in
    windows)
      find_visual_studio >/dev/null \
        || error_exit "Visual Studio 2022 with C++ tools not found, see '$SCRIPTNAME --deps'"
      ;;
    linux)
      # Cross-build: there is no local Visual Studio to find, so Chromium's
      # packaged VS+SDK zip stands in for one. Still experimental, see TODO.md.
      check_cross_toolchain
      ;;
    *)
      error_exit "Unsupported host OS '$(uname -s)'"
      ;;
  esac
}

sync_jobs() {
  # One job per CPU, capped at MAX_SYNC_JOBS (SYNC_JOBS overrides). Shared by
  # gclient sync.
  local cpus jobs
  cpus=$(cpu_count)
  jobs=$(( cpus < MAX_SYNC_JOBS ? cpus : MAX_SYNC_JOBS ))
  jobs="${SYNC_JOBS:-$jobs}"
  [[ "$jobs" =~ ^[1-9][0-9]*$ ]] || error_exit "Invalid SYNC_JOBS '$jobs'"
  printf '%s\n' "$jobs"
}

reset_sources() {
  # Put the checkout back to stock -- the synced sources with Electron's own
  # patches applied and none of ours -- without touching the network, so the
  # series can be tried again from the top. Seconds, against the hour-plus a
  # re-sync costs.
  #
  # Deliberately not `gclient revert`: that fetches, resets every dependency to
  # whatever .gclient_entries recorded rather than what is checked out, and
  # aborts anyway because a checkout would overwrite the untracked nested
  # checkouts inside src (third_party/aria-practices and friends). The reasoning
  # for what tools/reset_sources.py does instead is in its docstring.
  [ -d "$ELECTRON_PATH/.git" ] \
      || error_exit "No sources in $SRC_PATH, run '$SCRIPTNAME -d' first"

  VERBOSE=1 execute "Resetting $SRC_PATH to stock (v$ELECTRON_VERSION)" "Unable to reset the checkout" \
      py "$HERE/tools/reset_sources.py" \
      --patches "$PATCHES_PATH" \
      --series "chromium=$SRC_PATH" \
      --series "electron=$ELECTRON_PATH" \
      --series "node=$SRC_PATH/third_party/electron_node" \
      --series "other=$SRC_PATH"

  # Nothing of ours is applied now, whatever the stamp said.
  rm -f "$(patches_stamp)"
  log "${GRE} %s is back to stock${c0}\n" "$SRC_PATH"
}

fetch_sources() {
  # Fetches and syncs down Electron sources in src/
  check_node
  if [ "$HOST_OS" = windows ] && [[ "$ROOT_PATH" == *" "* ]]; then
    error_exit "ROOT_PATH '$ROOT_PATH' contains spaces, which Chromium's build doesn't support"
  fi

  # Electron's mtime cache keeps the timestamps of files its patches touch
  # across re-syncs, so they don't all rebuild. A first sync has nothing to
  # keep, and the cache's pre-sync hook would just print "Skipping
  # non-existent file" for every one of them.
  local use_mtime_cache=False
  [ -d "$ELECTRON_PATH" ] && use_mtime_cache=True

  # target_os picks which of Chromium's per-platform DEPS get checked out. A
  # Windows host wants only "win": adding "linux" sets checkout_linux, which
  # pulls the Debian sysroots, the Wayland/mutter deps, and
  # src/third_party/jdk/current. That last one is a Linux JDK whose CIPD
  # package holds symlinks, and unpacking those on Windows fails with "A
  # required privilege is not held by the client" unless the shell holds
  # SeCreateSymbolicLinkPrivilege. Cross-building from Linux needs both, since
  # the host tools it runs are built for linux.
  local target_os='[ "win" ]'
  [ "$HOST_OS" = linux ] && target_os='[ "linux", "win" ]'

  # Written by us (instead of `gclient config`) so it can carry target_os,
  # which cross-building from Linux will need.
  cat > "$ROOT_PATH/.gclient" <<EOF
solutions = [
  {
    "name": "src/electron",
    "url": "$ELECTRON_URL",
    "deps_file": "DEPS",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {
      # Chromium's switch to skip deps only its own bots need (benchmarks,
      # MSan libraries); these vars flow down into Chromium's DEPS.
      "checkout_configuration": "small",
      # node_modules for post-processing V8 coverage reports.
      "checkout_js_coverage_modules": False,
      "use_mtime_cache": $use_mtime_cache
    },
  },
]
target_os = $target_os
EOF

  if [ -d "$SRC_PATH" ]; then
    warn "Syncing resets $SRC_PATH to Electron v$ELECTRON_VERSION, discarding local changes."
  fi
  # --reset throws our patches away, so the tree is unpatched after this.
  rm -f "$(patches_stamp)"

  # Deliberately no --delete_unversioned_trees. src/electron is the solution,
  # but it also sits *inside* src/, where Chromium's DEPS knows nothing about
  # it -- so pruning unversioned trees while syncing src deletes the Electron
  # checkout. gclient syncs the solution first, so by the time src is pruned
  # src/electron's turn has passed and nothing recreates it; the sync then dies
  # in the hooks stage with
  #   can't open file 'src/electron/script/apply_all_patches.py'
  # after however long the Chromium fetch took. (Electron's own sibling deps --
  # third_party/electron_node, nan, squirrel.mac -- survive it, because they are
  # fetched after src and so get recreated.) A first sync never hits this:
  # nothing exists to prune yet. Electron's own build-tools doesn't pass the
  # flag either, and all it buys is pruning deps that upstream dropped between
  # versions, which is a disk-space concern, not a correctness one.
  local flags=(sync --force --reset
               --revision "src/electron@refs/tags/v$ELECTRON_VERSION")
  if [ "$SHALLOW" = true ]; then
    # Depth-1 fetch of exactly the pinned revision of every repo. Skips
    # --with_branch_heads/--with_tags, which pull every Chromium release ref.
    flags+=(--no-history)
  else
    flags+=(--with_branch_heads --with_tags)
  fi

  # gclient's --no-history path fetches with neither --progress nor a tty,
  # unlike the `clone --progress` it uses otherwise, so git says nothing for
  # the whole Chromium fetch and gclient's own stall detector cries wolf after
  # five minutes. --verbose is what makes that fetch report progress.
  [ "$VERBOSE" = 1 ] && flags+=(--verbose)

  flags+=(--jobs "$(sync_jobs)")

  cd "$ROOT_PATH" || error_exit "Unable to enter $ROOT_PATH"
  VERBOSE=1 execute "Syncing Electron v$ELECTRON_VERSION sources into $SRC_PATH (this takes a long time)" \
      "gclient sync failed" dt gclient "${flags[@]}"

  # --reset reverts tracked modifications but leaves untracked files alone, and
  # without --delete_unversioned_trees (see above) gclient no longer prunes them
  # either -- so the ~400 files our series *creates* survive the sync, and the
  # next apply dies on the first of them with "already exists in working
  # directory". reset_sources removes exactly those, by name, out of the
  # patches. Cheap, local, and it makes "synced" mean "stock".
  reset_sources
}

apply_series() {
  # Apply patches/<name>/series in <dir>. Skips patches that are already
  # applied (reverse-applies cleanly), so this is safe to re-run.
  local name="$1"
  local dir="$2"
  local series="$PATCHES_PATH/$name/series"
  local applied=0 skipped=0
  # Same leniency upstream's apply_patches.bat used.
  local flags=(--ignore-space-change --whitespace=nowarn)

  if [ ! -f "$series" ]; then
    log "${YEL} No patches/%s/series, skipping${c0}\n" "$name"
    return 0
  fi
  [ -d "$dir" ] || error_exit "Patch target '$dir' for $name/ doesn't exist; are sources downloaded?"

  log "${CYA} Applying %s patches in %s${c0}\n" "$name" "$dir"
  local p file
  while IFS= read -r p || [ -n "$p" ]; do
    p="${p%$'\r'}"
    [[ -z "$p" || "$p" == \#* ]] && continue
    file="$PATCHES_PATH/$name/$p"
    [ -f "$file" ] || error_exit "patches/$name/series lists '$p', which doesn't exist"

    if git -C "$dir" apply --check "${flags[@]}" "$file" >/dev/null 2>&1; then
      execute "" "Failed to apply $name/$p" git -C "$dir" apply "${flags[@]}" "$file"
      [ "$VERBOSE" == "1" ] && log "   applied %s\n" "$p"
      applied=$((applied + 1))
    elif git -C "$dir" apply --reverse --check "${flags[@]}" "$file" >/dev/null 2>&1; then
      [ "$VERBOSE" == "1" ] && log "   already applied %s\n" "$p"
      skipped=$((skipped + 1))
    else
      git -C "$dir" apply --check --verbose "${flags[@]}" "$file" >>"$LOG_FILE" 2>&1
      if [ "$KEEP_GOING" = true ]; then
        warn "does not apply, skipping: $name/$p"
        FAILED_PATCHES+=("$name/$p")
        continue
      fi
      error_exit "Patch $name/$p does not apply ($applied applied so far), check $LOG_FILE for details."
    fi
  done < "$series"
  log "${GRE} %s: %d applied, %d already applied${c0}\n" "$name" "$applied" "$skipped"
}

patches_stamp() {
  printf '%s\n' "$ROOT_PATH/.patches-applied"
}

patches_digest() {
  # Fingerprint of everything apply_patches would apply, so the stamp stops
  # matching as soon as a series or any patch file changes.
  local name p
  {
    for name in chromium electron node other; do
      local series="$PATCHES_PATH/$name/series"
      [ -f "$series" ] || continue
      printf '== %s\n' "$name"
      cat "$series"
      while IFS= read -r p || [ -n "$p" ]; do
        p="${p%$'\r'}"
        [[ -z "$p" || "$p" == \#* ]] && continue
        [ -f "$PATCHES_PATH/$name/$p" ] && cat "$PATCHES_PATH/$name/$p"
      done < "$series"
    done
  } | { sha256sum 2>/dev/null || cksum; } | cut -d' ' -f1
}

patches_are_applied() {
  # True if this exact patch set was already applied to this checkout. Lets a
  # build after -d/-p skip the series: re-running it costs a couple of git
  # invocations per patch across 300+ patches, and a patch that a later one
  # overlaps may no longer reverse-apply cleanly once the whole series is in,
  # which apply_series can only treat as a failure.
  local stamp
  stamp=$(patches_stamp)
  [ -f "$stamp" ] || return 1
  [ "$(cat "$stamp")" = "$(patches_digest)" ]
}

check_source_version() {
  # The checkout has to be at the release ELECTRON_VERSION names, and not only
  # because that is what the patches were written against: it also becomes
  # override_electron_version and the dist/ and npm package names. A checkout
  # at some other tag would build fine and be labelled as this version, which
  # is worse than failing, because it looks like a correct build.
  #
  # Deliberately not inside apply_patches: the patch stamp covers patches/ and
  # not the version, so bumping ELECTRON_VERSION without --sync leaves a stamp
  # that still matches, apply_patches never runs, and nothing else would look.
  [ -d "$ELECTRON_PATH/.git" ] || return 0

  # Electron's package.json always says 0.0.0-development, so go by the tag --
  # and compare HEAD against the tag's commit rather than asking what tag HEAD
  # is at. `describe --exact-match` only answers the latter, so it says nothing
  # when HEAD is at an untagged commit, which is precisely the case worth
  # catching: a re-cloned src/electron sits on main, 30k commits from the
  # release, and gclient reads its DEPS from there.
  local tag head
  tag=$(git -C "$ELECTRON_PATH" rev-parse -q --verify "refs/tags/v$ELECTRON_VERSION^{commit}" 2>/dev/null) || tag=""

  if [ -z "$tag" ]; then
    # The tag isn't fetched, which a --no-history checkout need not have.
    # Absence is not proof of a mismatch, so don't claim one.
    warn "src/electron has no v$ELECTRON_VERSION tag to compare against; can't confirm the checkout."
    return 0
  fi

  head=$(git -C "$ELECTRON_PATH" rev-parse HEAD)
  [ "$head" = "$tag" ] && return 0

  local at
  at=$(git -C "$ELECTRON_PATH" describe --tags --always HEAD 2>/dev/null) || at="$head"
  error_exit "src/electron is at $at, not v$ELECTRON_VERSION, so its DEPS and patch targets are the wrong ones and this build would still be labelled v$ELECTRON_VERSION. Put it on the tag (git -C $ELECTRON_PATH checkout --detach v$ELECTRON_VERSION) and re-run with --sync."
}

apply_patches() {
  [ -d "$ELECTRON_PATH" ] || error_exit "No sources in $SRC_PATH, run '$SCRIPTNAME -d' first"

  apply_series chromium "$SRC_PATH"
  apply_series electron "$ELECTRON_PATH"
  apply_series node "$SRC_PATH/third_party/electron_node"
  apply_series other "$SRC_PATH"

  # With --keep-going the series ran to the end over the failures; say what they
  # all were and stop, rather than building a half-patched tree. No stamp
  # either: nothing here was fully applied.
  if [ ${#FAILED_PATCHES[@]} -gt 0 ]; then
    log "${RED} %d patches did not apply:${c0}\n" "${#FAILED_PATCHES[@]}"
    printf '   %s\n' "${FAILED_PATCHES[@]}" | tee -a "$LOG_FILE"
    error_exit "Fix them, then re-run with --reset (the tree is partially patched now)."
  fi

  # Record what we just applied so a later build doesn't redo the series.
  patches_digest > "$(patches_stamp)"
}

out_dir() {
  # Relative to src/. One output dir per config and arch, so switching
  # between them stays incremental. (SIMD levels will add a suffix here.)
  local config=Release
  [ "$IS_DEBUG" = true ] && config=Debug
  [ "$IS_XP" = true ] && config=XP
  printf 'out/%s-%s\n' "$config" "$ARCH"
}

write_args() {
  # write_args <out dir> <args lines...>: write args.gn, then gn gen.
  # Writing args.gn instead of passing --args avoids quoting through cmd.exe.
  local out="$1"
  shift
  create_dir "$SRC_PATH/$out"
  {
    printf '# Generated by %s; edits are overwritten. Use --gn-args instead.\n' "$SCRIPTNAME"
    printf '%s\n' "$@"
    local a
    for a in "${EXTRA_GN_ARGS[@]}"; do
      printf '%s\n' "$a"
    done
  } > "$SRC_PATH/$out/args.gn"
  cd "$SRC_PATH" || error_exit "Unable to enter $SRC_PATH"
  execute "Generating $out" "gn gen failed" gn gen "$out"
}

version_arg() {
  # Electron otherwise takes its version from `git describe --tags`, which
  # no-history checkouts can't answer (it would build as 0.0.0-no-git-tag-found).
  printf 'override_electron_version = "%s"\n' "$ELECTRON_VERSION"
}

gen_out() {
  # Set args and gn gen out based on supplied flags. The args come from
  # assets/args/<config>_<arch>.gn, copied into args.gn because GN can't import
  # files from outside src/. Lines the file doesn't set itself are appended.
  local config=release
  [ "$IS_DEBUG" = true ] && config=debug
  [ "$IS_XP" = true ] && config=xp
  local name="${config}_${ARCH}.gn"
  local file="$ARGS_PATH/$name"
  [ -f "$file" ] || error_exit "No GN args file for this build: $file"

  local args=()
  mapfile -t args < <(tr -d '\r' < "$file")
  args=("# From assets/args/$name" "${args[@]}" "" "# Added by $SCRIPTNAME")
  grep -Eq '^[[:space:]]*target_os[[:space:]]*=' "$file" || args+=('target_os = "win"')
  grep -Eq '^[[:space:]]*override_electron_version[[:space:]]*=' "$file" || args+=("$(version_arg)")
  write_args "$(out_dir)" "${args[@]}"
}

uses_siso() {
  # Which driver autoninja will pick for this out dir. Mirrors the choice
  # depot_tools' autoninja.py makes, because that is what decides whether our
  # job count has to travel as a Ninja or a Siso flag:
  #   - an explicit `use_siso` in args.gn wins. Read the generated args.gn
  #     rather than assets/args/, so --gn-args counts too.
  #   - otherwise Siso is the default for a Chromium checkout (which this is:
  #     build/config/gclient_args.gni has build_with_chromium = true)...
  #   - ...except in an out dir Ninja has already built in. autoninja prints a
  #     "switch to Siso" suggestion and stays on Ninja, so the .ninja_deps it
  #     left behind stays usable. Our out dirs are in exactly that state.
  local out="$SRC_PATH/$1"
  local args="$out/args.gn"
  if [ -f "$args" ]; then
    grep -Eq '^[[:space:]]*use_siso[[:space:]]*=[[:space:]]*false' "$args" && return 1
    grep -Eq '^[[:space:]]*use_siso[[:space:]]*=[[:space:]]*true' "$args" && return 0
  fi
  [ -f "$out/.ninja_deps" ] && return 1
  return 0
}

ninja_bin() {
  # The ninja to build with. NINJA_BIN wins, which is the only way to use a
  # ninja of your own: autoninja never consults PATH for it. It calls
  # depot_tools' ninja.py in-process, and that prefers
  # <checkout>/third_party/ninja/ninja and reaches PATH only if no checkout has
  # one -- skipping any directory named depot_tools even then. So a host that
  # wants its own build (Ninja XP, say) sets NINJA_BIN and we run it directly;
  # see the Ninja branch of autoninja() for what that costs.
  #
  # Unset, this resolves what autoninja would have picked, so the default
  # behaviour is unchanged.
  # Reports failure rather than exiting: callers read this through $(...), where
  # an error_exit would only kill the subshell and lose its message.
  if [ -n "${NINJA_BIN:-}" ]; then
    { [ -f "$NINJA_BIN" ] && [ -x "$NINJA_BIN" ]; } || return 1
    printf '%s\n' "$NINJA_BIN"
    return 0
  fi
  local vendored="$SRC_PATH/third_party/ninja/ninja$EXE_SUFFIX"
  if [ -f "$vendored" ]; then
    printf '%s\n' "$vendored"
    return 0
  fi
  local dir
  while IFS= read -r -d: dir; do
    dir="${dir%/}"
    [ "${dir##*/}" = depot_tools ] && continue
    [ -f "$dir/ninja$EXE_SUFFIX" ] && { printf '%s\n' "$dir/ninja$EXE_SUFFIX"; return 0; }
  done <<<"$PATH:"
  return 1
}

siso_bin() {
  # The Siso the Siso path will end up running, mirroring depot_tools' siso.py:
  # SISO_PATH wins, then <base>/third_party/siso/cipd/siso, then
  # <base>/third_party/siso/siso -- for the first base of {primary solution,
  # gclient root, gclient root/src} that has build/config/siso/.sisoenv, which
  # in an Electron checkout is src/ and not the src/electron solution.
  #
  # Only used to report what is about to run: unlike Ninja, we hand the Siso
  # build to autoninja, so this does not choose anything.
  if [ -n "${SISO_PATH:-}" ]; then
    printf '%s\n' "$SISO_PATH"
    return 0
  fi
  local base p
  for base in "$ELECTRON_PATH" "$ROOT_PATH" "$SRC_PATH"; do
    [ -f "$base/build/config/siso/.sisoenv" ] || continue
    for p in "$base/third_party/siso/cipd/siso$EXE_SUFFIX" \
             "$base/third_party/siso/siso$EXE_SUFFIX"; do
      [ -f "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
  done
  return 1
}

log_build_driver() {
  # Which binary is about to do the building, and its version. Worth a line in
  # every build and not just a verbose one: the choice is made by depot_tools'
  # resolution rules rather than by anything visible in this script's output,
  # it differs per host (a vendored ninja, a NINJA_BIN of your own, a SISO_PATH
  # artifact from CI), and when a build log gets thrown away or a step behaves
  # oddly it is the first thing worth knowing.
  # Probed from the directory the build itself runs in, because the answer can
  # depend on it: depot_tools' own `ninja` is a wrapper around ninja.py, which
  # prefers the checkout's third_party/ninja and only falls back to PATH
  # outside one. Pointed at that wrapper, NINJA_BIN reports the version of
  # whatever it delegates to here -- which is the version that will build, and
  # the point of printing this at all.
  local bin="$1" version
  version=$(cd "$SRC_PATH" 2>/dev/null && "$bin" --version 2>/dev/null | head -n1) \
      || version=""
  log "${CYA} Using %s%s${c0}\n" "$bin" "${version:+ ($version)}"
}

check_ninja_identity() {
  # Ninja's build log format is versioned, and a ninja that meets a log from a
  # different version throws it away:
  #   ninja: warning: build log version is too new; starting over
  # Every output then has no log entry, which ninja reads as dirty, so the next
  # "incremental" build rebuilds the whole tree. Two ninjas in one out dir is
  # all it takes -- 1.12.1 writes v6 and 1.13.2 writes v7 -- and the usual way
  # in is a bare `ninja -C out/...` picking up a different binary than this
  # script does. Remember which one built here and say so when it changes,
  # because the warning itself scrolls past in a 60,000-step build.
  local out="$1" bin="$2" stamp
  stamp="$SRC_PATH/$out/.ninja_bin_used"
  if [ -f "$stamp" ] && [ "$(cat "$stamp")" != "$bin" ]; then
    warn "$out was last built by $(cat "$stamp"), now using $bin."
    warn "Ninja discards a build log written by another version, which rebuilds everything. Stick to one."
    error_exit "Exiting now to avoid a large rebuild"
  fi
  printf '%s\n' "$bin" > "$stamp" 2>/dev/null || true
}

autoninja() {
  # Args always carry -C <out dir>; find it to tell Siso and Ninja apart.
  local out="" i n
  for ((i = 1; i <= $#; i++)); do
    if [ "${!i}" = -C ]; then
      n=$((i + 1)); out="${!n}"; break
    fi
  done

  local flags=()
  # Both Ninja and Siso take -v to echo every command line.
  [ "$VERBOSE" = 1 ] && flags+=(-v)

  # JOBS is always set by parse_args, defaulting to the CPU count. Always pass
  # it as -j: autoninja hands that straight to Ninja, and rewrites it into
  # Siso's -local_jobs (Siso itself rejects -j). Leaving it off lets autoninja
  # pick the count instead -- CPUs + 2 -- which is how a -j16 on a 32-CPU host
  # ended up building with 34 jobs.
  flags+=(-j "$JOBS")

  local cmd=()
  if [ -n "$out" ] && uses_siso "$out"; then
    # SISO_LIMITS is read by Siso itself, and covers the one case -j does not:
    # autoninja drops it with only a warning whenever the count exceeds the CPU
    # count, even though -local_jobs would have taken it. local= is the
    # -local_jobs equivalent.
    export SISO_LIMITS="${SISO_LIMITS_BASE:+$SISO_LIMITS_BASE,}local=$JOBS"
    log "${CYA} Limiting Siso to %s local jobs (SISO_LIMITS=%s)${c0}\n" \
        "$JOBS" "$SISO_LIMITS"
    local siso
    if siso=$(siso_bin); then
      log_build_driver "$siso"
    else
      warn "No Siso binary found where depot_tools looks for one; autoninja will report the error."
    fi
    cmd=(dt autoninja)
  else
    # Drive Ninja ourselves rather than through autoninja, so NINJA_BIN can
    # choose the binary (see ninja_bin). What autoninja adds for a plain Ninja
    # build is small and reproduced here: -j, which we already pass and which is
    # the whole reason this wrapper exists, and -d stats under
    # NINJA_SUMMARIZE_BUILD. The rest of it is remote execution setup, the
    # Android build server, and uploading the ninjalog to Google -- none of
    # which apply to a local build of ours.
    local bin
    if [ -n "${NINJA_BIN:-}" ] \
        && { [ ! -f "${NINJA_BIN}" ] || [ ! -x "${NINJA_BIN}" ]; }; then
      error_exit "NINJA_BIN='$NINJA_BIN' is not an executable file"
    fi
    bin=$(ninja_bin) \
        || error_exit "No ninja found: install one on PATH or set NINJA_BIN"
    log "${CYA} Limiting Ninja to %s jobs${c0}\n" "$JOBS"
    log_build_driver "$bin"
    [ "${NINJA_SUMMARIZE_BUILD:-}" = 1 ] && flags+=(-d stats)
    [ -n "$out" ] && check_ninja_identity "$out" "$bin"
    cmd=("$bin")
  fi

  cd "$SRC_PATH" || error_exit "Unable to enter $SRC_PATH"
  VERBOSE=1 execute "Building $* (this takes a long time)" "Build failed" \
      "${cmd[@]}" "${flags[@]}" "$@"
}

ffmpeg_out_dir() {
  printf 'out/ffmpeg-%s\n' "$ARCH"
}

build_ffmpeg() {
  # Our builds always ship ffmpeg with proprietary codecs (ffmpeg_branding =
  # "Chrome", proprietary_codecs = true in assets/args). Upstream also
  # publishes a codec-free ffmpeg.dll that consumers can drop in place of ours
  # when they can't ship those codecs, so build that too -- it needs its own
  # out dir because it inverts those two args (see electron/build/args/ffmpeg.gn).
  local ffout args=()
  ffout=$(ffmpeg_out_dir)
  args=('import("//electron/build/args/ffmpeg.gn")' 'target_os = "win"'
        "target_cpu = \"$ARCH\"" "$(version_arg)")
  # ffmpeg.gn is an official build, so Clang PGO is on, and Electron resolves
  # the profile through a state file it publishes only for the platforms it
  # ships. There is no win-x86.pgo.txt, so gn gen dies reading it:
  #   ERROR at //build/config/compiler/pgo/BUILD.gn: Could not read file.
  #   I resolved this to ".../electron/build/pgo_profiles/win-x86.pgo.txt"
  # assets/args/release_x86.gn carries chrome_pgo_phase = 0 for exactly this,
  # but the ffmpeg out dir builds from ffmpeg.gn and never saw it. Keyed off
  # the state file rather than the arch, so x64 keeps its PGO and a win-x86
  # profile appearing later needs no change here.
  [ -f "$ELECTRON_PATH/build/pgo_profiles/win-$ARCH.pgo.txt" ] \
      || args+=('chrome_pgo_phase = 0')
  write_args "$ffout" "${args[@]}"
  autoninja -C "$ffout" electron:electron_ffmpeg_zip
}

build_electron() {
  # Build it!
  local config=Release
  [ "$IS_DEBUG" = true ] && config=Debug
  [ "$IS_XP" = true ] && config=XP
  log "${CYA} Building Electron (%s) for %s using %s jobs${c0}\n" "$config" "$ARCH" "$JOBS"
  local targets=(electron)
  if [ "$DO_PACKAGE" = true ]; then
    targets=(electron electron:electron_dist_zip electron:electron_mksnapshot_zip
             electron:electron_chromedriver_zip electron:node_headers)
  fi
  autoninja -C "$(out_dir)" "${targets[@]}"
  log "${GRE} Built Electron in %s${c0}\n" "$SRC_PATH/$(out_dir)"
  # Built here rather than from package() so every compile happens in the
  # build step and packaging only copies what is already built.
  [ "$DO_PACKAGE" = true ] && build_ffmpeg
}

package() {
  # Package artifacts similarly to how upstream Electron does, so that consumer's
  # package.json resolutions/overrides or electron-builder can fetch them.
  # This includes chromedriver, electron, mksnapshot, and ffmpeg .zips named properly, as well as electron-api.json and electron.d.ts.
  #
  # dist/v<ver>/ matches the release layout ELECTRON_MIRROR expects
  # (ELECTRON_CUSTOM_DIR=v<ver>), dist/headers/v<ver>/ the one npm_config_disturl
  # / node-gyp expects for native modules.
  local out="$SRC_PATH/$(out_dir)"
  local ver="v$ELECTRON_VERSION"
  # Release artifacts are named with Node's architecture string, not GN's: 32-bit
  # is ia32 there and x86 here. Everything that resolves an Electron download --
  # @electron/get, electron-builder, node-gyp via npm_config_disturl -- derives
  # the name from process.arch, so a win32-x86 zip is a zip nothing will find.
  # Electron's own tooling does this mapping in script/lib/config.py's
  # get_target_arch(); the import-library directories below keep the GN spelling
  # (win-x86), which is the layout upstream's upload-node-headers.py publishes.
  local zip_arch="$ARCH"
  [ "$ARCH" = x86 ] && zip_arch=ia32
  local suffix="$ver-win32-$zip_arch"
  local dest="$DIST_PATH/$ver"
  local headers="$DIST_PATH/headers/$ver"
  create_dir "$dest"
  create_dir "$headers"

  execute "Packaging electron, chromedriver" "Unable to copy zips" \
      cp "$out/dist.zip" "$dest/electron-$suffix.zip"
  execute "" "Unable to copy chromedriver.zip" \
      cp "$out/chromedriver.zip" "$dest/chromedriver-$suffix.zip"

  # mksnapshot.zip needs the args used to build the snapshot, as in Electron's
  # CI ("Fixup Mksnapshot"). Done on the copy so the build output stays as built.
  cd "$SRC_PATH" || error_exit "Unable to enter $SRC_PATH"
  log "${CYA} Packaging mksnapshot${c0}\n"
  gn desc "$(out_dir)" v8:run_mksnapshot_default args > "$out/mksnapshot_args" 2>>"$LOG_FILE" \
    || error_exit "gn desc failed, check $LOG_FILE for details."
  sed -i -e '/builtins-pgo/d' -e '/pgo_profiles/d' -e '/--turbo-profiling-input/d' \
      -e '/--reorder-builtins/d' -e '/--warn-about-builtin-profile-data/d' \
      -e '/--abort-on-bad-builtin-profile-data/d' "$out/mksnapshot_args"
  execute "" "Unable to copy mksnapshot.zip" \
      cp "$out/mksnapshot.zip" "$dest/mksnapshot-$suffix.zip"
  execute "" "Unable to add mksnapshot_args to mksnapshot.zip" \
      py "$HERE/tools/zip_append.py" "$dest/mksnapshot-$suffix.zip" \
      "$out/mksnapshot_args=mksnapshot_args" "$out/gen/v8/embedded.S=gen/v8/embedded.S"

  # The codec-free ffmpeg.dll build_ffmpeg() produced, for consumers who swap
  # it in for the proprietary-codec one our builds ship.
  execute "Packaging ffmpeg" "Unable to copy ffmpeg.zip" \
      cp "$SRC_PATH/$(ffmpeg_out_dir)/ffmpeg.zip" "$dest/ffmpeg-$suffix.zip"

  # TypeScript definitions and API description (arch independent).
  cd "$ELECTRON_PATH" || error_exit "Unable to enter $ELECTRON_PATH"
  execute "Generating electron.d.ts and electron-api.json" "Unable to generate TypeScript definitions" \
      node script/yarn.js create-typescript-definitions
  execute "" "Unable to copy typings" \
      cp electron.d.ts electron-api.json "$dest/"

  # Node headers and import libs for building native modules.
  local tarball="$out/gen/node_headers.tar.gz"
  local name
  for name in node-$ver.tar.gz node-$ver-headers.tar.gz iojs-$ver.tar.gz iojs-$ver-headers.tar.gz; do
    execute "" "Unable to copy node headers" cp "$tarball" "$headers/$name"
  done
  local libdirs=("win-$ARCH")
  [ "$ARCH" = x64 ] && libdirs+=(x64)
  local d
  for d in "${libdirs[@]}"; do
    create_dir "$headers/$d"
    execute "" "Unable to copy electron.lib" cp "$out/electron.lib" "$headers/$d/node.lib"
  done
  execute "Packaging node headers" "Unable to copy electron.lib" \
      cp "$out/electron.lib" "$headers/win-$ARCH/iojs.lib"
  [ "$ARCH" = x86 ] && execute "" "Unable to copy electron.lib" cp "$out/electron.lib" "$headers/node.lib"

  # Checksums cover every arch packaged so far, like the official SHASUMS256.txt.
  #
  # The two manifests deliberately differ in format, because two different
  # parsers read them and upstream's own files differ the same way:
  #
  #   dist/    -b, so names carry the binary-mode "*" marker. sumchecker, which
  #            @electron/get hands this to, expects that.
  #   headers/ no -b. node-gyp parses this one itself (downloadShasums() in
  #            lib/install.js) and only strips a leading "./", not the "*". With
  #            -b every key comes out as "*node-v<ver>-headers.tar.gz" while it
  #            looks up "node-v<ver>-headers.tar.gz", gets undefined, and every
  #            native module build dies with
  #              local checksum <sha> not match remote undefined
  cd "$dest" && execute "Writing checksums" "Unable to write SHASUMS256.txt" \
      bash -c 'sha256sum -b -- *.zip *.json *.d.ts > SHASUMS256.txt.tmp && mv SHASUMS256.txt.tmp SHASUMS256.txt'
  cd "$headers" && execute "" "Unable to write headers SHASUMS256.txt" \
      bash -c 'find . -type f ! -name "SHASUMS*" | sed "s|^\./||" | sort | xargs sha256sum -- > SHASUMS256.txt.tmp && mv SHASUMS256.txt.tmp SHASUMS256.txt'

  log "${GRE} Packaged into %s and %s${c0}\n" "$dest" "$headers"
}

npm_package() {
  # Stage the `electron` npm package in npm_package/, ready to commit and tag.
  #
  # Its sources are src/electron/npm, patched by other/09-npm-package.patch to
  # point at our releases -- so the customisation is reviewed as a patch like
  # everything else, and this only copies. The rest are the files upstream
  # injects when it publishes, which for us come out of the build: the version,
  # the checksums, electron.d.ts and the ABI.
  #
  # Arch independent on purpose. The package describes every zip in dist/, and
  # dist/ accumulates arches across runs (package() hashes whatever is there),
  # so packaging x64 and x86 before running this gives one package serving both.
  [ -d "$ELECTRON_PATH/npm" ] \
      || error_exit "No $ELECTRON_PATH/npm, run '$SCRIPTNAME -d' first"
  [ -d "$DIST_PATH/v$ELECTRON_VERSION" ] \
      || error_exit "No $DIST_PATH/v$ELECTRON_VERSION, run '$SCRIPTNAME <arch> --package' first"

  log "${CYA} Assembling npm package in %s${c0}\n" "$NPM_PATH"
  # VERBOSE=1: the summary it prints is the point of running it.
  VERBOSE=1 execute "" "Unable to assemble the npm package" \
      py "$HERE/tools/make_npm_package.py" \
      --npm-src "$ELECTRON_PATH/npm" \
      --license "$ELECTRON_PATH/LICENSE" \
      --readme "$NPM_ASSETS/README.md" \
      --dist "$DIST_PATH/v$ELECTRON_VERSION" \
      --args-gn "$ELECTRON_PATH/build/args/all.gn" \
      --out "$NPM_PATH" \
      --version "$ELECTRON_VERSION"
  log "${GRE} npm package ready in %s${c0}\n" "$NPM_PATH"
}

clean_out() {
  if [ -n "$ARCH" ]; then
    local d
    for d in "Release-$ARCH" "Debug-$ARCH" "ffmpeg-$ARCH"; do
      if [ -d "$SRC_PATH/out/$d" ]; then
        remove_path "$SRC_PATH/out/$d"
        log "${GRE} Removed out/%s${c0}\n" "$d"
      fi
    done
  elif [ -d "$SRC_PATH/out" ]; then
    remove_path "$SRC_PATH/out"
    log "${GRE} Removed %s${c0}\n" "$SRC_PATH/out"
  fi
}

main() {
  parse_args "$@"
  init_log "$@"

  if [ "$HOST_OS" = unsupported ]; then
    error_exit "Unsupported host OS '$(uname -s)'; use Git Bash on Windows"
  fi

  if [ "$DO_CLEAN" = true ]; then
    clean_out
    exit 0
  fi

  # --npm on its own assembles from dist/, so it needs no arch, no toolchain and
  # no build. With an arch it runs at the end instead, after --package.
  if [ "$DO_NPM" = true ] && [ -z "$ARCH" ]; then
    npm_package
    exit 0
  fi

  if [ "$DO_DEPS" = true ]; then
    install_deps
    if [ -z "$ARCH" ] && [ "$ONLY_DOWNLOAD" != true ] && [ "$ONLY_PATCH" != true ]; then
      exit 0
    fi
  fi

  if [ "$ONLY_DOWNLOAD" = true ] || [ "$DO_RESET" = true ] || [ "$ONLY_PATCH" = true ]; then
    # Reset runs before patch, so --reset -p is one invocation that puts the
    # tree back to stock and replays the series over it.
    if [ "$ONLY_DOWNLOAD" = true ]; then
      clone_depot_tools
      fetch_sources
    elif [ "$DO_RESET" = true ]; then
      clone_depot_tools
      check_python
      reset_sources
    fi
    if [ "$ONLY_PATCH" = true ]; then
      check_source_version
      apply_patches
    fi
    exit 0
  fi

  [ -n "$ARCH" ] || arg_error "No architecture given"
  setup_toolchain
  clone_depot_tools
  check_python

  if [ "$BUILD_ONLY" = true ]; then
    # Take src/ exactly as it is: no sync, and no patch series, not even the
    # stamp check. The point is to iterate on changes made directly in the
    # checkout, which is precisely what makes the stamp stop matching.
    [ -d "$ELECTRON_PATH/.git" ] || \
        error_exit "No sources in $SRC_PATH, run '$SCRIPTNAME -d' first"
    warn "--build-only: building $SRC_PATH as it is, skipping sync and patches."
  else
    if [ "$DO_SYNC" = true ] || [ ! -d "$ELECTRON_PATH/.git" ]; then
      fetch_sources
    elif [ "$DO_RESET" = true ]; then
      reset_sources
    fi
    check_source_version
    if patches_are_applied; then
      log "${GRE} Patches already applied; delete %s to force${c0}\n" "$(patches_stamp)"
    elif [ -f "$(patches_stamp)" ]; then
      # A stamp that doesn't match means the patch set changed since it was
      # applied. Re-running the series over an already-patched tree can't work:
      # the series overlaps itself (e.g. angle/0004 rewrites lines angle/0003
      # touched), so an applied patch stops reverse-applying cleanly once a later
      # one lands, and apply_series can only read that as a failure. Only a reset
      # gets back to a tree the series applies to.
      error_exit "patches/ changed since they were applied to $SRC_PATH; re-run with --sync to reset and re-apply, or --build-only to build the tree as it is"
    else
      apply_patches
    fi
  fi
  # Needs the checkout, so it can't go in setup_toolchain with the rest.
  if [ "$HOST_OS" = linux ]; then
    check_cross_toolchain_pinned
  fi
  gen_out
  build_electron
  [ "$DO_PACKAGE" = true ] && package
  [ "$DO_NPM" = true ] && npm_package
  log "${GRE}${bold} Done.${c0}\n"
}

main "$@"
