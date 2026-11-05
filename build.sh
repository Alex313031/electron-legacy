#!/usr/bin/env bash

# Copyright (c) 2026 Alex313031

# Fetch, patch, build and package Electron for legacy Windows.
# Currently runs on Windows under Git Bash. -d/-p also work on Linux, so
# patches can be developed there; building from Linux (cross-compiling with a
# packaged Visual Studio toolchain, like Chromium does) is planned, see TODO.md.

set -u -o pipefail

SCRIPTNAME=$(basename "$0")
SCRIPTVER="1.1.1"

export HERE=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Electron release the patches in patches/ are made for.
ELECTRON_VERSION="44.2.0"

# Where .gclient and the src/ checkout live. Defaults to this repo; override
# with e.g. `ROOT_PATH=/c/el ./build.sh x64` to use a short path on Windows.
ROOT_PATH="${ROOT_PATH:-$HERE}"

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

# Controls minimum Windows target, (unused currently)
WIN32_WINNT="0x0600"

# Don't auto update depot_tools
export DEPOT_TOOLS_UPDATE=0

# Use the locally installed Visual Studio, not Google's internal toolchain.
# (Cross-building will instead point depot_tools at a packaged toolchain.)
export DEPOT_TOOLS_WIN_TOOLCHAIN="${DEPOT_TOOLS_WIN_TOOLCHAIN:-0}"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) HOST_OS=windows ;;
  Linux*) HOST_OS=linux ;;
  *) HOST_OS=unsupported ;;
esac

# Options, set by parse_args
ARCH=""
VERBOSE=0
JOBS=""
IS_DEBUG=false
DO_DEPS=false
DO_PACKAGE=false
DO_CLEAN=false
DO_SYNC=false
ONLY_DOWNLOAD=false
ONLY_PATCH=false
SHALLOW=true
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
  -j <count>, --jobs <count>  Override Siso job count. (default: let Siso decide)
  --package                   Package built binaries into dist/ for distribution.
  -d, --download-sources      Only download sources, then exit; for making local modifications.
                              Discards any local changes in src/ (it resets to v$ELECTRON_VERSION).
  -p, --patch                 Only apply patches to already-downloaded sources, then exit; needs no arch.
                              Patches that are already applied are skipped.
  --sync                      Re-sync existing sources before building (same reset as -d).
  --full-history              Download full git history (default: none, which is far
                              smaller and faster). Only affects repos not yet cloned.
  --gn-args "<args>"          Extra GN args, e.g. --gn-args 'symbol_level=0'. Repeatable.
  --clean                     Removes build artifacts from out dir (only <arch>'s, if given).
  --debug                     Make an unoptimized, full symbol debug build.

Environment:
  ROOT_PATH          Where .gclient and src/ go (default: $HERE)
  SYNC_JOBS          Parallel git operations for gclient sync (default: CPUs, max $MAX_SYNC_JOBS)
  DEPOT_TOOLS_PATH   depot_tools location if not on PATH (default: \$HOME/depot_tools)
  vs2022_install     Visual Studio path, if not installed in the default location
  WINDOWSSDKDIR      Windows SDK path, if not installed in the default location

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
      -d|--download-sources) ONLY_DOWNLOAD=true ;;
      -p|--patch) ONLY_PATCH=true ;;
      --sync) DO_SYNC=true ;;
      --full-history) SHALLOW=false ;;
      --gn-args)
        [ $# -ge 2 ] || arg_error "$1 needs a value"
        EXTRA_GN_ARGS+=("$2"); shift ;;
      --clean) DO_CLEAN=true ;;
      --debug) IS_DEBUG=true ;;
      *) arg_error "Unknown option '$1'" ;;
    esac
    shift
  done

  if [ -n "$JOBS" ] && ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    arg_error "Invalid job count '$JOBS'"
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
    return 0
  fi
  if [ ! -d "$DEPOT_TOOLS_PATH/.git" ]; then
    if [ "$DO_DEPS" != true ]; then
      error_exit "depot_tools not found on PATH or in $DEPOT_TOOLS_PATH, run '$SCRIPTNAME --deps' first"
    fi
    execute "Cloning depot_tools into $DEPOT_TOOLS_PATH" "Unable to clone depot_tools" \
        git clone "$DEPOT_TOOLS_URL" "$DEPOT_TOOLS_PATH"
  fi
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

