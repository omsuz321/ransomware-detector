#!/bin/bash
# ==========================================
# BPF KERNEL CONTROL (Clean-Slate Version)
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
log_warn()    { echo -e " ⚠️  ${YELLOW}$1${NC}"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Bitte als root ausführen: sudo $0 ..."
        exit 1
    fi
}

# ==========================================
# Dependency Check
# ==========================================
install_dependencies() {
    echo -e "${YELLOW}Installiere notwendige Pakete...${NC}"
    sudo apt update && sudo apt install -y clang llvm libbpf-dev bpftool make linux-tools-$(uname -r) linux-headers-$(uname -r)
}

check_dependencies() {
    local missing=0
    if ! command -v clang &> /dev/null; then missing=1; fi
    if ! command -v bpftool &> /dev/null; then missing=1; fi
    if ! command -v make &> /dev/null; then missing=1; fi
    if [ ! -d "/lib/modules/$(uname -r)/build" ]; then missing=1; fi

    if [ $missing -eq 1 ]; then
        echo -e "${YELLOW}Tools fehlen. Installieren? [J/n]${NC}"
        read -r response
        [[ -z "$response" || "$response" =~ ^[JjYy]$ ]] && install_dependencies || exit 1
    fi
}

ensure_bpffs() {
    if ! mount | grep -q " /sys/fs/bpf "; then
        log_info "Mounte /sys/fs/bpf ..."
        mount -t bpf bpf /sys/fs/bpf
    fi
}

# ==========================================
# 1. BUILD & CLEAN
# ==========================================
do_clean() {
    echo -e "${BLUE}=== Räume Build-Dateien auf (Clean) ===${NC}"
    if command -v make &> /dev/null; then
        make clean-bpf
        log_success "Aufräumen erfolgreich."
    else
        log_warn "'make' nicht gefunden, überspringe clean."
    fi
}

do_build() {
    check_dependencies
    echo -e "${BLUE}=== Baue eBPF Objekt ===${NC}"
    make clean-bpf || true
    make bpf
    
    if [ -f "$BPF_OBJ" ]; then
        log_success "Build erfolgreich."
    else
        log_error "Build fehlgeschlagen."
        exit 1
    fi
}

# ==========================================
# 2. UNLOAD (Mit gründlicher Prüfung)
# ==========================================
do_unload() {
    check_root
    echo -e "${BLUE}=== Entlade eBPF Programme ===${NC}"

    local checks_failed=0

    # 1. Pins entfernen
    if [ -d "$PIN_DIR" ]; then
        rm -rf "$PIN_DIR"
        log_success "Pin-Verzeichnis gelöscht ($PIN_DIR)."
    else
        log_info "Kein Pin-Verzeichnis gefunden (schon sauber?)."
    fi

    # 2. Prüfen auf "Geister"-Maps (Zombie Maps)
    if command -v bpftool &> /dev/null; then
        sleep 0.2
        if bpftool prog show | grep -q "vfs_write"; then
            log_warn "ACHTUNG: Es scheinen noch BPF-Programme im Kernel zu hängen!"
            checks_failed=1
        elif bpftool map show | grep -q "vfs_write"; then
            log_warn "ACHTUNG: Die BPF-Maps sind noch im Speicher (Ref-Count > 0)."
            checks_failed=1
        else
            log_success "Kernel ist sauber. Alle Maps und Programme entfernt."
        fi
    fi

    if [ $checks_failed -eq 1 ]; then
        return 1 
    else
        return 0
    fi
}

# ==========================================
# 3. LOAD (Clean Slate)
# ==========================================
do_load() {
    check_root
    check_dependencies
    ensure_bpffs

    # IMMER neu bauen bei "load" (Korrektur integriert)
    echo -e "${BLUE}=== Erzwinge Neu-Bauen vor dem Laden ===${NC}"
    do_build

    # ZWANGS-BEREINIGUNG
    if [ -d "$PIN_DIR" ]; then
        log_info "Alter Zustand erkannt. Führe Reset durch..."
        do_unload || log_warn "Konnte alte Instanz nicht vollständig entfernen (siehe oben)."
    fi

    echo -e "${BLUE}=== Lade eBPF Programme (Neustart) ===${NC}"
    mkdir -p "$PIN_DIR"

    if bpftool prog loadall "$BPF_OBJ" "$PIN_DIR" autoattach; then
        log_success "Programme geladen und Maps neu initialisiert."
        echo -e "   📍 Pinned unter: $PIN_DIR"
    else
        log_error "Fehler beim Laden."
        rmdir "$PIN_DIR" 2>/dev/null || true
        exit 1
    fi
}

# ==========================================
# 4. STATUS
# ==========================================
do_status() {
    echo -e "${BLUE}=== Status ===${NC}"
    
    if [ -d "$PIN_DIR" ]; then
        echo -e "${GREEN}Status: AKTIV (Pinned)${NC}"
        echo "--------------------------------"
        bpftool prog show | grep -C 1 "$PIN_DIR" || echo "Keine Details lesbar."
        echo "--------------------------------"
        echo -e "Maps:"
        bpftool map show | grep -C 1 "$PIN_DIR" || echo "Keine Maps gefunden (ungewöhnlich)."
    else
        echo -e "${YELLOW}Status: INAKTIV (Nicht geladen)${NC}"
    fi
}

# ==========================================
# MAIN
# ==========================================
case "${1:-}" in
    build)  do_build ;;
    clean)  do_clean ;;  # NEU
    load)   do_load ;;
    unload) do_unload ;;
    status) do_status ;;
    help|*) echo "Usage: sudo $0 {build|clean|load|unload|status}"; exit 1 ;;
esac