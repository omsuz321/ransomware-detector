#!/usr/bin/env bash
set -e

OBJ=./vfs_write.bpf.o
PIN_DIR=/sys/fs/bpf/vfs_write_logger

if [ ! -f "$OBJ" ]; then
  echo "BPF-Objekt $OBJ fehlt – erst ./scripts/build.sh ausführen."
  exit 1
fi

sudo mkdir -p "$PIN_DIR"

# Programme laden (kprobe/kretprobe attachen automatisch)
echo "[INFO] Lade BPF-Programme..."
sudo bpftool prog load "$OBJ" "$PIN_DIR/vfs_write" autoattach

echo "[OK] eBPF vfs_write logger geladen und attached."
echo ""
echo "Zum Tracen ausführen: ./scripts/trace.sh"
