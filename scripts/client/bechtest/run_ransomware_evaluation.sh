#!/bin/bash

# ============================================================
# RANSOMWARE EVALUATION HARNESS
# Führt mehrere Ransomware-Simulatoren mit Monitoring aus
# ============================================================

set -euo pipefail

# --- GLOBAL STATE ---
CURRENT_MONITOR_SCRIPT_DIR=""
CURRENT_SERVER_PASS=""
CURRENT_SERVER_IP=""

# --- CLEANUP FUNCTION ---
cleanup() {
    echo -e "\n\n${RED}⚠️  Unterbrechen erkannt - räume auf...${NC}"
    
    # Stoppe Monitor auf dem Remote-Server falls aktiv
    if [ -n "$CURRENT_MONITOR_SCRIPT_DIR" ] && [ -n "$CURRENT_SERVER_PASS" ] && [ -n "$CURRENT_SERVER_IP" ]; then
        log_warn "Stoppe Ransomware Monitor auf Server..."
        sshpass -p "$CURRENT_SERVER_PASS" ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR "server@$CURRENT_SERVER_IP" \
            "cd $CURRENT_MONITOR_SCRIPT_DIR && printf '%s\n' '$CURRENT_SERVER_PASS' | sudo -S -p '' bash ./ransomware_monitor.sh stop" \
            >/dev/null 2>&1 || true
        log_success "Monitor gestoppt"
    fi
    
    echo -e "${YELLOW}Cleanup abgeschlossen - Beende Script${NC}"
    exit 130  # Standard exit code für SIGINT
}

trap cleanup SIGINT

# --- PARAMETER ---
SERVER_IP="${1:-}"
CLIENT_MOUNT="${2:-/mnt/nfs}"
DURATION="${3:-30}"
SERVER_PASS="${4:-}"
RANSOMWARE_SCRIPT_DIR="${5:-/home/server/Desktop/dev/scripts}"
SIMULATOR_FILTER="${6:-}"  # Optional: z.B. "ebpfangel" um nur diesen zu laufen
REPEAT_COUNT="${7:-1}"  # Wie viele Male pro Simulator ausführen (default: 1)

SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o LogLevel=ERROR
    -o ConnectTimeout=10
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=2
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RANSOM_SIM_DIR="$SCRIPT_DIR/../run_ransomware"
RESULTS_DIR="$SCRIPT_DIR/../results"
# Verwende CLIENT_MOUNT flexibel:
# - .../tmp   -> direkt nutzen
# - .../target -> Nachbarpfad .../tmp nutzen (target entspricht serverseitig .../target)
# - sonst     -> .../tmp anhängen
if [ "$(basename "${CLIENT_MOUNT%/}")" = "tmp" ]; then
    CLIENT_TMP="${CLIENT_MOUNT%/}"
elif [ "$(basename "${CLIENT_MOUNT%/}")" = "target" ]; then
    CLIENT_TMP="$(dirname "${CLIENT_MOUNT%/}")/tmp"
else
    CLIENT_TMP="${CLIENT_MOUNT%/}/tmp"
fi
SERVER_BASE_DIR="/srv/nfs/thesis_data"
SERVER_SOURCE_DIR="$SERVER_BASE_DIR/target"  # Target-Daten die für Tests kopiert werden
SERVER_WORK_DIR="$SERVER_BASE_DIR/tmp"  # Temp-Verzeichnis für Ransomware-Tests (via NFS gemountet)

# Monitoring
RANSOMWARE_MONITOR_SCRIPT="$RANSOMWARE_SCRIPT_DIR/ransomware_monitor.sh"
RANSOMWARE_MONITOR_CSV="/home/server/Desktop/run_evaluation.csv"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e " ℹ️  $1"; }
log_success() { echo -e " ✅ ${GREEN}$1${NC}"; }
log_error()   { echo -e " ❌ ${RED}$1${NC}"; }
log_warn()    { echo -e " ⚠️  ${YELLOW}$1${NC}"; }

# --- HELPERS ---
sanitize_label() {
    local raw="$1"
    local normalized

    # CSV-sicheres Label: klein, nur [a-z0-9._-], Rest zu "_"
    normalized="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/_/g; s/^_+//; s/_+$//; s/_+/_/g')"
    if [ -z "$normalized" ]; then
        normalized="unknown"
    fi

    echo "$normalized"
}

