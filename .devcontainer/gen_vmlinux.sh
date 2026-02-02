clear

set -e

if [ ! -f /sys/kernel/btf/vmlinux ]; then
  echo "ERROR: /sys/kernel/btf/vmlinux fehlt – Kernel ohne BTF?"
  exit 1
fi

# Ziel: globale Datei, die alle nutzen können
TARGET=/usr/local/include/vmlinux.h

sudo mkdir -p /usr/local/include

sudo bpftool btf dump file /sys/kernel/btf/vmlinux format c \
  | sudo tee "$TARGET" >/dev/null

sudo chmod 644 "$TARGET"

echo "[OK] $TARGET generated and world-readable."
