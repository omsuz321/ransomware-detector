#!/bin/bash
set -e

echo "=== DevContainer Setup ==="

if [ -f /work/.devcontainer/kernel_version.env ]; then
    source /work/.devcontainer/kernel_version.env
else
    KERNEL_VERSION=$(uname -r)
    echo "KERNEL_VERSION=$KERNEL_VERSION" > /work/.devcontainer/kernel_version.env
fi

echo "Kernel-Version: $KERNEL_VERSION"

# 1. vmlinux.h
if [ -f /sys/kernel/btf/vmlinux ]; then
    echo "[1/4] Generiere vmlinux.h..."
    mkdir -p /work/include
    bpftool btf dump file /sys/kernel/btf/vmlinux format c > /work/include/vmlinux.h
    echo "      ✓ vmlinux.h erstellt"
fi

# 2. .clangd
echo "[2/4] Generiere .clangd..."
cat > /work/.clangd << EOF
CompileFlags:
  Add:
    # Kernel-Includes (für vmlinux.h und Kernel-Strukturen)
    - --compile-commands-dir=/work/linux-${KERNEL_VERSION}
    - -I/work/linux-${KERNEL_VERSION}/include
    - -I/work/linux-${KERNEL_VERSION}/include/uapi
    - -I/work/linux-${KERNEL_VERSION}/arch/x86/include
    - -I/work/linux-${KERNEL_VERSION}/arch/x86/include/generated
    - -I/work/linux-${KERNEL_VERSION}/arch/x86/include/generated/uapi
    
    # BPF-Includes und Flags
    - -I/work/include
    - -I/work/security/my_lsm/include
    - -I/usr/include/bpf
    - -D__TARGET_ARCH_x86
    - -D__BPF__
    - -target
    - bpf
    # Die "Lebensretter"-Warnungen (statische Analyse)
    - -Wall
    - -Wextra
    - -Wsign-compare      # Zeigt signed/unsigned Fehler!
    - -Wconversion        # Zeigt Datenverlust
    - -Wshorten-64-to-32  # Zeigt Pointer-Truncation
EOF
echo "      ✓ .clangd erstellt"

# 3. Kernel-Source
echo "[3/4] Prüfe Kernel-Source..."
KERNEL_DIR="/work/linux-$KERNEL_VERSION"
if [ ! -d "$KERNEL_DIR" ]; then
    echo "      → Lade Kernel herunter..."
    cd /work
    curl -sSL "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.14.tar.xz" -o kernel.tar.xz
    tar -xJf kernel.tar.xz
    mv linux-6.14 "linux-$KERNEL_VERSION"
    rm kernel.tar.xz
    echo "      ✓ Kernel heruntergeladen"
    
    # Erstelle optimierte FS-Config
    echo "      → Erstelle optimierte .config für FS/NFSD..."
    if [ -f /work/.devcontainer/create_fs_config.sh ]; then
        bash /work/.devcontainer/create_fs_config.sh "$KERNEL_DIR" "$(uname -r)" > /dev/null 2>&1
        echo "      ✓ FS-optimierte .config erstellt"
    else
        echo "      ⚠️ create_fs_config.sh nicht gefunden, nutze defconfig..."
        cd "$KERNEL_DIR"
        make defconfig > /dev/null 2>&1
    fi
else
    echo "      ✓ Kernel vorhanden"
fi

# 4. compile_commands.json (KOMPLETTER BUILD)
echo "[4/4] Kompiliere Kernel und generiere compile_commands.json..."
echo "      ⚠️ Das kann 10-30 Minuten dauern..."
bash /work/.devcontainer/generate_cc_commands.sh

# 5. BPF Skeleton Header generieren
echo "[5/5] Generiere BPF Skeleton Header..."
if [ -d "/work/security/my_lsm" ]; then
    cd /work/security/my_lsm
    
    # Erst BPF-Programm kompilieren
    echo "      → Kompiliere vfs_write.bpf.c..."
    make clean > /dev/null 2>&1 || true
    make > /tmp/bpf_build.log 2>&1 || {
        echo "      ⚠️ BPF-Kompilierung fehlgeschlagen"
        tail -5 /tmp/bpf_build.log
    }
    
    # Dann Skeleton generieren
    if [ -f "vfs_write.bpf.o" ] && [ -f "scripts/gen_skeleton.sh" ]; then
        bash scripts/gen_skeleton.sh > /tmp/gen_skel.log 2>&1 || {
            echo "      ⚠️ Skeleton-Generierung fehlgeschlagen"
            tail -3 /tmp/gen_skel.log
        }
        
        if [ -f "include/vfs_write.skel.h" ]; then
            echo "      ✓ vfs_write.skel.h generiert in /work/security/my_lsm/include/"
        fi
    else
        echo "      ⚠️ vfs_write.bpf.o fehlt, überspringe Skeleton-Generierung"
    fi
    
    cd - > /dev/null
else
    echo "      ⚠️ my_lsm Projekt nicht gefunden"
fi

echo ""
echo "=== Setup abgeschlossen ==="