generate_run_id() {
    local run_source="$1"
    local run_counter="$2"
    local repeat="$3"
    local ts_ns

    ts_ns="$(date +%s%N 2>/dev/null || true)"
    if ! [[ "$ts_ns" =~ ^[0-9]+$ ]]; then
        ts_ns="$(date +%s)$RANDOM"
    fi

    # run_id soll mit dem Simulator starten (z.B. "jimmy"), aber eindeutig bleiben
    printf '%s_r%03d_rep%03d_%s_%04d' "$run_source" "$run_counter" "$repeat" "$ts_ns" "$RANDOM"
}

# --- VALIDATION ---
if [ -z "$SERVER_IP" ] || [ -z "$SERVER_PASS" ]; then
    log_error "Fehlende Parameter"
    echo "Usage: $0 SERVER_IP CLIENT_MOUNT DURATION SERVER_PASS [RANSOMWARE_SCRIPT_DIR] [SIMULATOR_FILTER] [REPEAT_COUNT]"
    echo ""
    echo "Beispiele:"
    echo "  $0 192.168.2.209 /mnt/nfs 30 1234                                     # nutzt /mnt/nfs/tmp"
    echo "  $0 192.168.2.209 /mnt/nfs/target 30 1234                              # nutzt automatisch /mnt/nfs/tmp"
    echo "  $0 192.168.2.209 /mnt/nfs/tmp 30 1234 /usr/scripts ebpfangel         # nutzt direkt /mnt/nfs/tmp"
    echo "  $0 192.168.2.209 /mnt/nfs 30 1234 /usr/scripts ebpfangel 5           # ebpfangel (5x)"
    exit 1
fi

