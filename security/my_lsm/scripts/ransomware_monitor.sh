#!/bin/bash
# ==========================================
# Ransomware Monitor Control Script
# Controls src/monitor/ransomware_logger
# ==========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

LOGGER_BIN="src/monitor/ransomware_logger"
PID_FILE="/tmp/ransomware_logger.pid"
DEFAULT_STDOUT_LOG="/tmp/ransomware_logger.bg.log"
DEFAULT_CSV="/var/log/ransomware_events.csv"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

do_build() {
    echo -e "${BLUE}=== Build ransomware logger ===${NC}"
    make ransomware-userspace

    if [ ! -f "$LOGGER_BIN" ]; then
        log_error "Logger binary nicht gefunden: $LOGGER_BIN"
        exit 1
    fi

    log_success "Build erfolgreich."
}

do_run() {
    check_root

    local output="$DEFAULT_CSV"
    local ring_mb=8
    local extra_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output)
                [ $# -lt 2 ] && { log_error "Fehlender Wert für $1"; exit 1; }
                output="$2"
                shift 2
                ;;
            --ring-mb)
                [ $# -lt 2 ] && { log_error "Fehlender Wert für --ring-mb"; exit 1; }
                ring_mb="$2"
                shift 2
                ;;
            --run-id)
                [ $# -lt 2 ] && { log_error "Fehlender Wert für --run-id"; exit 1; }
                extra_args+=("--run-id" "$2")
                shift 2
                ;;
            --label)
                [ $# -lt 2 ] && { log_error "Fehlender Wert für --label"; exit 1; }
                extra_args+=("--label" "$2")
                shift 2
                ;;
            *)
                log_error "Unbekannte Option: $1"
                echo "Usage: sudo $0 run [-o FILE] [--ring-mb N] [--run-id ID] [--label LABEL]"
                exit 1
                ;;
        esac
    done

    # Lade BPF-Programme falls noch nicht geladen
    local pin_dir="/sys/fs/bpf/vfs_write_logger"
    if [ ! -d "$pin_dir" ]; then
        echo -e "${BLUE}=== BPF-Programme nicht geladen, lade sie jetzt ===${NC}"
        if [ -x "$SCRIPT_DIR/ebpf.sh" ]; then
            "$SCRIPT_DIR/ebpf.sh" load
        else
            log_error "ebpf.sh nicht gefunden. Bitte manuell laden: sudo scripts/ebpf.sh load"
            exit 1
        fi
    else
        log_info "BPF-Programme bereits geladen."
    fi

    do_build

    local out_dir
    out_dir="$(dirname "$output")"
    [ -d "$out_dir" ] || mkdir -p "$out_dir"

    echo -e "${BLUE}=== Starte ransomware logger ===${NC}"
    log_info "CSV: $output"
    log_info "Stoppen: Ctrl+C"

    "$LOGGER_BIN" -o "$output" --ring-mb "$ring_mb" "${extra_args[@]}"
}

do_run_bg() {
    check_root

    local output="$DEFAULT_CSV"
    local ring_mb=8
    local stdout_log="$DEFAULT_STDOUT_LOG"
    local extra_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output)
                [ $# -lt 2 ] && { log_error "Fehlender Wert für $1"; exit 1; }
                output="$2"
                shift 2
                ;;
            --ring-mb)
                [ $# -lt 2 ] && { log_error "Fehlender Wert für --ring-mb"; exit 1; }
                ring_mb="$2"
                shift 2
                ;;
            --stdout)
                [ $# -lt 2 ] && { log_error "Fehlender Wert für --stdout"; exit 1; }
                stdout_log="$2"
                shift 2
                ;;
            --run-id)
                [ $# -lt 2 ] && { log_error "Fehlender Wert für --run-id"; exit 1; }
                extra_args+=("--run-id" "$2")
                shift 2
                ;;
            --label)
                [ $# -lt 2 ] && { log_error "Fehlender Wert für --label"; exit 1; }
                extra_args+=("--label" "$2")
                shift 2
                ;;
            *)
                log_error "Unbekannte Option: $1"
                echo "Usage: sudo $0 run-bg [-o FILE] [--ring-mb N] [--stdout FILE] [--run-id ID] [--label LABEL]"
                exit 1
                ;;
        esac
    done

    if [ -f "$PID_FILE" ]; then
        local existing_pid
        existing_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [ -n "$existing_pid" ] && kill -0 "$existing_pid" >/dev/null 2>&1; then
            log_error "Logger läuft bereits (PID: $existing_pid). Erst stoppen mit: sudo $0 stop"
            exit 1
        fi
        rm -f "$PID_FILE" 2>/dev/null || true
    fi

    # Lade BPF-Programme falls noch nicht geladen
    local pin_dir="/sys/fs/bpf/vfs_write_logger"
    if [ ! -d "$pin_dir" ]; then
        echo -e "${BLUE}=== BPF-Programme nicht geladen, lade sie jetzt ===${NC}"
        if [ -x "$SCRIPT_DIR/ebpf.sh" ]; then
            "$SCRIPT_DIR/ebpf.sh" load
        else
            log_error "ebpf.sh nicht gefunden. Bitte manuell laden: sudo scripts/ebpf.sh load"
            exit 1
        fi
    else
        log_info "BPF-Programme bereits geladen."
    fi

    do_build

    local out_dir stdout_dir
    out_dir="$(dirname "$output")"
    stdout_dir="$(dirname "$stdout_log")"
    [ -d "$out_dir" ] || mkdir -p "$out_dir"
    [ -d "$stdout_dir" ] || mkdir -p "$stdout_dir"

    echo -e "${BLUE}=== Starte ransomware logger im Hintergrund ===${NC}"
    log_info "CSV: $output"
    log_info "Stdout/Stderr: $stdout_log"

    nohup "$LOGGER_BIN" -o "$output" --ring-mb "$ring_mb" "${extra_args[@]}" >"$stdout_log" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"

    sleep 1
    if ! kill -0 "$pid" >/dev/null 2>&1; then
        log_error "Logger ist direkt beendet. Siehe: $stdout_log"
        rm -f "$PID_FILE" 2>/dev/null || true
        exit 1
    fi

    log_success "Logger läuft im Hintergrund (PID: $pid)"
}

