#!/bin/bash
set -e

# filepath: /work/.devcontainer/generate_cc_commands.sh

# KONFIGURATION
if [ -f /work/.devcontainer/kernel_version.env ]; then
    source /work/.devcontainer/kernel_version.env
else
    KERNEL_VERSION=$(uname -r)
fi

KERNEL_DIR="/work/linux-$KERNEL_VERSION"
CONFIG_FILE="$KERNEL_DIR/.config"
TARGET_PROJECT="/work/security/my_lsm"
TARGET_CCJSON="$TARGET_PROJECT/compile_commands.json"

echo "=== Kompiliere Kernel für compile_commands.json ==="

# 1. Verzeichnis prüfen
if [ ! -d "$KERNEL_DIR" ]; then
    echo "❌ Fehler: $KERNEL_DIR nicht gefunden!"
    echo ""
    read -p "Drücke Enter zum Beenden..."
    exit 1
fi

cd "$KERNEL_DIR"

# 2. .config vorbereiten - NUTZE HOST-CONFIG
if [ ! -f "$CONFIG_FILE" ]; then
    echo "--- Kopiere .config vom Host-System ---"
    HOST_CONFIG="/boot/config-$(uname -r)"
    
    if [ -f "$HOST_CONFIG" ]; then
        cp "$HOST_CONFIG" "$CONFIG_FILE"
        echo "✓ Host-Config kopiert von $HOST_CONFIG"
    else
        echo "⚠️ Host-Config nicht gefunden, nutze defconfig..."
        make defconfig > /dev/null 2>&1
        echo "✓ defconfig verwendet"
    fi
fi

echo "--- Konfiguriere Kernel (.config) ---"
make olddefconfig > /dev/null 2>&1
sed -i 's/^CONFIG_WERROR=y/# CONFIG_WERROR is not set/' .config
make olddefconfig > /dev/null 2>&1
echo "✓ .config konfiguriert"

# 3. KOMPLETTER Kernel-Build
echo "--- Starte kompletten Kernel-Build ---"
echo "Nutze $(nproc) Kerne für Parallel-Build..."
CORES=$(nproc)

# Build mit Fehlertoleranz
if make -j$CORES 2>&1 | tee /tmp/kernel_build.log; then
    echo "✅ Build erfolgreich abgeschlossen"
else
    echo "⚠️ Build hatte Fehler, versuche dennoch weiter..."
    tail -20 /tmp/kernel_build.log
fi

# 4. compile_commands.json generieren
echo "--- Generiere compile_commands.json ---"
if [ -f "scripts/clang-tools/gen_compile_commands.py" ]; then
    python3 scripts/clang-tools/gen_compile_commands.py > /tmp/gen_cc.log 2>&1
    
    if [ -f "compile_commands.json" ]; then
        echo "✅ compile_commands.json erzeugt: $(wc -l < compile_commands.json) Zeilen"
        
        # 5. Kopiere ins Projekt
        if [ -d "$TARGET_PROJECT" ]; then
            mkdir -p "$TARGET_PROJECT"
            cp "$KERNEL_DIR/compile_commands.json" "$TARGET_CCJSON"
            echo "✅ Kopiert nach $TARGET_CCJSON"
            
            # eBPF-Einträge hinzufügen falls Script existiert
            if [ -f "$TARGET_PROJECT/add_bpf_to_compile_commands.sh" ]; then
                cd "$TARGET_PROJECT"
                ./add_bpf_to_compile_commands.sh ebpfTest.c compile_commands.json
                cd - > /dev/null
                echo "✅ eBPF-Einträge hinzugefügt"
            fi
        else
            echo "⚠️ $TARGET_PROJECT nicht gefunden"
        fi
    else
        echo "❌ compile_commands.json nicht erzeugt"
        cat /tmp/gen_cc.log
        echo ""
        read -p "Drücke Enter zum Beenden..."
        exit 1
    fi
else
    echo "❌ gen_compile_commands.py nicht gefunden"
    echo ""
    read -p "Drücke Enter zum Beenden..."
    exit 1
fi

echo ""
echo "=== Setup abgeschlossen ==="
echo ""
read -p "Drücke Enter zum Beenden..."