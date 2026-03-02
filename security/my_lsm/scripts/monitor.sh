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
ENABLE_VFS_ITER_WRITE=1
ENABLE_ENTROPY=1
ENABLE_BPF_LOG=0
MONITOR_BG_PID_FILE="/tmp/fileops_logger.pid"

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

parse_vfs_iter_write_flag() {
    case "$1" in
        --vfs-iter-write)
            ENABLE_VFS_ITER_WRITE=1
            ;;
        --no-vfs-iter-write)
            ENABLE_VFS_ITER_WRITE=0
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

parse_entropy_flag() {
    case "$1" in
        --entropy)
            ENABLE_ENTROPY=1
            ;;
        --no-entropy)
            ENABLE_ENTROPY=0
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

parse_bpf_log_flag() {
    case "$1" in
        --bpf-log)
            ENABLE_BPF_LOG=1
            ;;
        --no-bpf-log)
            ENABLE_BPF_LOG=0
            ;;
        *)
            return 1
            ;;
    esac
    return 0
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
# 1. BUILD & CLEAN
# ==========================================
do_clean() {
    echo -e "${BLUE}=== Räume Build-Dateien auf (Clean) ===${NC}"
    if command -v make &> /dev/null; then
        make clean-monitor
        log_success "Aufräumen erfolgreich."
    else
        log_warn "'make' nicht gefunden, überspringe clean."
    fi
}

do_build() {
    check_dependencies

    while [[ $# -gt 0 ]]; do
        case $1 in
            --vfs-iter-write|--no-vfs-iter-write)
                parse_vfs_iter_write_flag "$1"
                shift
                ;;
            --entropy|--no-entropy)
                parse_entropy_flag "$1"
                shift
                ;;
            --bpf-log|--no-bpf-log)
                parse_bpf_log_flag "$1"
                shift
                ;;
            *)
                log_error "Unbekannte Option: $1"
                echo "Usage: $0 build [--vfs-iter-write|--no-vfs-iter-write] [--entropy|--no-entropy] [--bpf-log|--no-bpf-log]"
                exit 1
                ;;
        esac
    done

    echo -e "${BLUE}=== Baue Fileops Monitor BPF + Userspace ===${NC}"
    if [ "$ENABLE_VFS_ITER_WRITE" = "1" ]; then
        log_info "vfs_iter_write hook: aktiviert"
    else
        log_info "vfs_iter_write hook: deaktiviert"
    fi
    if [ "$ENABLE_ENTROPY" = "1" ]; then
        log_info "entropy: aktiviert"
    else
        log_info "entropy: deaktiviert"
    fi
    if [ "$ENABLE_BPF_LOG" = "1" ]; then
        log_info "bpf log (BPF_LOG): aktiviert"
    else
        log_info "bpf log (BPF_LOG): deaktiviert (default)"
    fi
    make clean-monitor || true
    make monitor \
        ENABLE_VFS_ITER_WRITE="$ENABLE_VFS_ITER_WRITE" \
        ENABLE_ENTROPY="$ENABLE_ENTROPY" \
        ENABLE_BPF_LOG="$ENABLE_BPF_LOG"
    
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

    if pgrep -f "fileops_logger" > /dev/null; then
        log_info "Beende verbleibende Logger-Prozesse..."
        pkill -f "fileops_logger" || true
        sleep 0.5
    fi

    if [ -d "$PIN_DIR" ]; then
        rm -rf "$PIN_DIR"
        log_success "Pin-Verzeichnis gelöscht ($PIN_DIR)."
    else
        log_info "Kein Pin-Verzeichnis gefunden (schon sauber?)."
    fi

    sleep 0.2

    if command -v bpftool &> /dev/null; then
        if bpftool prog show | grep -q "fileops_lsm"; then
            log_warn "Warnung: BPF-Programme noch aktiv (ein Logger läuft noch?)."
            return 1
        else
            log_success "Kernel ist sauber."
        fi
    fi
    rm -f "$MONITOR_BG_PID_FILE" 2>/dev/null || true
    return 0
}

