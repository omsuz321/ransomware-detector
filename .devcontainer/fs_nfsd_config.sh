#!/bin/bash
# filepath: /work/.devcontainer/fs_nfsd_config.sh
# Aktiviert wichtige Dateisystem- und NFSD-Optionen in .config

set -e

KERNEL_DIR="${1:-.}"
CONFIG_FILE="$KERNEL_DIR/.config"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Fehler: $CONFIG_FILE nicht gefunden!"
    exit 1
fi

cd "$KERNEL_DIR"

echo "=== Aktiviere Dateisystem- und NFSD-Optionen ==="

# NFSD / NFS-Server
scripts/config --enable CONFIG_NFSD
scripts/config --enable CONFIG_NFSD_V3
scripts/config --enable CONFIG_NFSD_V4
scripts/config --enable CONFIG_NFSD_LEGACY_CLIENT_TRACKING

# Dateisystem-Optionen
scripts/config --enable CONFIG_EXT4_FS
scripts/config --enable CONFIG_TMPFS
scripts/config --enable CONFIG_PROC_FS
scripts/config --enable CONFIG_SYSFS

# Netzwerk (für NFSD wichtig)
scripts/config --enable CONFIG_INET
scripts/config --enable CONFIG_IPV4
scripts/config --enable CONFIG_SUNRPC
scripts/config --enable CONFIG_LOCKD
scripts/config --enable CONFIG_GRACE_PERIOD

# Sicherheit & BPF
scripts/config --enable CONFIG_SECURITY
scripts/config --enable CONFIG_SECURITY_LSM
scripts/config --enable CONFIG_BPF
scripts/config --enable CONFIG_BPF_SYSCALL
scripts/config --enable CONFIG_DEBUG_INFO_BTF

# Deaktiviere Werror um Compilier-Warnungen zu ignorieren
scripts/config --disable CONFIG_WERROR

echo "--- Aktualisiere .config mit olddefconfig ---"
make olddefconfig > /dev/null 2>&1

echo ""
echo "✅ Folgende Optionen sind jetzt aktiviert:"
grep -E "^CONFIG_(NFSD|EXT4|TMPFS|SUNRPC|LOCKD|SECURITY_LSM|BPF)" .config | grep "=y"

echo ""
echo "=== Konfiguration abgeschlossen ==="
