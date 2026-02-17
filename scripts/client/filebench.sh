#!/bin/bash
# ==============================================================================
# Filebench Controller (Ubuntu 24.04 Optimized)
# - temp copy of profile for prepare/run
# - auto cleanup on EXIT + Ctrl+C (INT) + TERM
# - run supports --dir to override location
# ==============================================================================

set -euo pipefail

# --- Konfiguration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

DEFAULT_EXPORT="/srv/nfs/thesis_data"
NFS_MOUNT="/mnt/nfs"
WORKLOAD_FILE="/tmp/safe_nfs.f"

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Tempfile cleanup (auch bei Ctrl+C) ---
TMP_FILES=()

register_tmp() {
  TMP_FILES+=("$1")
}

cleanup_tmp_files() {
  for f in "${TMP_FILES[@]:-}"; do
    [ -n "${f:-}" ] && rm -f "$f" 2>/dev/null || true
  done
}

on_int() {
  echo -e "\n${YELLOW}Interrupted (Ctrl+C) -> cleaning temp files...${NC}"
  cleanup_tmp_files
  exit 130
}

trap cleanup_tmp_files EXIT TERM
trap on_int INT

# --- Filebench finden ---
if [ -z "${FILEBENCH_DIR:-}" ]; then
  if [ -d "$PARENT_DIR/filebench" ]; then FILEBENCH_DIR="$PARENT_DIR/filebench"
  elif [ -d "/work/filebench" ]; then FILEBENCH_DIR="/work/filebench"
  else FILEBENCH_DIR="./filebench"
  fi
fi

# --- Hilfe ---
print_help() {
  cat << EOF
Usage: sudo ./$(basename "$0") <COMMAND> [OPTIONS]

Commands:
  build                 -> Re-compiles Filebench with security checks disabled
  setup <IP> [EXPORT]   -> Mounts NFS and generates a stable workload file
  prepare [options]     -> Cleans dir + runs ONLY "create files" (prealloc phase)
  run [options]         -> Runs the benchmark using a TEMP COPY of the profile
  teardown              -> Unmounts and cleans up

Run Options:
  -t, --time <sec>      Override runtime duration (e.g., 60)
  -p, --profile <file>  Use a custom workload file (.f) instead of the default
  --dir <path>          Override location (rewrites set \$dir=... AND path=... lines)
  --no-reuse            Don't reuse files (recreate them - SLOW)

Prepare Options:
  -p, --profile <file>  Use a custom workload file (.f) instead of the default
  --dir <path>          Override location for prepare (default: $NFS_MOUNT)
  --no-clean            Don't rm -rf the target directory before prepare

Examples:
  sudo ./$(basename "$0") setup 192.168.1.10 /srv/nfs/thesis_data
  sudo ./$(basename "$0") prepare
  sudo ./$(basename "$0") prepare -p /path/to/profile.f --dir /mnt/nfs_test
  sudo ./$(basename "$0") run -t 60
  sudo ./$(basename "$0") run -p /path/to/profile.f --dir /mnt/nfs_test -t 60
EOF
}

# --- Helper: dir in Profil injizieren (set $dir + path=... überschreiben) ---
inject_dir_into_profile() {
  local profile_file="$1"
  local dir="$2"

  # 1) set $dir=... ersetzen oder hinzufügen
  if grep -qE '^[[:space:]]*set[[:space:]]+\$dir=' "$profile_file"; then
    sed -i "s|^[[:space:]]*set[[:space:]]\+\$dir=.*|set \$dir=$dir|g" "$profile_file"
  else
    sed -i "1iset \$dir=$dir" "$profile_file"
  fi

  # 2) define fileset/file ... path=... überschreiben (falls hardcoded)
  sed -i -E "/^[[:space:]]*define[[:space:]]+fileset[[:space:]]/ s|path=[^,[:space:]]+|path=$dir|g" "$profile_file"
  sed -i -E "/^[[:space:]]*define[[:space:]]+file[[:space:]]/   s|path=[^,[:space:]]+|path=$dir|g" "$profile_file"
}

