#!/usr/bin/env bash
set -e

# Falls nicht als root gestartet, mit sudo neu aufrufen
if [ "$EUID" -ne 0 ]; then
  exec sudo -E "$0" "$@"
fi

TRACE_DIR=/sys/kernel/debug/tracing

# Stelle sicher dass /sys/kernel/debug existiert
mkdir -p /sys/kernel/debug

# Stelle sicher dass debugfs gemounted ist
if ! mount | grep -q " on /sys/kernel/debug "; then
  echo "[INFO] Mounte debugfs..."
  mount -t debugfs debugfs /sys/kernel/debug
fi

# Stelle sicher dass tracefs gemounted ist
if ! mount | grep -q " on /sys/kernel/debug/tracing "; then
  echo "[INFO] Mounte tracefs..."
  mkdir -p "$TRACE_DIR"
  mount -t tracefs tracefs "$TRACE_DIR" || true
fi

# Finale Prüfung
if [ ! -d "$TRACE_DIR" ]; then
  echo "[ERROR] $TRACE_DIR konnte nicht erstellt werden!"
  echo "[INFO] Versuche: mount -t debugfs debugfs /sys/kernel/debug"
  exit 1
fi

# Tracing zurücksetzen
echo "[INFO] Setze Tracing zurück..."
echo 0 > $TRACE_DIR/tracing_on
echo > $TRACE_DIR/trace
echo 1 > $TRACE_DIR/tracing_on

echo "[INFO] Starte trace_pipe. STRG+C zum Beenden."
cat $TRACE_DIR/trace_pipe
