#!/usr/bin/env bash
set -e

PIN_DIR=/sys/fs/bpf/vfs_write_logger
TRACE_DIR=/sys/kernel/debug/tracing

echo "[INFO] Entlade BPF-Programme..."

# Stoppe Tracing
if [ -d "$TRACE_DIR" ]; then
  echo "[INFO] Stoppe Tracing..."
  echo 0 | sudo tee $TRACE_DIR/tracing_on > /dev/null 2>&1 || true
  echo | sudo tee $TRACE_DIR/trace > /dev/null 2>&1 || true
fi

# Entferne alle BPF-Programme
if [ -d "$PIN_DIR" ]; then
  echo "[INFO] Entferne gepinnte BPF-Programme aus $PIN_DIR..."
  
  # Entferne alle Programme einzeln
  for prog in "$PIN_DIR"/*; do
    if [ -e "$prog" ]; then
      sudo rm -f "$prog" 2>/dev/null || true
    fi
  done
  
  # Entferne Verzeichnis
  sudo rmdir "$PIN_DIR" 2>/dev/null || true
  echo "[OK] BPF-Programme entladen."
else
  echo "[INFO] Keine BPF-Programme geladen (PIN_DIR existiert nicht)."
fi

# Prüfe ob noch BPF-Programme aktiv sind
ACTIVE_PROGS=$(sudo bpftool prog show | grep -i "vfs_write" | wc -l)
if [ "$ACTIVE_PROGS" -gt 0 ]; then
  echo "[WARNING] Es sind noch $ACTIVE_PROGS vfs_write BPF-Programme aktiv!"
  echo "[INFO] Versuche diese zu entfernen..."
  
  sudo bpftool prog show | grep -i "vfs_write" | awk '{print $1}' | tr -d ':' | while read prog_id; do
    sudo bpftool prog detach id "$prog_id" 2>/dev/null || true
  done
fi

echo "[OK] Cleanup abgeschlossen."
