#!/bin/bash
# ==========================================
# BPF KERNEL CONTROL (mit Auto-Install, loadall & besserem Status)
# ==========================================

set -e

# Pfade bestimmen
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# Variablen
BPF_OBJ="vfs_write.bpf.o"
PIN_DIR="/sys/fs/bpf/vfs_write_logger"

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Hilfsfunktionen
log_info()    { echo -e " ℹ️  $1"; }
log_success() { echo -e " ✅ ${GREEN}$1${NC}"; }
log_error()   { echo -e " ❌ ${RED}$1${NC}"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Bitte als root ausführen: sudo $0 ..."
        exit 1
    fi
}

# ==========================================
# Dependency Check & Installation
# ==========================================
install_dependencies() {
    echo -e "${YELLOW}Folgende Pakete werden installiert:${NC}"
    echo "  clang llvm libbpf-dev bpftool make linux-tools-$(uname -r) linux-headers-$(uname -r)"
    echo ""
    
    if sudo apt update && sudo apt install -y \
        clang llvm libbpf-dev bpftool make \
        linux-tools-$(uname -r) linux-headers-$(uname -r); then
        log_success "Abhängigkeiten erfolgreich installiert."
    else
        log_error "Installation fehlgeschlagen. Bitte manuell prüfen."
        exit 1
    fi
}

check_dependencies() {
    local missing=0
    
    # Prüfe auf wichtige Binaries
    if ! command -v clang &> /dev/null; then missing=1; fi
    if ! command -v bpftool &> /dev/null; then missing=1; fi
    if ! command -v make &> /dev/null; then missing=1; fi
    
    # Prüfe auf Kernel Header Ordner
    if [ ! -d "/lib/modules/$(uname -r)/build" ]; then missing=1; fi

    if [ $missing -eq 1 ]; then
        echo -e "${YELLOW}⚠ Es scheinen notwendige Tools (clang, bpftool, Header, ...) zu fehlen.${NC}"
        echo -n "Sollen diese jetzt installiert werden? [J/n]: "
        read -r response
        
        # Standard ist Ja bei Enter
        if [[ -z "$response" || "$response" =~ ^[JjYy]$ ]]; then
            install_dependencies
        else
            log_error "Abbruch. Ohne Tools kann nicht gebaut/geladen werden."
            exit 1
        fi
    fi
}

# ==========================================
# 1. BUILD (Nur make bpf)
# ==========================================
do_build() {
    check_dependencies
    
    echo -e "${BLUE}=== Baue eBPF Objekt (.o) ===${NC}"
    make clean-bpf || true
    make bpf
    
    if [ -f "$BPF_OBJ" ]; then
        log_success "Build erfolgreich: $BPF_OBJ erstellt."
    else
        log_error "Build fehlgeschlagen."
        exit 1
    fi
}

# ==========================================
# Hilfsfunktion: bpffs sicherstellen
# ==========================================
ensure_bpffs() {
    if ! mount | grep -q " /sys/fs/bpf "; then
        log_info "bpffs nicht gemountet, mounte /sys/fs/bpf ..."
        mount -t bpf bpf /sys/fs/bpf
    fi
}

# ==========================================
# 2. LOAD (In den Kernel laden & pinnen)
# ==========================================
do_load() {
    check_root
    check_dependencies
    ensure_bpffs

    if [ ! -f "$BPF_OBJ" ]; then
        log_info "Objekt $BPF_OBJ nicht gefunden. Starte Build..."
        do_build
    fi

    # Prüfen, ob schon etwas unter PIN_DIR gepinnt ist
    if command -v bpftool &> /dev/null; then
        if bpftool prog show | grep -q "$PIN_DIR" ; then
            log_info "Programm(e) scheinen bereits geladen zu sein (Pins unter $PIN_DIR gefunden)."
            do_status
            exit 0
        fi
    fi

    echo -e "${BLUE}=== Lade eBPF Programme in den Kernel (loadall) ===${NC}"
    mkdir -p "$PIN_DIR"

    # loadall: lädt ALLE Programme aus dem Objekt & pinnt sie im Verzeichnis
    if bpftool prog loadall "$BPF_OBJ" "$PIN_DIR" autoattach; then
        log_success "eBPF Programme erfolgreich geladen und (auto)attached."
        echo "   (Programme sind jetzt unter $PIN_DIR gepinnt)"
    else
        log_error "Fehler beim Laden mit bpftool (loadall)."
        rmdir "$PIN_DIR" 2>/dev/null || true
        exit 1
    fi
}

# ==========================================
# 3. UNLOAD (Entfernen)
# ==========================================
do_unload() {
    check_root
    
    echo -e "${BLUE}=== Entlade eBPF Programme ===${NC}"

    if [ -d "$PIN_DIR" ]; then
        rm -rf "$PIN_DIR"
        log_success "Pins entfernt (Pin-Dir gelöscht: $PIN_DIR)."
    else
        log_info "Kein Pin-Dir gefunden, nichts zu entfernen."
    fi
    
    # Sicherheitscheck: hängt noch irgendwas unter diesem Pfad?
    if command -v bpftool &> /dev/null; then
        if bpftool prog show | grep -q "$PIN_DIR" ; then
            echo -e "${YELLOW}Warnung: Es scheinen noch Reste im Kernel zu sein (Pins mit $PIN_DIR im Pfad).${NC}"
            bpftool prog show | grep "$PIN_DIR" || true
        else
            log_info "Keine weiteren Programme mit Pfad $PIN_DIR gefunden."
        fi
    fi
}

# ==========================================
# 4. STATUS
# ==========================================
do_status() {
    echo -e "${BLUE}=== Status ===${NC}"
    
    if ! command -v bpftool &> /dev/null; then
        echo -e "${YELLOW}bpftool nicht installiert, kann keinen Status anzeigen.${NC}"
        return
    fi

    # Prüfen, ob Programme unter PIN_DIR gepinnt sind
    if bpftool prog show | grep -q "$PIN_DIR" ; then
        echo -e "${GREEN}Status: GELADEN (Programme unter $PIN_DIR gepinnt)${NC}"
        echo ""
        echo "Details (bpftool):"
        bpftool prog show | grep "$PIN_DIR" || echo "Konnte Details nicht lesen."
    else
        echo -e "${YELLOW}Status: NICHT GELADEN (keine Pins unter $PIN_DIR gefunden)${NC}"
    fi
}

# ==========================================
# MAIN
# ==========================================
case "${1:-}" in
    build)  do_build ;;
    load)   do_load ;;
    unload) do_unload ;;
    status) do_status ;;
    help|*) echo "Usage: sudo $0 {build|load|unload|status}"; exit 1 ;;
esac
