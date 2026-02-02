#!/bin/bash
set -e

# filepath: /work/.devcontainer/create_fs_config.sh
# Erstellt eine .config basierend auf Host-Config + alle FS-Optionen auf Y

KERNEL_DIR="${1:-.}"
HOST_KERNEL_VERSION="${2:-(uname -r)}"

if [ ! -d "$KERNEL_DIR" ]; then
    echo "❌ Fehler: $KERNEL_DIR nicht gefunden!"
    exit 1
fi

CONFIG_FILE="$KERNEL_DIR/.config"
HOST_CONFIG="/boot/config-$HOST_KERNEL_VERSION"

echo "=== Erstelle FS-optimierte .config ==="

# 1. Kopiere Host-Config als Basis
if [ -f "$HOST_CONFIG" ]; then
    echo "--- Kopiere Host-Config von $HOST_CONFIG ---"
    cp "$HOST_CONFIG" "$CONFIG_FILE"
    echo "✓ Host-Config als Basis kopiert"
else
    echo "⚠️ Host-Config nicht gefunden, nutze defconfig..."
    cd "$KERNEL_DIR"
    make defconfig > /dev/null 2>&1
fi

cd "$KERNEL_DIR"

echo ""
echo "--- Aktiviere alle FS/NFSD-Optionen auf Y ---"

# 2. Aktiviere ALLE wichtigen FS-Optionen
FS_OPTIONS=(
    # NFSD / NFS-Server
    "CONFIG_NFSD"
    "CONFIG_NFSD_V3"
    "CONFIG_NFSD_V3_ACL"
    "CONFIG_NFSD_V4"
    "CONFIG_NFSD_V4_2"
    "CONFIG_NFSD_V4_SECURITY_LABEL"
    "CONFIG_NFSD_PNFS"
    
    # NFS Client
    "CONFIG_NFS_FS"
    "CONFIG_NFS_V3"
    "CONFIG_NFS_V3_ACL"
    "CONFIG_NFS_V4"
    "CONFIG_NFS_V4_1"
    "CONFIG_NFS_V4_2"
    
    # Dateisysteme
    "CONFIG_EXT4_FS"
    "CONFIG_EXT4_FS_POSIX_ACL"
    "CONFIG_EXT4_FS_SECURITY"
    "CONFIG_BTRFS_FS"
    "CONFIG_BTRFS_FS_POSIX_ACL"
    "CONFIG_XFS_FS"
    "CONFIG_TMPFS"
    "CONFIG_TMPFS_POSIX_ACL"
    "CONFIG_TMPFS_XATTR"
    
    # Netzwerk (für NFSD essentiell)
    "CONFIG_NET"
    "CONFIG_INET"
    "CONFIG_IPV4"
    "CONFIG_IPV6"
    "CONFIG_SUNRPC"
    "CONFIG_SUNRPC_GSS"
    "CONFIG_LOCKD"
    "CONFIG_LOCKD_V4"
    "CONFIG_GRACE_PERIOD"
    
    # Sicherheit & LSM
    "CONFIG_SECURITY"
    "CONFIG_SECURITY_LSM"
    "CONFIG_SECURITY_PATH"
    
    # BPF Support
    "CONFIG_BPF"
    "CONFIG_BPF_SYSCALL"
    "CONFIG_BPF_JIT"
    "CONFIG_DEBUG_INFO_BTF"
    
    # Debugging
    "CONFIG_DEBUG_KERNEL"
    "CONFIG_DEBUG_INFO"
    "CONFIG_KPROBES"
    "CONFIG_KRETPROBES"
)

# Aktiviere alle Optionen
for OPTION in "${FS_OPTIONS[@]}"; do
    scripts/config --enable "$OPTION" 2>/dev/null || true
done

echo "✓ FS-Optionen aktiviert"

# 3. Aktualisiere .config mit olddefconfig (löst Dependencies)
echo ""
echo "--- Löse Dependencies mit olddefconfig ---"
make olddefconfig > /dev/null 2>&1
echo "✓ Dependencies aufgelöst"

# 4. Deaktiviere CONFIG_WERROR um Warnungen zu ignorieren
scripts/config --disable CONFIG_WERROR 2>/dev/null || true
make olddefconfig > /dev/null 2>&1

# 5. Zeige aktivierte Optionen
echo ""
echo "✅ Aktivierte FS-Optionen:"
echo "--- NFSD ---"
grep -E "^CONFIG_NFSD" "$CONFIG_FILE" | head -5

echo "--- NFS Client ---"
grep -E "^CONFIG_NFS_" "$CONFIG_FILE" | head -5

echo "--- Filesystems ---"
grep -E "^CONFIG_(EXT4|BTRFS|XFS|TMPFS)" "$CONFIG_FILE" | head -5

echo "--- Network ---"
grep -E "^CONFIG_(SUNRPC|LOCKD|INET)" "$CONFIG_FILE" | head -3

echo ""
echo "=== .config erfolgreich erstellt ==="
echo "Pfad: $CONFIG_FILE"
echo "Zeilen: $(wc -l < $CONFIG_FILE)"