# ==========================================
# 3. LOAD
# ==========================================
do_load() {
    check_root
    check_dependencies
    ensure_bpffs

    while [[ $# -gt 0 ]]; do
        case $1 in
            --vfs-iter-write|--no-vfs-iter-write)
                parse_vfs_iter_write_flag "$1"
                shift
                ;;
            --entropy|--no-entropy)
                parse_entropy_flag "$1"
                shift
                ;;
            --bpf-log|--no-bpf-log)
                parse_bpf_log_flag "$1"
                shift
                ;;
            *)
                log_error "Unbekannte Option: $1"
                echo "Usage: sudo $0 load [--vfs-iter-write|--no-vfs-iter-write] [--entropy|--no-entropy] [--bpf-log|--no-bpf-log]"
                exit 1
                ;;
        esac
    done

    # IMMER neu bauen bei "load" (Korrektur integriert)
    echo -e "${BLUE}=== Erzwinge Neu-Bauen vor dem Laden ===${NC}"
    do_build

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
# 4. RUN (Build + Start Logger via Skeleton)
# ==========================================
do_run() {
    check_root
    check_dependencies

    local output="/var/log/nfs_fileops.csv"
    local ring_mb=256
    local output_set=0

    while [[ $# -gt 0 ]]; do
        case $1 in
            -o|--output)
                if [[ $# -lt 2 ]]; then
                    log_error "Fehlender Wert für $1"
                    echo "Usage: sudo $0 run [-o FILE|FILE] [--ring-mb N] [--vfs-iter-write|--no-vfs-iter-write] [--entropy|--no-entropy] [--bpf-log|--no-bpf-log]"
                    exit 1
                fi
                output="$2"
                output_set=1
                shift 2
                ;;
            --ring-mb)
                if [[ $# -lt 2 ]]; then
                    log_error "Fehlender Wert für --ring-mb"
                    echo "Usage: sudo $0 run [-o FILE|FILE] [--ring-mb N] [--vfs-iter-write|--no-vfs-iter-write] [--entropy|--no-entropy] [--bpf-log|--no-bpf-log]"
                    exit 1
                fi
                ring_mb="$2"
                shift 2
                ;;
            --vfs-iter-write|--no-vfs-iter-write)
                parse_vfs_iter_write_flag "$1"
                shift
                ;;
            --entropy|--no-entropy)
                parse_entropy_flag "$1"
                shift
                ;;
            --bpf-log|--no-bpf-log)
                parse_bpf_log_flag "$1"
                shift
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    if [ "$output_set" = "0" ]; then
                        output="$1"
                        output_set=1
                        shift
                    else
                        log_error "Zu viele Positionsargumente: $1"
                        echo "Usage: sudo $0 run [-o FILE|FILE] [--ring-mb N] [--vfs-iter-write|--no-vfs-iter-write] [--entropy|--no-entropy] [--bpf-log|--no-bpf-log]"
                        exit 1
                    fi
                done
                ;;
            -*)
                log_error "Unbekannte Option: $1"
                echo "Usage: sudo $0 run [-o FILE|FILE] [--ring-mb N] [--vfs-iter-write|--no-vfs-iter-write] [--entropy|--no-entropy] [--bpf-log|--no-bpf-log]"
                exit 1
                ;;
            *)
                if [ "$output_set" = "0" ]; then
                    output="$1"
                    output_set=1
                    shift
                else
                    log_error "Zu viele Positionsargumente: $1"
                    echo "Usage: sudo $0 run [-o FILE|FILE] [--ring-mb N] [--vfs-iter-write|--no-vfs-iter-write] [--entropy|--no-entropy] [--bpf-log|--no-bpf-log]"
                    exit 1
                fi
                ;;
        esac
    done

    do_build

    log_info "Setze alten Zustand zurück..."
    do_unload || true

    if [ ! -f "$MONITOR_LOG_BIN" ]; then
        log_error "Logger binary nicht gefunden: $MONITOR_LOG_BIN"
        exit 1
    fi

    log_dir=$(dirname "$output")
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir"
    fi

    echo -e "${BLUE}=== Starte Logger ===${NC}"
    log_success "CSV wird geschrieben zu: $output"
    log_info "Drücke Ctrl+C zum Stoppen..."
    echo ""

    local logger_args="-o $output"
    [ "$ring_mb" != "256" ] && logger_args="$logger_args --ring-mb $ring_mb"

    "$MONITOR_LOG_BIN" $logger_args

    echo ""
    log_info "Logger gestoppt. Entlade BPF..."
    do_unload || true

    log_success "Fertig. CSV liegt unter: $output"
}

