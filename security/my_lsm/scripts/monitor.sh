#!/bin/bash
# ==========================================
# Fileops Monitor Control Script
# Builds + Loads + Runs BPF Logger
# ==========================================

set -e

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

MONITOR_BPF_OBJ="src/monitor/fileops_lsm.bpf.o"
MONITOR_LOG_BIN="src/monitor/fileops_logger"
PIN_DIR="/sys/fs/bpf/fileops_logger"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
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
    apt update && apt install -y clang llvm libbpf-dev bpftool make \
        linux-headers-$(uname -r) build-essential libelf-dev zlib1g-dev gcc
}

check_dependencies() {
    local missing=0
    if ! command -v clang &> /dev/null; then missing=1; fi
    if ! command -v bpftool &> /dev/null; then missing=1; fi
    if ! command -v make &> /dev/null; then missing=1; fi
    if ! command -v gcc &> /dev/null; then missing=1; fi

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
# 1. BUILD
# ==========================================
do_build() {
    check_dependencies
    echo -e "${BLUE}=== Baue Fileops Monitor BPF + Userspace ===${NC}"
    make clean-monitor || true
    make monitor
    
    if [ -f "$MONITOR_BPF_OBJ" ] && [ -f "$MONITOR_LOG_BIN" ]; then
        log_success "Build erfolgreich."
    else
        log_error "Build fehlgeschlagen."
        exit 1
    fi
}

# ==========================================
# 2. UNLOAD (Cleanup)
# ==========================================
do_unload() {
    check_root
    echo -e "${BLUE}=== Entlade BPF Programme ===${NC}"

    # Pin-Verzeichnis entfernen
    if [ -d "$PIN_DIR" ]; then
        rm -rf "$PIN_DIR"
        log_success "Pin-Verzeichnis gelöscht ($PIN_DIR)."
    else
        log_info "Kein Pin-Verzeichnis gefunden (schon sauber?)."
    fi

    # Kurze Pause für RCU cleanup
    sleep 0.2

    # Prüfe auf verbleibende Programme
    if command -v bpftool &> /dev/null; then
        if bpftool prog show | grep -q "fileops_lsm"; then
            log_warn "Warnung: BPF-Programme noch aktiv (ein Logger läuft noch?)."
            return 1
        else
            log_success "Kernel ist sauber."
        fi
    fi

    return 0
}

# ==========================================
# 3. LOAD
# ==========================================
do_load() {
    check_root
    ensure_bpffs

    if [ ! -f "$MONITOR_BPF_OBJ" ]; then
        do_build
    fi

    # Cleanup: alte Instanz entfernen
    if [ -d "$PIN_DIR" ]; then
        log_info "Alter Zustand erkannt. Führe Reset durch..."
        do_unload || log_warn "Konnte alte Instanz nicht vollständig entfernen."
    fi

    echo -e "${BLUE}=== Lade BPF Programme ===${NC}"
    mkdir -p "$PIN_DIR"

    if bpftool prog loadall "$MONITOR_BPF_OBJ" "$PIN_DIR" autoattach; then
        log_success "BPF Programme geladen und angehängt."
        echo -e "   📍 Pinned unter: $PIN_DIR"
    else
        log_error "Fehler beim Laden."
        rmdir "$PIN_DIR" 2>/dev/null || true
        exit 1
    fi
}

# ==========================================
# 4. RUN (Build + Load + Start Logger)
# ==========================================
do_run() {
    check_root
    check_dependencies

    local output="/var/log/nfs_fileops.csv"
    local ring_mb=256

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -o|--output)
                output="$2"
                shift 2
                ;;
            --ring-mb)
                ring_mb="$2"
                shift 2
                ;;
            *)
                log_error "Unbekannte Option: $1"
                echo "Usage: sudo $0 run [-o FILE] [--ring-mb N]"
                exit 1
                ;;
        esac
    done

    # Build
    do_build

    # Load BPF
    do_load

    # Check if logger binary exists
    if [ ! -f "$MONITOR_LOG_BIN" ]; then
        log_error "Logger binary nicht gefunden: $MONITOR_LOG_BIN"
        exit 1
    fi

    # Ensure log directory exists
    log_dir=$(dirname "$output")
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir"
    fi

    # Start logger with Ctrl+C handling
    echo -e "${BLUE}=== Starte Logger ===${NC}"
    log_success "CSV wird geschrieben zu: $output"
    log_info "Drücke Ctrl+C zum Stoppen..."
    echo ""

    local logger_args="-o $output"
    [ "$ring_mb" != "256" ] && logger_args="$logger_args --ring-mb $ring_mb"

    # Run logger (will exit on Ctrl+C)
    "$MONITOR_LOG_BIN" $logger_args

    # Cleanup after logger stops
    echo ""
    log_info "Logger gestoppt. Entlade BPF..."
    do_unload || true

    log_success "Fertig. CSV liegt unter: $output"
}

# ==========================================
# 5. STATUS
# ==========================================
do_status() {
    echo -e "${BLUE}=== Monitor Status ===${NC}"
    
    if [ -d "$PIN_DIR" ]; then
        echo -e "${GREEN}Status: AKTIV (Pinned)${NC}"
        echo "--------------------------------"
        if bpftool prog show | grep -q "fileops_lsm"; then
            bpftool prog show | grep -B1 -A1 "fileops_lsm" || echo "Keine Details lesbar."
        fi
        echo "--------------------------------"
    else
        echo -e "${YELLOW}Status: INAKTIV (Nicht geladen)${NC}"
    fi
}

# ==========================================
# MAIN
# ==========================================
usage() {
    cat << EOF
Usage: sudo $0 {build|load|unload|run|status|help}

Commands:
  build              Build BPF + Userspace binaries only
  load               Load BPF programmes into kernel
  unload             Unload BPF programmes from kernel
  run [opts]         Build + Load + Start logger (full pipeline)
  status             Show current monitor status

Run options:
  -o FILE            Output CSV file (default: /var/log/nfs_fileops.csv)
  --ring-mb N        Ringbuffer size in MiB (default: 256)

Examples:
  sudo $0 build
  sudo $0 run
  sudo $0 run -o /tmp/fileops.csv --ring-mb 512

EOF
}

case "${1:-}" in
    build)  do_build ;;
    load)   do_load ;;
    unload) do_unload ;;
    run)    shift; do_run "$@" ;;
    status) do_status ;;
    help)   usage ;;
    *)      usage; exit 1 ;;
esac