setup_toolchain() {
  # Make sure we can target Windows from this host before running gn/siso.
  case "$HOST_OS" in
    windows)
      find_visual_studio >/dev/null \
        || error_exit "Visual Studio 2022 with C++ tools not found, see '$SCRIPTNAME --deps'"
      ;;
    linux)
      # TODO: cross-build with a packaged VS toolchain, like Chromium:
      # DEPOT_TOOLS_WIN_TOOLCHAIN=1, DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL=<dir
      # with the toolchain .zip>, GYP_MSVS_HASH_<hash>=<zip hash>; .gclient
      # already carries "win" in target_os. Needs Electron patches in other/.
      error_exit "Building Windows binaries on Linux isn't supported yet (only -d and -p are); see TODO.md"
      ;;
    *)
      error_exit "Unsupported host OS '$(uname -s)'"
      ;;
  esac
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
      "use_mtime_cache": $use_mtime_cache,
      # Download PGO profiles
      "checkout_pgo_profiles": True
    },
  },
]
target_os = $target_os
EOF

  if [ -d "$SRC_PATH" ]; then
    warn "Syncing resets $SRC_PATH to Electron v$ELECTRON_VERSION, discarding local changes."
  fi

  local flags=(sync --force --reset --delete_unversioned_trees
               --revision "src/electron@refs/tags/v$ELECTRON_VERSION")
  if [ "$SHALLOW" = true ]; then
    # Depth-1 fetch of exactly the pinned revision of every repo. Skips
    # --with_branch_heads/--with_tags, which pull every Chromium release ref.
    flags+=(--no-history)
  else
    flags+=(--with_branch_heads --with_tags)
  fi

  # One job per CPU, capped at MAX_SYNC_JOBS (SYNC_JOBS overrides).
  local cpus jobs
  cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)
  jobs=$(( cpus < MAX_SYNC_JOBS ? cpus : MAX_SYNC_JOBS ))
  jobs="${SYNC_JOBS:-$jobs}"
  [[ "$jobs" =~ ^[1-9][0-9]*$ ]] || error_exit "Invalid SYNC_JOBS '$jobs'"
  flags+=(--jobs "$jobs")

  cd "$ROOT_PATH" || error_exit "Unable to enter $ROOT_PATH"
  VERBOSE=1 execute "Syncing Electron v$ELECTRON_VERSION sources into $SRC_PATH (this takes a long time)" \
      "gclient sync failed" dt gclient "${flags[@]}"
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
      error_exit "Patch $name/$p does not apply ($applied applied so far), check $LOG_FILE for details."
    fi
  done < "$series"
  log "${GRE} %s: %d applied, %d already applied${c0}\n" "$name" "$applied" "$skipped"
}

apply_patches() {
  [ -d "$ELECTRON_PATH" ] || error_exit "No sources in $SRC_PATH, run '$SCRIPTNAME -d' first"

  # Electron's package.json always says 0.0.0-development, so compare against
  # the release tag. No-history checkouts don't have the tag; skip the check then.
  local tag head
  if tag=$(git -C "$ELECTRON_PATH" rev-parse -q --verify "refs/tags/v$ELECTRON_VERSION^{commit}" 2>/dev/null); then
    head=$(git -C "$ELECTRON_PATH" rev-parse HEAD)
    if [ "$tag" != "$head" ]; then
      warn "src/electron isn't at v$ELECTRON_VERSION, which the patches are for; expect failures."
    fi
  fi

  apply_series chromium "$SRC_PATH"
  apply_series electron "$ELECTRON_PATH"
  apply_series node "$SRC_PATH/third_party/electron_node"
  apply_series other "$SRC_PATH"
}

