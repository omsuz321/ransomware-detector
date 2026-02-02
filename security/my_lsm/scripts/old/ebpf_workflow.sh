#!/bin/bash
# eBPF Workflow: Check → Download Dependencies → Compile → Inject in Kernel
# Ein Skript für den kompletten Workflow

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parsiere Parameter
ACTION="all"
EBPF_FILE="src/ebpf/ebpfTest.c"

# Erste Argument könnte Action sein oder Datei
if [ -n "$1" ]; then
    case "$1" in
        check|deps|compile|inject|remove|all)
            ACTION="$1"
            EBPF_FILE="${2:-src/ebpf/ebpfTest.c}"
            ;;
        *)
            EBPF_FILE="$1"
            ACTION="${2:-all}"
            ;;
    esac
fi

EBPF_OBJ="${EBPF_FILE%.c}.o"

echo -e "${BLUE}=== eBPF Workflow ===${NC}\n"

# ============================================================================
# SCHRITT 0: KOMPATIBILITÄT CHECKEN
# ============================================================================

check_compatibility() {
    echo -e "${BLUE}[0/4] Kompatibilität überprüfen...${NC}\n"
    
    KERNEL=$(uname -r)
    ARCH=$(uname -m)
    
    echo "📊 System-Info:"
    echo "  Kernel: $KERNEL"
    echo "  Architektur: $ARCH"
    
    # Kernel >= 5.8?
    KERNEL_MAJOR=$(echo $KERNEL | cut -d. -f1)
    KERNEL_MINOR=$(echo $KERNEL | cut -d. -f2)
    
    if [ "$KERNEL_MAJOR" -lt 5 ] || ([ "$KERNEL_MAJOR" -eq 5 ] && [ "$KERNEL_MINOR" -lt 8 ]); then
        echo -e "${RED}❌ Kernel zu alt! Benötigt >= 5.8${NC}"
        return 1
    fi
    
    # BTF vorhanden?
    if [ ! -f /sys/kernel/btf/vmlinux ]; then
        echo -e "${RED}❌ BTF nicht vorhanden: /sys/kernel/btf/vmlinux${NC}"
        return 1
    fi
    
    # Clang installiert?
    if ! command -v clang &> /dev/null; then
        echo -e "${RED}❌ clang nicht installiert${NC}"
        return 1
    fi
    
    # libbpf installiert?
    if [ ! -d /usr/include/bpf ]; then
        echo -e "${RED}❌ libbpf-dev nicht installiert${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Alle Checks bestanden${NC}\n"
    return 0
}

# ============================================================================
# SCHRITT 1: DEPENDENCIES DOWNLOADEN & INSTALLIEREN
# ============================================================================

install_dependencies() {
    echo -e "${BLUE}[1/4] Installiere fehlende Dependencies...${NC}\n"
    
    MISSING=""
    
    if ! command -v clang &> /dev/null; then
        MISSING="$MISSING clang"
    fi
    
    if ! command -v make &> /dev/null; then
        MISSING="$MISSING build-essential"
    fi
    
    if [ ! -d /usr/include/bpf ]; then
        MISSING="$MISSING libbpf-dev"
    fi
    
    if ! command -v bpftool &> /dev/null; then
        MISSING="$MISSING linux-tools-generic"
    fi
    
    if [ -z "$MISSING" ]; then
        echo -e "${GREEN}✅ Alle Dependencies bereits installiert${NC}\n"
        return 0
    fi
    
    echo "📦 Fehlend:$MISSING"
    echo -e "${YELLOW}Installation wird durchgeführt...${NC}\n"
    
    sudo apt update
    sudo apt install -y clang build-essential libbpf-dev linux-tools-generic
    
    echo -e "${GREEN}✅ Dependencies installiert${NC}\n"
}

# ============================================================================
# SCHRITT 2: KOMPILIERE eBPF
# ============================================================================

