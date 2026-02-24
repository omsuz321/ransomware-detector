#!/bin/bash
# ==============================================================================
# Filebench Controller (Thesis Edition - Final)
# - Features: Custom Profiles (--profile), Custom Dirs (--dir), ASLR Auto-Restore
# - Interaktives Cache-Dropping wird dynamisch ins Profil injiziert!
# ==============================================================================

set -euo pipefail

# --- Konfiguration ---
DEFAULT_NFS_MOUNT="/mnt/nfs"

# Farben für Output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Variablen für die ursprünglichen Kernel-Zustände
ORIG_ASLR=""
ORIG_SHMMAX=""

# --- System-Restore & Tempfile Cleanup ---
TMP_FILES=()
register_tmp() { TMP_FILES+=("$1"); }

cleanup() {
  for f in "${TMP_FILES[@]:-}"; do 
    [ -n "${f:-}" ] && rm -f "$f" 2>/dev/null || true
  done

  if [[ -n "$ORIG_ASLR" ]]; then
    echo -e "${YELLOW}⚙️ Stelle System-Sicherheit (ASLR) wieder her...${NC}"
    echo "$ORIG_ASLR" | sudo tee /proc/sys/kernel/randomize_va_space > /dev/null
  fi
  if [[ -n "$ORIG_SHMMAX" ]]; then
    echo "$ORIG_SHMMAX" | sudo tee /proc/sys/kernel/shmmax > /dev/null
  fi
}
trap cleanup EXIT TERM INT

# --- Kernel-Fixes anwenden ---
apply_kernel_fixes() {
  if [[ -z "$ORIG_ASLR" ]]; then
    ORIG_ASLR=$(cat /proc/sys/kernel/randomize_va_space 2>/dev/null || echo 2)
  fi
  if [[ -z "$ORIG_SHMMAX" ]]; then
    ORIG_SHMMAX=$(cat /proc/sys/kernel/shmmax 2>/dev/null || echo 33554432)
  fi

  echo -e "${YELLOW}⚙️ Deaktiviere ASLR temporär für Filebench...${NC}"
  echo 0 | sudo tee /proc/sys/kernel/randomize_va_space > /dev/null
  echo 2147483648 | sudo tee /proc/sys/kernel/shmmax > /dev/null
}

# --- Hilfe ---
print_help() {
  cat << EOF
Usage: sudo ./$(basename "$0") <setup|prepare|run|teardown> [OPTIONS]

Beispiel:
  sudo ./$(basename "$0") prepare --dir /mnt/nfs --profile ./fileserver.f
  sudo ./$(basename "$0") run --time 900 --dir /mnt/nfs --profile ./fileserver.f
EOF
}

# --- 1. SETUP ---
cmd_setup() {
  local server_ip="${1:-localhost}"
  echo -e "${BLUE}=== Setup: Mount NFS ===${NC}"
  sudo mkdir -p "$DEFAULT_NFS_MOUNT"
  if ! mountpoint -q "$DEFAULT_NFS_MOUNT"; then
    sudo mount -t nfs -o vers=3,nolock "$server_ip:/srv/nfs/thesis_data" "$DEFAULT_NFS_MOUNT" || { 
        echo -e "${RED}Mount fehlgeschlagen! IP prüfen.${NC}"; exit 1; 
    }
  fi
  echo -e "${GREEN}✅ NFS gemountet auf $DEFAULT_NFS_MOUNT${NC}"
}

