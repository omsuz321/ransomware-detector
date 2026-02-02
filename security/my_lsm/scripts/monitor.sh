#!/bin/bash
# Monitor Management Script (Userspace Only)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# Konfiguration
MONITOR_BIN="./monitor"
PIDFILE="/tmp/bpf_monitor.pid"
LOGFILE="/var/log/bpf_monitor.log"

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ==========================================
# HELP / USAGE
# ==========================================
print_help() {
    echo -e "${BLUE}=== BPF Monitor Controller ===${NC}"
    echo "Dieses Skript steuert nur das Userspace-Tool (den Monitor)."
    echo ""
    echo "Verwendung: $0 {Befehl}"
    echo ""
    echo "Verfügbare Befehle:"
    echo -e "  ${GREEN}start${NC}    - Startet den Monitor im Hintergrund"
    echo -e "  ${GREEN}stop${NC}     - Stoppt den laufenden Monitor"
    echo -e "  ${GREEN}restart${NC}  - Startet den Monitor neu"
    echo -e "  ${GREEN}status${NC}   - Zeigt PID und Prozess-Status"
    echo -e "  ${GREEN}logs${NC}     - Zeigt die Live-Logs an (tail -f)"
    echo -e "  ${GREEN}build${NC}    - Kompiliert NUR das Monitor-Tool neu"
    echo -e "  ${GREEN}clean${NC}    - Löscht das Monitor-Binary (behält BPF)"
    echo -e "  ${GREEN}help${NC}     - Zeigt diese Hilfe an"
    echo ""
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Fehler: Bitte als root ausführen (sudo $0 ...)${NC}"
        exit 1
    fi
}

# ==========================================
# FUNKTIONEN
# ==========================================

do_build() {
    echo -e "${BLUE}=== Rebuilding Monitor (Userspace) ===${NC}"
    # Nur User-Clean und User-Build
    make clean-user
    make user
    
    if [ -f "$MONITOR_BIN" ]; then
        echo -e "${GREEN}✓ Build erfolgreich: $MONITOR_BIN erstellt.${NC}"
    else
        echo -e "${RED}✗ Build fehlgeschlagen.${NC}"
        exit 1
    fi
}

do_start() {
    check_root
    
    # 1. Check ob läuft
    if [ -f "$PIDFILE" ] && kill -0 $(cat "$PIDFILE") 2>/dev/null; then
        echo -e "${YELLOW}⚠ Monitor läuft bereits (PID: $(cat $PIDFILE))${NC}"
        exit 0
    fi
    
    # 2. Check ob Binary da ist (sonst bauen)
    if [ ! -f "$MONITOR_BIN" ]; then
        echo -e "${YELLOW}Monitor binary fehlt. Starte Build...${NC}"
        do_build
    fi
    
    # 3. Starten
    echo -e "${GREEN}=== Starte Monitor ===${NC}"
    nohup "$MONITOR_BIN" > "$LOGFILE" 2>&1 &
    
    PID=$!
    echo $PID > "$PIDFILE"
    sleep 1
    
    # 4. Check ob an geblieben
    if kill -0 $PID 2>/dev/null; then
        echo -e "${GREEN}✓ Monitor läuft (PID: $PID)${NC}"
        echo -e "${BLUE}  Logs ansehen mit: sudo $0 logs${NC}"
    else
        echo -e "${RED}✗ Fehler: Prozess hat sich sofort beendet.${NC}"
        echo -e "${YELLOW}Log-Ausgabe:${NC}"
        cat "$LOGFILE"
        rm -f "$PIDFILE"
        exit 1
    fi
}

do_stop() {
    check_root
    
    if [ ! -f "$PIDFILE" ]; then
        echo -e "${YELLOW}Keine PID-Datei gefunden (Monitor läuft nicht).${NC}"
        exit 0
    fi
    
    PID=$(cat "$PIDFILE")
    if kill -0 "$PID" 2>/dev/null; then
        echo -e "${BLUE}Stoppe Monitor (PID: $PID)...${NC}"
        kill -TERM "$PID"
        sleep 1
        
        # Hard kill falls nötig
        if kill -0 "$PID" 2>/dev/null; then
            kill -KILL "$PID"
        fi
        
        rm -f "$PIDFILE"
        echo -e "${GREEN}✓ Gestoppt.${NC}"
    else
        echo -e "${YELLOW}Prozess war bereits beendet.${NC}"
        rm -f "$PIDFILE"
    fi
}

do_restart() {
    do_stop
    sleep 1
    do_start
}

do_status() {
    if [ -f "$PIDFILE" ] && kill -0 $(cat "$PIDFILE") 2>/dev/null; then
        PID=$(cat "$PIDFILE")
        echo -e "${GREEN}✓ Monitor läuft (PID: $PID)${NC}"
        ps -p "$PID" -o pid,etime,cmd
    else
        echo -e "${RED}✗ Monitor läuft nicht${NC}"
        # PID Datei aufräumen falls veraltet
        [ -f "$PIDFILE" ] && rm -f "$PIDFILE"
    fi
}

do_clean() {
    echo -e "${BLUE}=== Cleaning Monitor ===${NC}"
    # WICHTIG: Nutzt clean-user, damit der Kernel-Teil (Skeleton) erhalten bleibt!
    make clean-user
    echo -e "${GREEN}✓ Monitor Binary entfernt.${NC}"
}

do_logs() {
    if [ -f "$LOGFILE" ]; then
        echo -e "${BLUE}=== Logs (Ctrl+C zum Beenden) ===${NC}"
        tail -f "$LOGFILE"
    else
        echo -e "${YELLOW}Log-Datei noch nicht vorhanden ($LOGFILE)${NC}"
    fi
}

# ==========================================
# MAIN DISPATCHER
# ==========================================
case "${1:-}" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_restart ;;
    status)  do_status ;;
    build)   do_build ;;
    clean)   do_clean ;;
    logs)    do_logs ;;
    help)    print_help ;;
    *)       print_help; exit 1 ;;
esac