compile_ebpf() {
    echo -e "${BLUE}[2/4] Kompiliere eBPF-Programm...${NC}\n"
    
    if [ ! -f "$EBPF_FILE" ]; then
        echo -e "${RED}❌ Datei nicht gefunden: $EBPF_FILE${NC}"
        return 1
    fi
    
    echo "📝 Quelle: $EBPF_FILE"
    
    if ! make ebpf &>/dev/null; then
        echo -e "${RED}❌ Kompilation fehlgeschlagen${NC}"
        make ebpf
        return 1
    fi
    
    if [ ! -f "$EBPF_OBJ" ]; then
        echo -e "${RED}❌ Output nicht gefunden: $EBPF_OBJ${NC}"
        return 1
    fi
    
    SIZE=$(du -h "$EBPF_OBJ" | cut -f1)
    echo -e "${GREEN}✅ Kompiliert${NC}: $EBPF_OBJ ($SIZE)\n"
}

# ============================================================================
# SCHRITT 3: INJIZIERE IN KERNEL (dynamisch)
# ============================================================================

inject_into_kernel() {
    echo -e "${BLUE}[3/4] Injiziere in Kernel...${NC}\n"
    
    if [ ! -f "$EBPF_OBJ" ]; then
        echo -e "${RED}❌ eBPF-Datei nicht gefunden: $EBPF_OBJ${NC}"
        return 1
    fi
    
    echo "📖 Datei: $EBPF_OBJ"

    if ! command -v bpftool &> /dev/null; then
        echo -e "${YELLOW}⚠️  bpftool nicht vorhanden${NC}"
        echo "   Installiere: sudo apt install linux-tools-generic"
        return 0
    fi

    local PIN_DIR="/sys/fs/bpf/vfs_read_logger"

    echo "🚀 Lade mit bpftool (fentry/fexit)..."
    sudo rm -rf "$PIN_DIR"
    sudo mkdir -p "$PIN_DIR"

    sudo bpftool prog loadall "$EBPF_OBJ" "$PIN_DIR"

    local FENTRY_ID
    local FEXIT_ID
    FENTRY_ID=$(sudo bpftool prog show | awk '/name vfs_read_enter/ {print $1}' | tr -d ':')
    FEXIT_ID=$(sudo bpftool prog show | awk '/name vfs_read_exit/ {print $1}' | tr -d ':')

    if [ -z "$FENTRY_ID" ] || [ -z "$FEXIT_ID" ]; then
        echo -e "${RED}❌ fentry/fexit Programme nicht gefunden${NC}"
        return 1
    fi

    sudo bpftool prog attach "$FENTRY_ID" fentry vfs_read
    sudo bpftool prog attach "$FEXIT_ID" fexit vfs_read

    echo -e "${GREEN}✅ Erfolgreich geladen und attached${NC}\n"
    return 0
}

# ============================================================================
# SCHRITT 4: ANZEIGE - WIE MAN ENTFERNT
# ============================================================================

show_removal_commands() {
    echo -e "${BLUE}[4/4] Entfernungs-Befehle${NC}\n"
    
    echo "📝 Um das eBPF-Programm zu entfernen:"
    echo ""
    echo "  Pins löschen (entlädt auch Programme):"
    echo "    sudo rm -rf /sys/fs/bpf/vfs_read_logger"
    echo ""
    echo "  Optional: direkt per ID löschen"
    echo "    bpftool prog show | grep vfs_read"
    echo "    bpftool prog detach id <ID> fentry vfs_read"
    echo "    bpftool prog detach id <ID> fexit  vfs_read"
    echo ""
}

# ============================================================================
# MAIN: WÄHLE AKTION
# ============================================================================

cd "$(dirname "$0")/.." || exit 1

case "$ACTION" in
    "check")
        check_compatibility
        ;;
    "deps")
        install_dependencies
        ;;
    "compile")
        compile_ebpf
        ;;
    "inject")
        inject_into_kernel
        ;;
    "remove")
        show_removal_commands
        ;;
    "all"|*)
        check_compatibility || exit 1
        install_dependencies || exit 1
        compile_ebpf || exit 1
        inject_into_kernel || exit 1
        show_removal_commands
        
        echo -e "${GREEN}=== WORKFLOW ERFOLGREICH ===${NC}"
        echo ""
        echo "✅ eBPF ist aktiv im Kernel (oder bereit zum Laden)"
        echo ""
        ;;
esac