# --- 2. PREPARE ---
cmd_prepare() {
  echo -e "${BLUE}=== Prepare: Erstelle Testdateien ===${NC}"
  
  local profile=""
  local dir_override="$DEFAULT_NFS_MOUNT"
  local EXTRA_ARGS=()

  # Argumente parsen
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--profile) profile="$2"; shift 2 ;;
      --dir) dir_override="$2"; shift 2 ;;
      -v) EXTRA_ARGS+=("-v" "$2"); shift 2 ;;
      *) echo -e "${RED}❌ Unbekanntes Argument: $1${NC}"; exit 1 ;;
    esac
  done

  [ -z "$profile" ] && { echo -e "${RED}❌ Bitte --profile angeben!${NC}"; exit 1; }
  [ ! -f "$profile" ] && { echo -e "${RED}❌ Profildatei '$profile' nicht gefunden!${NC}"; exit 1; }

  local prep_tmp=$(mktemp /tmp/fb_prep.XXXXXX.f)
  register_tmp "$prep_tmp"

  cp "$profile" "$prep_tmp"

  # Pfad im Profil anpassen
  sed -i "s|^set[[:space:]]*\$dir=.*|set \$dir=$dir_override|g" "$prep_tmp"
  
  # Den 'run' Befehl entfernen (wir wollen ja nur vorbereiten)
  sed -i '/^[[:space:]]*run[[:space:]]/d' "$prep_tmp"
  
  # Stattdessen 'create files' ans Ende setzen
  echo "create files" >> "$prep_tmp"

  apply_kernel_fixes

  filebench -f "$prep_tmp" "${EXTRA_ARGS[@]}"
  echo -e "${GREEN}✅ Vorbereitung abgeschlossen.${NC}"
}

# --- 3. RUN ---
cmd_run() {
  local duration="60"
  local profile=""
  local dir_override="$DEFAULT_NFS_MOUNT"
  local EXTRA_ARGS=()

  # Argumente parsen
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--time) duration="$2"; shift 2 ;;
      -p|--profile) profile="$2"; shift 2 ;;
      --dir) dir_override="$2"; shift 2 ;;
      -v) EXTRA_ARGS+=("-v" "$2"); shift 2 ;;
      *) echo -e "${RED}❌ Unbekanntes Argument: $1${NC}"; exit 1 ;;
    esac
  done

  [ -z "$profile" ] && { echo -e "${RED}❌ Bitte --profile angeben!${NC}"; exit 1; }
  [ ! -f "$profile" ] && { echo -e "${RED}❌ Profildatei '$profile' nicht gefunden!${NC}"; exit 1; }

  local run_tmp=$(mktemp /tmp/fb_run.XXXXXX.f)
  register_tmp "$run_tmp"

  cp "$profile" "$run_tmp"

  # Pfad im Profil anpassen
  sed -i "s|^set[[:space:]]*\$dir=.*|set \$dir=$dir_override|g" "$run_tmp"

  # Sicherstellen, dass "reuse" beim Fileset steht (damit er nicht neu anlegt)
  if ! grep -q "reuse" "$run_tmp"; then
    sed -i '/^[[:space:]]*define fileset/ s/$/,reuse/' "$run_tmp"
  fi

  # Den alten 'run' Befehl entfernen
  sed -i '/^[[:space:]]*run[[:space:]]/d' "$run_tmp"

  # Das Interaktive Menü und den Cache-Drop DYNAMISCH unten anhängen!
  {
    echo "echo \"🔍 Scanne Metadaten (Pre-allocation)...\""
    echo "create files"
    echo "echo \"------------------------------------------------------------\""
    echo "echo \"✅ Metadaten-Scan fertig (Dentries/Inodes sind im RAM).\""
    echo "echo \"🚀 Drücke ENTER um Caches zu leeren und Messung zu starten!\""
    echo "echo \"------------------------------------------------------------\""
    echo "system \"read dummy < /dev/tty\""
    echo "echo \"🧹 Dropping Caches (Client)...\""
    echo "system \"sync\""
    echo "system \"echo 3 > /proc/sys/vm/drop_caches\""
    echo "sleep 2"
    echo "echo \"🏁 Starte Benchmark-Lauf...\""
    echo "run $duration"
  } >> "$run_tmp"

  apply_kernel_fixes

  echo -e "${BLUE}=== Starte Filebench ===${NC}"
  filebench -f "$run_tmp" "${EXTRA_ARGS[@]}"
}

# --- 4. TEARDOWN ---
cmd_teardown() {
  echo -e "${YELLOW}=== Teardown: Unmount NFS ===${NC}"
  sudo umount -l "$DEFAULT_NFS_MOUNT" 2>/dev/null || true
  echo -e "${GREEN}✅ Abgeschlossen.${NC}"
}

# --- Main Switch ---
case "${1:-}" in
  setup)    shift; cmd_setup "$@" ;;
  prepare)  shift; cmd_prepare "$@" ;;
  run)      shift; cmd_run "$@" ;;
  teardown) cmd_teardown ;;
  *)        print_help ;;
esac