# --- 1. BUILD ---
cmd_build() {
  echo -e "${BLUE}=== Filebench Build (Relaxed Security) ===${NC}"

  if [ ! -d "$FILEBENCH_DIR" ]; then
    mkdir -p "$(dirname "$FILEBENCH_DIR")"
    git clone https://github.com/filebench/filebench.git "$FILEBENCH_DIR"
  fi
  cd "$FILEBENCH_DIR"

  if ! command -v make >/dev/null; then
    sudo apt-get update
    sudo apt-get install -y build-essential libtool automake autoconf bison flex psmisc nfs-common
  fi

  if [ ! -f "configure" ]; then
    libtoolize && aclocal && autoheader && automake --add-missing && autoconf
  fi

  echo -e "${YELLOW}Cleaning old builds...${NC}"
  make distclean 2>/dev/null || true

  echo -e "${YELLOW}Configuring with checks DISABLED (_FORTIFY_SOURCE=0)...${NC}"
  ./configure CFLAGS="-g -O2 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -fno-stack-protector"

  echo "Compiling..."
  make
  sudo make install
  echo -e "${GREEN}✅ Build complete.${NC}"
}

# --- 2. SETUP ---
cmd_setup() {
  local server_ip="${1:-localhost}"
  local nfs_export="${2:-$DEFAULT_EXPORT}"

  echo -e "${BLUE}=== Setup: Mount NFS + Generate Stable Workload ===${NC}"

  sudo mkdir -p "$NFS_MOUNT"
  if ! mountpoint -q "$NFS_MOUNT"; then
    echo "Mounting $server_ip:$nfs_export -> $NFS_MOUNT"
    sudo mount -t nfs "$server_ip:$nfs_export" "$NFS_MOUNT" || {
      echo -e "${RED}Mount failed.${NC}"
      exit 1
    }
  else
    echo -e "${YELLOW}Already mounted: $NFS_MOUNT${NC}"
  fi

  echo "Writing safe config to $WORKLOAD_FILE..."
  cat > "$WORKLOAD_FILE" <<EOF
# Safe Stable NFS Workload
set \$dir=$NFS_MOUNT
set \$nfiles=10000
set \$filesize=64k
set \$nthreads=1

define fileset name=myfiles,path=\$dir,size=\$filesize,entries=\$nfiles,dirwidth=\$nfiles,prealloc=100

define process name=nfs_proc,instances=1 {
  thread name=nfs_thread,instances=\$nthreads {
    flowop openfile name=open,filesetname=myfiles,fd=1
    flowop readwholefile name=read,fd=1
    flowop closefile name=close,fd=1
    flowop openfile name=open2,filesetname=myfiles,fd=1
    flowop appendfilerand name=append,fd=1,iosize=4k
    flowop closefile name=close2,fd=1
    flowop statfile name=stat,filesetname=myfiles
  }
}

run 60
EOF

  echo -e "${GREEN}✅ Setup complete.${NC}"
  echo -e "${YELLOW}Default workload file:${NC} $WORKLOAD_FILE"
}