# --- SETUP SERVER TMP DIR ---
setup_server_tmp() {
    local label="$1"
    log_info "Räume Server-Workdir auf (für: $label)..."
    
    sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" 'bash -s' <<EOF
set -euo pipefail
SERVER_PASS="$SERVER_PASS"
SOURCE_DIR="$SERVER_SOURCE_DIR"
WORK_DIR="$SERVER_WORK_DIR"

echo "[DEBUG] SOURCE_DIR: \$SOURCE_DIR"
echo "[DEBUG] WORK_DIR: \$WORK_DIR"

# Erstelle Work-Verzeichnis mit sudo
printf '%s\n' "\$SERVER_PASS" | sudo -S -p '' mkdir -p "\$WORK_DIR"

# Leere tmp komplett (mehrere Versuche)
echo "[DEBUG] Räume WORK_DIR auf..."
for i in 1 2 3; do
    printf '%s\n' "\$SERVER_PASS" | sudo -S -p '' rm -rf "\$WORK_DIR"/* 2>/dev/null && break || sleep 1
done

# Überprüfe ob SOURCE_DIR existiert
if [ ! -d "\$SOURCE_DIR" ]; then
    echo "ERROR: SOURCE_DIR nicht gefunden: \$SOURCE_DIR"
    exit 1
fi

# Kopiere alle Dateien/Ordner aus SOURCE_DIR nach WORK_DIR
echo "[DEBUG] Kopiere von \$SOURCE_DIR nach \$WORK_DIR..."
printf '%s\n' "\$SERVER_PASS" | sudo -S -p '' cp -a "\$SOURCE_DIR"/* "\$WORK_DIR"/ 2>&1 | tail -5

# Überprüfe ob Dateien kopiert wurden
FILE_COUNT=\$(find "\$WORK_DIR" -mindepth 1 | wc -l)
if [ \$FILE_COUNT -eq 0 ]; then
    echo "ERROR: Keine Dateien in WORK_DIR nach Kopie"
    echo "SOURCE_DIR Inhalt:"
    ls -la "\$SOURCE_DIR" | sed 's/^/  /'
    exit 1
fi

echo "[INFO] \$FILE_COUNT Dateien/Ordner in WORK_DIR kopiert"

# Permissions fix - wichtig für NFS-Zugriff vom Client
# Setze Owner auf nobody:nogroup (Standard für NFS) oder auf die exportierte UID
printf '%s\n' "\$SERVER_PASS" | sudo -S -p '' chown -R nobody:nogroup "\$WORK_DIR" 2>/dev/null || true
# Setze alle Dateien und Ordner auf vollständige Permissions
printf '%s\n' "\$SERVER_PASS" | sudo -S -p '' chmod -R 777 "\$WORK_DIR" 2>/dev/null || true
# Zusätzlicher Fix wie manuell getestet: cd WORK_DIR && chmod -R 777 ./*
if [ -n "\$(find "\$WORK_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    printf '%s\n' "\$SERVER_PASS" | sudo -S -p '' bash -c 'cd "\$1" && chmod -R 777 ./*' _ "\$WORK_DIR" 2>/dev/null || true
fi
# Stelle sicher dass neue Dateien auch schreibbar sind
printf '%s\n' "\$SERVER_PASS" | sudo -S -p '' find "\$WORK_DIR" -type d -exec chmod 777 {} \; 2>/dev/null || true
printf '%s\n' "\$SERVER_PASS" | sudo -S -p '' find "\$WORK_DIR" -type f -exec chmod 666 {} \; 2>/dev/null || true

# Server-Caches leeren
printf '%s\n' "\$SERVER_PASS" | sudo -S -p '' bash -c 'sync && echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true

echo "[DEBUG] WORK_DIR nach Setup:"
printf '%s\n' "\$SERVER_PASS" | sudo -S -p '' ls -ld "\$WORK_DIR"
printf '%s\n' "\$SERVER_PASS" | sudo -S -p '' ls -lh "\$WORK_DIR" | head -6

echo "OK:server_ready"
EOF
    
    local ssh_result=$?
    if [ $ssh_result -ne 0 ]; then
        log_error "Server-Setup fehlgeschlagen"
        return 1
    fi
    
    # Client-Caches leeren (lokal)
    log_info "Räume Client-Caches auf..."
    sync
    sudo -S bash -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
    
    # Warte kurz damit NFS-Cache aktualisiert wird
    sleep 2
    
    # Überprüfe ob Verzeichnis auf Client sichtbar ist
    if [ ! -d "$CLIENT_TMP" ]; then
        log_error "CLIENT_TMP nicht sichtbar: $CLIENT_TMP"
        log_error "Überprüfe NFS-Mount!"
        return 1
    fi
    
    local client_dirs=$(find "$CLIENT_TMP" -mindepth 1 -type d 2>/dev/null | wc -l)
    local client_files=$(find "$CLIENT_TMP" -type f 2>/dev/null | wc -l)
    log_info "Client sieht $client_dirs Ordner und $client_files Dateien in $CLIENT_TMP"

    if [ "$client_dirs" -eq 0 ] && [ "$client_files" -eq 0 ]; then
        log_warn "Client sieht in $CLIENT_TMP nichts (möglicherweise falscher NFS-Mount/Pfad)"
        if command -v findmnt >/dev/null 2>&1; then
            local mount_info
            mount_info=$(findmnt -T "$CLIENT_TMP" -n -o SOURCE,FSTYPE,TARGET 2>/dev/null || true)
            if [ -n "$mount_info" ]; then
                log_warn "Mount-Info für $CLIENT_TMP: $mount_info"
            fi
        fi
    fi
    
    log_success "Server und Client sind bereit"
}

# --- START RANSOMWARE MONITOR ---
start_monitor() {
    local label="$1"
    local run_id="$2"
    
    log_info "Starte Ransomware Monitor..."
    log_info "  Label: $label"
    log_info "  Run-ID: $run_id"
    log_info "  Script-Dir: $RANSOMWARE_SCRIPT_DIR"
    log_info "  CSV-Path: $RANSOMWARE_MONITOR_CSV"
    log_info "  Server: server@$SERVER_IP"
    
    local ssh_output
    ssh_output=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" bash -s "$SERVER_PASS" "$RANSOMWARE_SCRIPT_DIR" "$RANSOMWARE_MONITOR_CSV" "$run_id" "$label" <<'SSHEOF'
set -x
set -euo pipefail
SERVER_PASS="$1"
SCRIPT_DIR="$2"
CSV_PATH="$3"
RUN_ID="$4"
LABEL="$5"

echo "[DEBUG] SERVER_PASS länge: ${#SERVER_PASS}"
echo "[DEBUG] SCRIPT_DIR: $SCRIPT_DIR"
echo "[DEBUG] CSV_PATH: $CSV_PATH"
echo "[DEBUG] RUN_ID: $RUN_ID"
echo "[DEBUG] LABEL: $LABEL"

# Prüfe ob Verzeichnis existiert
if [ ! -d "$SCRIPT_DIR" ]; then
    echo "ERROR: Script-Verzeichnis nicht gefunden: $SCRIPT_DIR"
    exit 1
fi

echo "[DEBUG] Script-Verzeichnis existiert"

# Prüfe ob ransomware_monitor.sh existiert
if [ ! -f "$SCRIPT_DIR/ransomware_monitor.sh" ]; then
    echo "ERROR: ransomware_monitor.sh nicht in $SCRIPT_DIR gefunden"
    echo "ERROR: Verfügbare Dateien in $SCRIPT_DIR:"
    ls -la "$SCRIPT_DIR" 2>&1 | sed 's/^/ERROR:  /'
    exit 1
fi

echo "[DEBUG] ransomware_monitor.sh existiert"

cd "$SCRIPT_DIR" || { echo "ERROR: Konnte nicht in $SCRIPT_DIR wechseln"; exit 1; }

echo "[DEBUG] Bin in $SCRIPT_DIR, starte Monitor..."

# Starte Monitor im Hintergrund
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bash ./ransomware_monitor.sh run-bg \
    -o "$CSV_PATH" \
    --run-id "$RUN_ID" \
    --label "$LABEL" 2>&1

echo "[DEBUG] Monitor-Command beendet"

# Warte kurz und überprüfe ob PID-File existiert
sleep 2

echo "[DEBUG] Lese PID-File..."
PID=$(printf '%s\n' "$SERVER_PASS" | sudo -S -p '' cat /tmp/ransomware_logger.pid 2>/dev/null || echo "")

if [ -z "$PID" ]; then
    echo "ERROR: PID-File nicht erstellt"
    echo "ERROR: /tmp-Inhalt:"
    printf '%s\n' "$SERVER_PASS" | sudo -S -p '' ls -la /tmp/ransomware* 2>&1 | sed 's/^/ERROR:  /'
    echo "ERROR: Log-Ausgabe:"
    printf '%s\n' "$SERVER_PASS" | sudo -S -p '' cat /tmp/ransomware_logger.bg.log 2>&1 | head -50 | sed 's/^/ERROR:  /'
    exit 1
fi

echo "[SUCCESS] PID=$PID"
echo "OK:$PID"
SSHEOF
) 2>&1
    
    # Gib alle Ausgabe dem Nutzer
    echo "$ssh_output"
}


# --- STOP MONITOR & GET RESULT ---
stop_monitor() {
    local label="$1"
    
    sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" bash -s "$SERVER_PASS" "$RANSOMWARE_MONITOR_CSV" "$RANSOMWARE_SCRIPT_DIR" <<'SSHEOF' 2>&1 || true
set -euo pipefail
SERVER_PASS="$1"
CSV_PATH="$2"
SCRIPT_DIR="$3"

# Überprüfe ob CSV existiert
if [ ! -f "$CSV_PATH" ]; then
    echo "ERROR: CSV nicht gefunden: $CSV_PATH"
    exit 1
fi

# Stoppe Monitor
cd "$SCRIPT_DIR" || { echo "ERROR: Konnte nicht in $SCRIPT_DIR wechseln"; exit 1; }
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bash ./ransomware_monitor.sh stop >/dev/null 2>&1 || true

# Lese letzte Zeile
sleep 1
LAST_LINE=$(printf '%s\n' "$SERVER_PASS" | sudo -S -p '' tail -1 "$CSV_PATH" 2>/dev/null || echo "")
if [ -z "$LAST_LINE" ]; then
    echo "ERROR: Keine Daten in CSV: $CSV_PATH"
    printf '%s\n' "$SERVER_PASS" | sudo -S -p '' wc -l "$CSV_PATH" 2>&1 | sed 's/^/ERROR: /'
    exit 1
fi

echo "OK:$LAST_LINE"
SSHEOF
}

# --- RUN RANSOMWARE SIMULATOR ---
run_simulator() {
    local simulator_script="$1"
    local label="$2"
    local run_id="$3"
    
    log_info "Starte Ransomware-Simulator: $label..."
    log_info "Target: $CLIENT_TMP"
    
    # Debug: Zeige was im Client-Verzeichnis ist
    if [ -d "$CLIENT_TMP" ]; then
        local file_count=$(find "$CLIENT_TMP" -type f 2>/dev/null | wc -l)
        log_info "Dateien in $CLIENT_TMP: $file_count"
    else
        log_warn "Verzeichnis existiert nicht: $CLIENT_TMP"
    fi
    
    # Workaround für NFS-Permissions: Stelle sicher dass keine ACLs den Zugriff blockieren
    log_info "Entferne NFS-ACLs für $CLIENT_TMP..."
    sudo setfacl -R -b "$CLIENT_TMP" 2>/dev/null || true
    
    # Zusätzlich: Stelle sicher dass das Verzeichnis schreibbar ist
    sudo chmod -R 777 "$CLIENT_TMP" 2>/dev/null || true
    if [ -n "$(find "$CLIENT_TMP" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
        sudo bash -c 'cd "$1" && chmod -R 777 ./*' _ "$CLIENT_TMP" 2>/dev/null || true
    fi
    
    # Starte Simulator im Hintergrund
    bash "$simulator_script" "$CLIENT_TMP" "$DURATION" &>/dev/null &
    local sim_pid=$!
    
    log_info "Simulator läuft (PID: $sim_pid)"
    
    # Überwache CSV und töte Simulator bei Erkennung
    local start_time=$(date +%s)
    local timeout_time=$((start_time + DURATION))
    
    while true; do
        local current_time=$(date +%s)
        
        # Timeout-Check
        if [ $current_time -ge $timeout_time ]; then
            log_warn "Timeout erreicht ($DURATION Sekunden)"
            kill $sim_pid 2>/dev/null || true
            wait $sim_pid 2>/dev/null || true
            return 1
        fi
        
        # Überprüfe ob Simulator noch läuft
        if ! kill -0 $sim_pid 2>/dev/null; then
            log_info "Simulator beendet (PID $sim_pid)"
            wait $sim_pid 2>/dev/null || true
            return 0
        fi
        
        # Prüfe CSV auf Server auf Erkennung
        local detection_status=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" \
            "grep '^$run_id,' '$RANSOMWARE_MONITOR_CSV' 2>/dev/null | tail -1 | cut -d',' -f5" 2>/dev/null || echo "")
        
        if [ "$detection_status" = "1" ]; then
            log_success "🎯 ERKENNUNG! Monitor hat Ransomware erkannt - stoppe Simulator"
            kill $sim_pid 2>/dev/null || true
            wait $sim_pid 2>/dev/null || true
            return 0
        fi
        
        sleep 1
    done
}

# --- MAIN LOOP ---
main() {
    mkdir -p "$RESULTS_DIR"
    
    echo -e "\n${BLUE}============================================${NC}"
    echo -e "${BLUE} 🚀 Ransomware Evaluation Harness${NC}"
    echo -e "${BLUE}============================================${NC}\n"
    log_info "Pfad-Mapping: CLIENT_MOUNT=$CLIENT_MOUNT -> CLIENT_TMP=$CLIENT_TMP"
    
    # Sammle alle Ransomware-Simulatoren
    if [ ! -d "$RANSOM_SIM_DIR" ]; then
        log_error "Ransomware-Verzeichnis nicht gefunden: $RANSOM_SIM_DIR"
        exit 1
    fi
    
    local simulators=()
    for script in "$RANSOM_SIM_DIR"/run_*_ransomware.sh; do
        if [ -f "$script" ]; then
            local basename_script=$(basename "$script")
            
            # Skip Nextron
            if [[ "$basename_script" == *"nextron"* ]]; then
                continue
            fi
            
            # Filter anwenden falls gesetzt
            if [ -n "$SIMULATOR_FILTER" ] && ! [[ "$basename_script" == *"$SIMULATOR_FILTER"* ]]; then
                continue
            fi
            
            simulators+=("$script")
        fi
    done
    
    if [ ${#simulators[@]} -eq 0 ]; then
        log_error "Keine Ransomware-Simulatoren gefunden"
        exit 1
    fi
    
    log_success "Gefundene Simulatoren: ${#simulators[@]} (je $REPEAT_COUNT Mal)"
    for sim in "${simulators[@]}"; do
        log_info "  - $(basename "$sim")"
    done
    
    # Führe jeden Simulator REPEAT_COUNT Mal aus
    local run_counter=1
    for simulator in "${simulators[@]}"; do
        local sim_name
        local sim_label
        local event_label="ransomware"
        sim_name="$(basename "$simulator" | sed 's/run_//;s/_ransomware.sh//')"
        sim_label="$(sanitize_label "$sim_name")"

        if [ "$sim_name" != "$sim_label" ]; then
            log_warn "Label normalisiert: '$sim_name' -> '$sim_label'"
        fi
        
        # Wiederhole jeden Simulator REPEAT_COUNT Mal
        for repeat in $(seq 1 $REPEAT_COUNT); do
            local run_id
            run_id="$(generate_run_id "$sim_label" "$run_counter" "$repeat")"
        
            echo -e "\n${YELLOW}======== Run $run_counter: $sim_label (Wiederholung $repeat/$REPEAT_COUNT) ========${NC}\n"
            log_info "Run-ID: $run_id"
            log_info "Label: $event_label"
        
            # 1. Server vorbereiten
            if ! setup_server_tmp "$sim_label"; then
                log_error "Konnte Server nicht vorbereiten"
                ((run_counter++))
                continue 2  # Nächster Simulator
            fi
            
            # 2. Monitor starten
            CURRENT_SERVER_IP="$SERVER_IP"
            CURRENT_SERVER_PASS="$SERVER_PASS"
            CURRENT_MONITOR_SCRIPT_DIR="$RANSOMWARE_SCRIPT_DIR"
            
            local monitor_output=$(start_monitor "$event_label" "$run_id")
            
            # Überprüfe auf Fehler in der Ausgabe
            if echo "$monitor_output" | grep -q "^ERROR"; then
                log_error "Monitor-Start fehlgeschlagen:"
                echo "$monitor_output" | grep "^ERROR" | sed 's/^/  /'
                # Zeige auch DEBUG-Zeilen für mehr Kontext
                echo "$monitor_output" | grep -E "^\[DEBUG\]|^\[SUCCESS\]" | sed 's/^/  /'
                ((run_counter++))
                continue 2  # Nächster Simulator
            fi
            
            # Extrahiere OK-Zeile
            local ok_line=$(echo "$monitor_output" | grep "^OK:" | tail -1)
            if [ -z "$ok_line" ]; then
                log_error "Monitor-Start: Keine OK-Zeile gefunden"
                log_error "Komplette SSH-Ausgabe:"
                echo "$monitor_output" | sed 's/^/  /'
                ((run_counter++))
                continue 2  # Nächster Simulator
            fi
            
            local monitor_pid="${ok_line#OK:}"
            if [ -z "$monitor_pid" ] || ! [[ "$monitor_pid" =~ ^[0-9]+$ ]]; then
                log_error "Monitor-PID ungültig: $monitor_pid"
                log_error "OK-Zeile: $ok_line"
                ((run_counter++))
                continue 2  # Nächster Simulator
            fi
            
            log_success "Monitor läuft (PID: $monitor_pid)"
            
            # 3. Ransomware-Simulator starten (inkludiert Polling für Erkennung)
            run_simulator "$simulator" "$sim_label" "$run_id"
            
            # 4. Monitor stoppen
            local final_result=$(stop_monitor "$sim_label")
            CURRENT_SERVER_IP=""
            CURRENT_SERVER_PASS=""
            CURRENT_MONITOR_SCRIPT_DIR=""
            
            if [[ "$final_result" != "OK:"* ]]; then
                log_error "Konnte Monitor-Ergebnisse nicht abrufen"
            else
                local csv_line="${final_result#OK:}"
                log_success "Ergebnis: $csv_line"
                local csv_run_id
                local csv_label
                csv_run_id="$(echo "$csv_line" | cut -d',' -f1)"
                csv_label="$(echo "$csv_line" | cut -d',' -f2)"
                if [ "$csv_run_id" != "$run_id" ]; then
                    log_warn "CSV run_id passt nicht zum gestarteten Run: erwartet '$run_id', erhalten '$csv_run_id'"
                fi
                if [ "$csv_label" != "$event_label" ]; then
                    log_warn "CSV label passt nicht zum erwarteten Label: erwartet '$event_label', erhalten '$csv_label'"
                fi
            fi
            
            # 5. Speichere Ergebnisse
            echo "$csv_line" >> "$RESULTS_DIR/evaluation_results.csv"
            
            ((run_counter++))
            
            # Warte zwischen Wiederholungen (außer beim letzten Lauf)
            if [ $repeat -lt $REPEAT_COUNT ]; then
                log_info "Warte 3 Sekunden vor nächster Wiederholung..."
                sleep 3
            fi
        done
    done
    
    echo -e "\n${GREEN}✅ Evaluation abgeschlossen${NC}"
    log_info "Ergebnisse in: $RESULTS_DIR/evaluation_results.csv"
    
    # Finale Cleanup
    CURRENT_SERVER_IP=""
    CURRENT_SERVER_PASS=""
    CURRENT_MONITOR_SCRIPT_DIR=""
}

main "$@"
