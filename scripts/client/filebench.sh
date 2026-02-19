#!/bin/bash
# ==============================================================================
# Filebench Controller (Thesis Edition - Final)
# - Features: Interaktive Pause, Cache-Drop nach Metadaten-Scan
# ==============================================================================

set -euo pipefail

# --- Konfiguration ---
NFS_MOUNT="/mnt/nfs"

# Farben für Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Tempfile Cleanup ---
TMP_FILES=()
register_tmp() { TMP_FILES+=("$1"); }
cleanup_tmp_files() {
  for f in "${TMP_FILES[@]:-}"; do [ -n "${f:-}" ] && rm -f "$f" 2>/dev/null || true; done
}
trap cleanup_tmp_files EXIT TERM

# --- Hilfe ---
print_help() {
  cat << EOF
Usage: sudo ./$(basename "$0") <setup|prepare|run|teardown> [OPTIONS]

Workflow:
  1. sudo ./$(basename "$0") setup <IP>  # Mountet NFS
  2. sudo ./$(basename "$0") prepare     # Erstellt Dateien (einmalig)
  3. sudo ./$(basename "$0") run -t 60   # Führt Test mit Cache-Drop aus
EOF
}

# --- 1. SETUP ---
cmd_setup() {
  local server_ip="${1:-localhost}"
  echo -e "${BLUE}=== Setup: Mount NFS ===${NC}"
  sudo mkdir -p "$NFS_MOUNT"
  if ! mountpoint -q "$NFS_MOUNT"; then
    # Passe den Export-Pfad ggf. an deinen Server an (/srv/nfs/thesis_data)
    sudo mount -t nfs -o vers=3,nolock "$server_ip:/srv/nfs/thesis_data" "$NFS_MOUNT" || { 
        echo -e "${RED}Mount fehlgeschlagen! IP prüfen.${NC}"; exit 1; 
    }
  fi
  echo -e "${GREEN}✅ NFS gemountet auf $NFS_MOUNT${NC}"
}

# --- 2. PREPARE ---
cmd_prepare() {
  echo -e "${BLUE}=== Prepare: Erstelle Testdateien ===${NC}"
  local prep_tmp=$(mktemp /tmp/fb_prep.XXXXXX.f)
  register_tmp "$prep_tmp"

  cat <<EOF > "$prep_tmp"
set \$dir=$NFS_MOUNT
set \$nfiles=10000
set \$filesize=64k
define fileset name=myfiles,path=\$dir,size=\$filesize,entries=\$nfiles,dirwidth=100,prealloc=100
create files
EOF
  filebench -f "$prep_tmp"
  echo -e "${GREEN}✅ Vorbereitung abgeschlossen.${NC}"
}

# --- 3. RUN (Der wissenschaftliche Teil) ---
cmd_run() {
  local duration="60"
  while [[ $# -gt 0 ]]; do
    case $1 in
      -t|--time) duration="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  local run_tmp=$(mktemp /tmp/fb_run.XXXXXX.f)
  register_tmp "$run_tmp"

  # Hier bauen wir das Filebench-Profil (WML)
  {
    echo "set \$dir=$NFS_MOUNT"
    echo "set \$nfiles=10000"
    echo "set \$filesize=64k"
    
    # Fileset mit reuse (scannt nur vorhandene Dateien)
    echo "define fileset name=myfiles,path=\$dir,size=\$filesize,entries=\$nfiles,dirwidth=100,prealloc=100,reuse"

    # PHASE 1: Vorbereitung (Metadaten landen im Cache)
    echo "echo \"🔍 Scanne Metadaten (Pre-allocation)...\""
    echo "create files"
    
    # PHASE 2: Interaktive Pause
    echo "echo \"------------------------------------------------------------\""
    echo "echo \"✅ Metadaten-Scan fertig (Dentries/Inodes sind im RAM).\""
    echo "echo \"🚀 Drücke ENTER um Caches zu leeren und Messung zu starten!\""
    echo "echo \"------------------------------------------------------------\""
    
    # Warten auf Tastendruck
    echo "system \"read dummy < /dev/tty\""
    
    # PHASE 3: Der radikale Cache-Drop
    echo "echo \"🧹 Dropping Caches (Client)...\""
    echo "system \"sync\""
    echo "system \"echo 3 > /proc/sys/vm/drop_caches\""
    echo "sleep 2"
    
    # PHASE 4: Eigentlicher Workload
    echo "define process name=nfs_proc,instances=1 {"
    echo "  thread name=nfs_thread,instances=1 {"
    echo "    flowop openfile name=open,filesetname=myfiles,fd=1"
    echo "    flowop readwholefile name=read,fd=1"
    echo "    flowop closefile name=close,fd=1"
    echo "  }"
    echo "}"
    
    echo "echo \"🏁 Starte Benchmark-Lauf...\""
    echo "run $duration"
  } > "$run_tmp"

  echo -e "${BLUE}=== Starte Filebench ===${NC}"
  filebench -f "$run_tmp"
}

# --- 4. TEARDOWN ---
cmd_teardown() {
  echo -e "${YELLOW}=== Teardown: Unmount NFS ===${NC}"
  sudo umount -l "$NFS_MOUNT" 2>/dev/null || true
  echo -e "${GREEN}✅ Abgeschlossen.${NC}"
}

# --- Main Switch ---
case "${1:-}" in
  setup)    shift; cmd_setup "$@" ;;
  prepare)  cmd_prepare ;;
  run)      shift; cmd_run "$@" ;;
  teardown) cmd_teardown ;;
  *)        print_help ;;
esac