# --- 3. PREPARE ---
cmd_prepare() {
  echo -e "${BLUE}=== Prepare: Creating Files (create files only) ===${NC}"

  local profile="$WORKLOAD_FILE"
  local dir_override="$NFS_MOUNT"
  local do_clean=true

  while [[ $# -gt 0 ]]; do
    case $1 in
      -p|--profile) profile="$2"; shift 2 ;;
      --dir) dir_override="$2"; shift 2 ;;
      --no-clean) do_clean=false; shift ;;
      *) echo -e "${RED}Unknown option for prepare: $1${NC}"; exit 1 ;;
    esac
  done

  [ ! -f "$profile" ] && { echo -e "${RED}Profile not found: $profile${NC}"; exit 1; }

  sudo mkdir -p "$dir_override"

  if [[ "$dir_override" == "$NFS_MOUNT" ]]; then
    if ! mountpoint -q "$NFS_MOUNT"; then
      echo -e "${RED}NFS mount not active at $NFS_MOUNT. Run 'setup' first (or mount manually).${NC}"
      exit 1
    fi
  fi

  if [ "$do_clean" = true ]; then
    echo "Cleaning directory: $dir_override ..."
    sudo rm -rf "$dir_override"/* 2>/dev/null || true
  else
    echo -e "${YELLOW}Skipping clean (--no-clean).${NC}"
  fi

  local prep_tmp
  prep_tmp="$(mktemp /tmp/filebench_prepare.XXXXXX.f)"
  register_tmp "$prep_tmp"
  cp "$profile" "$prep_tmp"

  inject_dir_into_profile "$prep_tmp" "$dir_override"

  # Run/Creates entfernen
  sed -i '/^[[:space:]]*run[[:space:]]\+/d' "$prep_tmp"
  sed -i '/^[[:space:]]*create[[:space:]]\+files[[:space:]]*$/d' "$prep_tmp"
  sed -i '/^[[:space:]]*create[[:space:]]\+processes[[:space:]]*$/d' "$prep_tmp"

  # Nur Prealloc
  echo "eventgen rate = 1" >> "$prep_tmp"
  echo "create files" >> "$prep_tmp"

  echo "Allocating files using TEMP profile: $prep_tmp"
  echo "Injected dir: $dir_override"

  ulimit -s unlimited 2>/dev/null || true
  echo 0 | sudo tee /proc/sys/kernel/randomize_va_space > /dev/null

  filebench -f "$prep_tmp"
  echo -e "${GREEN}✅ Prepare done.${NC}"
}

# --- 4. RUN ---
cmd_run() {
  local duration=""
  local custom_profile=""
  local use_default=true
  local no_reuse=false
  local dir_override="$NFS_MOUNT"

  while [[ $# -gt 0 ]]; do
    case $1 in
      -t|--time) duration="$2"; shift 2 ;;
      -p|--profile) custom_profile="$2"; use_default=false; shift 2 ;;
      --no-reuse) no_reuse=true; shift ;;
      --dir) dir_override="$2"; shift 2 ;;
      *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
    esac
  done

  local base_profile
  if [ "$use_default" = true ]; then
    base_profile="$WORKLOAD_FILE"
    echo -e "${BLUE}=== Running Benchmark (Default Profile) ===${NC}"
  else
    base_profile="$custom_profile"
    echo -e "${BLUE}=== Running Benchmark (Custom Profile) ===${NC}"
  fi

  [ ! -f "$base_profile" ] && { echo -e "${RED}Profile not found: $base_profile${NC}"; exit 1; }

  sudo mkdir -p "$dir_override"

  # TEMP COPY erstellen (und später automatisch löschen – auch bei Ctrl+C)
  local run_tmp
  run_tmp="$(mktemp /tmp/filebench_run.XXXXXX.f)"
  register_tmp "$run_tmp"
  cp "$base_profile" "$run_tmp"

  # Dir überschreiben
  inject_dir_into_profile "$run_tmp" "$dir_override"
  echo "-> Using TEMP profile: $run_tmp"
  echo "-> Run dir overridden: $dir_override"

  # Reuse Flag Logic
  if [ "$no_reuse" = false ]; then
    if ! grep -q "define fileset.*reuse" "$run_tmp"; then
      sed -i "/^define fileset/ s/$/,reuse/" "$run_tmp"
    fi
  fi

  # Zeit Override
  if [ -n "$duration" ]; then
    sed -i '/^[[:space:]]*run[[:space:]]\+/d' "$run_tmp"
    echo "run $duration" >> "$run_tmp"
  fi

  # Runtime Fixes (wie bei dir)
  echo 0 | sudo tee /proc/sys/kernel/randomize_va_space > /dev/null
  echo 2147483648 | sudo tee /proc/sys/kernel/shmmax > /dev/null

  # Debug: effektiv verwendeter Pfad
  echo ">>> Effective set \$dir:"
  grep -nE '^[[:space:]]*set[[:space:]]+\$dir=' "$run_tmp" || true
  echo ">>> Effective define fileset/file path lines:"
  grep -nE '^[[:space:]]*define[[:space:]]+(fileset|file).*path=' "$run_tmp" || true

  echo "Starting Filebench..."
  filebench -f "$run_tmp"

  echo -e "${GREEN}✅ Run finished.${NC}"
}

# --- 5. TEARDOWN ---
cmd_teardown() {
  echo -e "${BLUE}=== Teardown ===${NC}"
  if mountpoint -q "$NFS_MOUNT"; then
    sudo umount -lf "$NFS_MOUNT" 2>/dev/null || sudo umount "$NFS_MOUNT"
  fi
  rm -f "$WORKLOAD_FILE"
  echo -e "${GREEN}✅ Teardown done.${NC}"
}

# --- MAIN ---
case "${1:-}" in
  build)    cmd_build ;;
  setup)    shift; cmd_setup "$@" ;;
  prepare)  shift; cmd_prepare "$@" ;;
  run)      shift; cmd_run "$@" ;;
  teardown) cmd_teardown ;;
  *)        print_help ;;
esac