do_run_bg() {
    check_root
    check_dependencies

    local output="/var/log/nfs_fileops.csv"
    local ring_mb=256
    local output_set=0
    local stdout_log="/tmp/fileops_logger.bg.log"

    while [[ $# -gt 0 ]]; do
        case $1 in
            -o|--output)
                if [[ $# -lt 2 ]]; then
                    log_error "Fehlender Wert für $1"
                    echo "Usage: sudo $0 run-bg [-o FILE|FILE] [--stdout FILE] [--ring-mb N] [--vfs-iter-write|--no-vfs-iter-write] [--entropy|--no-entropy] [--bpf-log|--no-bpf-log]"
                    exit 1
                fi
                output="$2"
                output_set=1
                shift 2
                ;;
            --stdout)
                if [[ $# -lt 2 ]]; then
                    log_error "Fehlender Wert für --stdout"
                    echo "Usage: sudo $0 run-bg [-o FILE|FILE] [--stdout FILE] [--ring-mb N] [--vfs-iter-write|--no-vfs-iter-write] [--entropy|--no-entropy] [--bpf-log|--no-bpf-log]"
                    exit 1
                fi
                stdout_log="$2"
                shift 2
                ;;
            --ring-mb)
                if [[ $# -lt 2 ]]; then
                    log_error "Fehlender Wert für --ring-mb"
                    echo "Usage: sudo $0 run-bg [-o FILE|FILE] [--stdout FILE] [--ring-mb N] [--vfs-iter-write|--no-vfs-iter-write] [--entropy|--no-entropy] [--bpf-log|--no-bpf-log]"
                    exit 1
                fi
                ring_mb="$2"
                shift 2
                ;;
            --vfs-iter-write|--no-vfs-iter-write)
                parse_vfs_iter_write_flag "$1"
                shift
                ;;
            --entropy|--no-entropy)
                parse_entropy_flag "$1"
                shift
                ;;
            --bpf-log|--no-bpf-log)
                parse_bpf_log_flag "$1"
                shift
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    if [ "$output_set" = "0" ]; then
                        output="$1"
                        output_set=1
                        shift
                    else
                        log_error "Zu viele Positionsargumente: $1"
                        echo "Usage: sudo $0 run-bg [-o FILE|FILE] [--stdout FILE] [--ring-mb N] [--vfs-iter-write|--no-vfs-iter-write] [--entropy|--no-entropy] [--bpf-log|--no-bpf-log]"
                        exit 1
                    fi
                done
                ;;
            -*)
                log_error "Unbekannte Option: $1"
                echo "Usage: sudo $0 run-bg [-o FILE|FILE] [--stdout FILE] [--ring-mb N] [--vfs-iter-write|--no-vfs-iter-write] [--entropy|--no-entropy] [--bpf-log|--no-bpf-log]"
                exit 1
                ;;
            *)
                if [ "$output_set" = "0" ]; then
                    output="$1"
                    output_set=1
                    shift
                else
                    log_error "Zu viele Positionsargumente: $1"
                    echo "Usage: sudo $0 run-bg [-o FILE|FILE] [--stdout FILE] [--ring-mb N] [--vfs-iter-write|--no-vfs-iter-write] [--entropy|--no-entropy] [--bpf-log|--no-bpf-log]"
                    exit 1
                fi
                ;;
        esac
    done

    do_build

    log_info "Setze alten Zustand zurück..."
    do_unload || true

    if [ ! -f "$MONITOR_LOG_BIN" ]; then
        log_error "Logger binary nicht gefunden: $MONITOR_LOG_BIN"
        exit 1
    fi

    local log_dir
    log_dir=$(dirname "$output")
    [ -d "$log_dir" ] || mkdir -p "$log_dir"

    local stdout_dir
    stdout_dir=$(dirname "$stdout_log")
    [ -d "$stdout_dir" ] || mkdir -p "$stdout_dir"

    echo -e "${BLUE}=== Starte Logger im Hintergrund ===${NC}"
    log_info "CSV: $output"
    log_info "Stdout/Stderr: $stdout_log"

    local logger_args=("-o" "$output")
    [ "$ring_mb" != "256" ] && logger_args+=("--ring-mb" "$ring_mb")

    nohup "$MONITOR_LOG_BIN" "${logger_args[@]}" >"$stdout_log" 2>&1 &
    local logger_pid=$!
    echo "$logger_pid" > "$MONITOR_BG_PID_FILE"

    sleep 1
    if ! kill -0 "$logger_pid" >/dev/null 2>&1; then
        log_error "Logger ist direkt wieder beendet. Siehe $stdout_log"
        rm -f "$MONITOR_BG_PID_FILE" 2>/dev/null || true
        exit 1
    fi

    log_success "Logger läuft im Hintergrund (PID: $logger_pid)"
    log_info "Stoppen mit: sudo $0 teardown"
}

