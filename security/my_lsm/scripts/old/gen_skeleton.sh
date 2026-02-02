#!/bin/bash
set -e

# filepath: /work/security/my_lsm/scripts/gen_skeleton.sh
# Generiert vfs_write.skel.h aus vfs_write.bpf.o

if [ "$EUID" -ne 0 ]; then
  exec sudo -E "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BPF_OBJ="$PROJECT_DIR/vfs_write.bpf.o"
SKEL_H="$PROJECT_DIR/include/vfs_write.skel.h"

echo "=== Generiere BPF Skeleton Header ==="

# 1. Prüfe ob .o File existiert
if [ ! -f "$BPF_OBJ" ]; then
  echo "❌ Fehler: $BPF_OBJ nicht gefunden!"
  echo "[INFO] Erst kompilieren: cd $PROJECT_DIR && make"
  exit 1
fi

# 2. Prüfe ob include-Verzeichnis existiert
mkdir -p "$PROJECT_DIR/include"

# 3. Generiere Skeleton Header
echo "--- Generiere Skeleton Header ---"
if bpftool gen skeleton "$BPF_OBJ" > "$SKEL_H"; then
  echo "✅ Skeleton Header generiert:"
  echo "   $SKEL_H"
  wc -l "$SKEL_H"
else
  echo "❌ Fehler beim Generieren!"
  exit 1
fi

echo ""
echo "=== Fertig ==="