out_dir() {
  # Relative to src/. One output dir per config and arch, so switching
  # between them stays incremental. (SIMD levels will add a suffix here.)
  local config=Release
  [ "$IS_DEBUG" = true ] && config=Debug
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
  execute "Generating $out" "gn gen failed" dt gn gen "$out"
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

autoninja() {
  local jobs=()
  [ -n "$JOBS" ] && jobs=(-j "$JOBS")
  cd "$SRC_PATH" || error_exit "Unable to enter $SRC_PATH"
  VERBOSE=1 execute "Building $* (this takes a long time)" "Build failed" \
      dt autoninja "${jobs[@]}" "$@"
}

build_electron() {
  # Build it!
  local targets=(electron)
  if [ "$DO_PACKAGE" = true ]; then
    targets=(electron:electron_dist_zip electron:electron_mksnapshot_zip
             electron:electron_chromedriver_zip electron:node_headers)
  fi
  autoninja -C "$(out_dir)" "${targets[@]}"
  log "${GRE} Built Electron in %s${c0}\n" "$SRC_PATH/$(out_dir)"
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
  local suffix="$ver-win32-$ARCH"
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
  dt gn desc "$(out_dir)" v8:run_mksnapshot_default args > "$out/mksnapshot_args" 2>>"$LOG_FILE" \
    || error_exit "gn desc failed, check $LOG_FILE for details."
  sed -i -e '/builtins-pgo/d' -e '/pgo_profiles/d' -e '/--turbo-profiling-input/d' \
      -e '/--reorder-builtins/d' -e '/--warn-about-builtin-profile-data/d' \
      -e '/--abort-on-bad-builtin-profile-data/d' "$out/mksnapshot_args"
  execute "" "Unable to copy mksnapshot.zip" \
      cp "$out/mksnapshot.zip" "$dest/mksnapshot-$suffix.zip"
  execute "" "Unable to add mksnapshot_args to mksnapshot.zip" \
      py "$HERE/tools/zip_append.py" "$dest/mksnapshot-$suffix.zip" \
      "$out/mksnapshot_args=mksnapshot_args" "$out/gen/v8/embedded.S=gen/v8/embedded.S"

  # Proprietary-codec-free ffmpeg.dll, built in its own out dir like upstream.
  local ffout="out/ffmpeg-$ARCH"
  write_args "$ffout" 'import("//electron/build/args/ffmpeg.gn")' \
      'target_os = "win"' "target_cpu = \"$ARCH\"" "$(version_arg)"
  autoninja -C "$ffout" electron:electron_ffmpeg_zip
  execute "Packaging ffmpeg" "Unable to copy ffmpeg.zip" \
      cp "$SRC_PATH/$ffout/ffmpeg.zip" "$dest/ffmpeg-$suffix.zip"

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
  cd "$dest" && execute "Writing checksums" "Unable to write SHASUMS256.txt" \
      bash -c 'sha256sum -b -- *.zip *.json *.d.ts > SHASUMS256.txt.tmp && mv SHASUMS256.txt.tmp SHASUMS256.txt'
  cd "$headers" && execute "" "Unable to write headers SHASUMS256.txt" \
      bash -c 'find . -type f ! -name "SHASUMS*" | sed "s|^\./||" | sort | xargs sha256sum -b -- > SHASUMS256.txt.tmp && mv SHASUMS256.txt.tmp SHASUMS256.txt'

  log "${GRE} Packaged into %s and %s${c0}\n" "$dest" "$headers"
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

  if [ "$DO_DEPS" = true ]; then
    install_deps
    if [ -z "$ARCH" ] && [ "$ONLY_DOWNLOAD" != true ] && [ "$ONLY_PATCH" != true ]; then
      exit 0
    fi
  fi

  if [ "$ONLY_DOWNLOAD" = true ] || [ "$ONLY_PATCH" = true ]; then
    if [ "$ONLY_DOWNLOAD" = true ]; then
      clone_depot_tools
      fetch_sources
    fi
    [ "$ONLY_PATCH" = true ] && apply_patches
    exit 0
  fi

  [ -n "$ARCH" ] || arg_error "No architecture given"
  setup_toolchain
  clone_depot_tools

  if [ "$DO_SYNC" = true ] || [ ! -d "$ELECTRON_PATH/.git" ]; then
    fetch_sources
  fi
  apply_patches
  gen_out
  build_electron
  [ "$DO_PACKAGE" = true ] && package
  log "${GRE}${bold} Done.${c0}\n"
}

main "$@"