do_teardown() {
    check_root
    echo -e "${BLUE}=== Teardown (Logger + BPF) ===${NC}"

    if [ -f "$MONITOR_BG_PID_FILE" ]; then
        local pid
        pid="$(cat "$MONITOR_BG_PID_FILE" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
            log_info "Stoppe Hintergrund-Logger PID $pid ..."
            kill -INT "$pid" >/dev/null 2>&1 || true
            sleep 1
            if kill -0 "$pid" >/dev/null 2>&1; then
                kill -TERM "$pid" >/dev/null 2>&1 || true
            fi
        fi
        rm -f "$MONITOR_BG_PID_FILE" 2>/dev/null || true
    fi

    do_unload || true
    log_success "Teardown abgeschlossen."
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
Usage: sudo $0 {build|clean|load|unload|run|run-bg|teardown|status|help} [opts]

Commands:
  build [opts]       Build BPF + Userspace binaries only
  clean              Räumt die Build-Dateien auf (make clean)
  load [opts]        Load BPF programmes into kernel
  unload             Unload BPF programmes from kernel
  run [opts]         Build + Start logger (logger loads/attaches BPF)
  run-bg [opts]      Build + Start logger im Hintergrund
  teardown           Stoppt Hintergrund-Logger und entlädt BPF
  status             Show current monitor status

Run options:
  -o FILE            Output CSV file (default: /var/log/nfs_fileops.csv)
  FILE               Optionales Positionsargument für Output-Pfad
  --ring-mb N        Ringbuffer size in MiB (default: 256)
  --stdout FILE      Nur bei run-bg: Datei für logger stdout/stderr

Hook options (build/load/run/run-bg):
  --vfs-iter-write       Aktiviere fentry/vfs_iter_write Hook (default)
  --no-vfs-iter-write    Deaktiviere fentry/vfs_iter_write Hook

Entropy options (build/load/run/run-bg):
  --entropy              Aktiviere Entropy-Berechnung (default)
  --no-entropy           Deaktiviere Entropy-Berechnung

BPF log options (build/load/run/run-bg):
  --bpf-log              Aktiviere BPF_LOG -> bpf_printk
  --no-bpf-log           Deaktiviere BPF_LOG (default)

Examples:
  sudo $0 clean
  sudo $0 run
  sudo $0 run-bg --no-entropy --no-bpf-log -o /tmp/fileops.csv --stdout /tmp/monitor.log
  sudo $0 teardown
  sudo $0 run --bpf-log
  sudo $0 run --no-vfs-iter-write
  sudo $0 run --no-entropy
  sudo $0 run --entropy /tmp/fileops.csv
  sudo $0 load --no-entropy
  sudo $0 load --no-vfs-iter-write
  sudo $0 run -o /tmp/fileops.csv --ring-mb 512

EOF
}

case "${1:-}" in
    build)  shift; do_build "$@" ;;
    clean)  do_clean ;;  # NEU
    load)   shift; do_load "$@" ;;
    unload) do_unload ;;
    run)    shift; do_run "$@" ;;
    run-bg) shift; do_run_bg "$@" ;;
    teardown) do_teardown ;;
    status) do_status ;;
    help)   usage ;;
    *)      usage; exit 1 ;;
esac
