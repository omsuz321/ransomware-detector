clear

set -e

if [ ! -f /sys/kernel/btf/vmlinux ]; then
  echo "ERROR: /sys/kernel/btf/vmlinux fehlt – Kernel ohne BTF?"
  exit 1
fi

# Ziel: globale Datei, die alle nutzen können
TARGET=/usr/local/include/vmlinux.h

mkdir -p /usr/local/include

bpftool btf dump file /sys/kernel/btf/vmlinux format c > "$TARGET"

chmod 644 "$TARGET"

echo "[OK] $TARGET generated and world-readable."

# Kopiere auch zu my_lsm/include für lokale Nutzung
MY_LSM_TARGET=/work/security/my_lsm/include/vmlinux.h
mkdir -p "$(dirname "$MY_LSM_TARGET")"
cp "$TARGET" "$MY_LSM_TARGET"
chmod 644 "$MY_LSM_TARGET"

echo "[OK] $MY_LSM_TARGET copied."