do_stop() {
    check_root

    if [ ! -f "$PID_FILE" ]; then
        log_warn "Kein PID-File gefunden ($PID_FILE)."
        return 0
    fi

    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"

    if [ -z "$pid" ]; then
        rm -f "$PID_FILE" 2>/dev/null || true
        log_warn "Leeres PID-File entfernt."
        return 0
    fi

    if ! kill -0 "$pid" >/dev/null 2>&1; then
        rm -f "$PID_FILE" 2>/dev/null || true
        log_warn "Prozess $pid lief nicht mehr. PID-File entfernt."
        return 0
    fi

    log_info "Stoppe Logger PID $pid ..."
    kill -INT "$pid" >/dev/null 2>&1 || true
    sleep 1
    if kill -0 "$pid" >/dev/null 2>&1; then
        kill -TERM "$pid" >/dev/null 2>&1 || true
    fi

    rm -f "$PID_FILE" 2>/dev/null || true
    log_success "Logger gestoppt."

    # Entlade auch die BPF-Programme
    echo -e "${BLUE}=== Entlade BPF-Programme ===${NC}"
    if [ -x "$SCRIPT_DIR/ebpf.sh" ]; then
        "$SCRIPT_DIR/ebpf.sh" unload
    else
        log_warn "ebpf.sh nicht gefunden, überspringe BPF-Unload."
    fi
}

do_status() {
    echo -e "${BLUE}=== Ransomware logger status ===${NC}"

    if [ ! -f "$PID_FILE" ]; then
        echo -e "${YELLOW}Status: INAKTIV${NC}"
        return 0
    fi

    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"

    if [ -z "$pid" ]; then
        echo -e "${YELLOW}Status: INAKTIV (leeres PID-File)${NC}"
        return 0
    fi

    if kill -0 "$pid" >/dev/null 2>&1; then
        echo -e "${GREEN}Status: AKTIV${NC}"
        echo "PID: $pid"
    else
        echo -e "${YELLOW}Status: INAKTIV (stale PID-File)${NC}"
    fi
}

usage() {
    cat << EOF
Usage: sudo $0 {build|run|run-bg|stop|status|help} [opts]

Commands:
  build                  Buildet BPF + ransomware userspace logger
  run [opts]             Startet Logger im Vordergrund (lädt BPF auto)
  run-bg [opts]          Startet Logger im Hintergrund (lädt BPF auto)
  stop                   Stoppt Logger + entlädt BPF-Programme
  status                 Zeigt Logger-Status

Options for run/run-bg:
  -o, --output FILE              CSV-Ausgabedatei (default: $DEFAULT_CSV)
  --ring-mb N                    Ringbuffer-Größe MiB (default: 8)
  --run-id ID                    Run identifier (für Summary-Zeile)
  --label LABEL                  Run label (benign, ransomware, etc.)

Options for run-bg:
  --stdout FILE          Datei für stdout/stderr (default: $DEFAULT_STDOUT_LOG)

Hinweis:
  - run/run-bg laden automatisch die BPF-Programme falls nicht geladen
  - stop entfernt sowohl Logger als auch BPF-Programme (Clean Slate)
  - Beim Stop wird eine Summary-Zeile am Ende der CSV geschrieben
  - attack_start_time wird automatisch beim User-Creation Event getrackt

Examples:
  sudo $0 build
  sudo $0 run -o /tmp/test.csv --run-id run_001 --label ransomware
  sudo $0 run-bg -o /tmp/test.csv --run-id run_001 --label benign
  sudo $0 status
  sudo $0 stop
EOF
}

case "${1:-}" in
    build)
        shift
        do_build "$@"
        ;;
    run)
        shift
        do_run "$@"
        ;;
    run-bg)
        shift
        do_run_bg "$@"
        ;;
    stop)
        shift
        do_stop "$@"
        ;;
    status)
        shift
        do_status "$@"
        ;;
    help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
