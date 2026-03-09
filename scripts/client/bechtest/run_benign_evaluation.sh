#!/bin/bash

# ============================================================
# BENIGN EVALUATION HARNESS
# Runs benign workloads with ransomware monitor integration
# ============================================================

set -euo pipefail

# --- PARAMETERS ---
SERVER_IP="${1:-}"
CLIENT_MOUNT="${2:-/mnt/nfs}"
DURATION="${3:-60}"
SERVER_PASS="${4:-}"
WORKLOAD_TYPE="${5:-}"
WORKLOAD_ARG="${6:-all}"
REPEAT_COUNT="${7:-1}"
MONITOR_SCRIPT_DIR="${8:-/home/server/Desktop/dev/scripts}"

# Server-side paths (similar to ransomware evaluation)
SERVER_BASE_DIR="/srv/nfs/thesis_data"
SERVER_SOURCE_DIR="$SERVER_BASE_DIR/target"
SERVER_WORK_DIR="$SERVER_BASE_DIR/tmp"

# --- SETUP PATHS ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"
mkdir -p "$RESULTS_DIR"

# --- COLORS ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- LOGGING ---
log_info()    { echo -e " [INFO] $1"; }
log_success() { echo -e " ${GREEN}[OK]${NC}   $1"; }
log_error()   { echo -e " ${RED}[ERR]${NC}  $1"; }
log_warn()    { echo -e " ${YELLOW}[WARN]${NC} $1"; }

# --- RESOLVE CLIENT PATHS ---
resolve_paths() {
    if [[ "${CLIENT_MOUNT}" == */tmp* ]]; then
        CLIENT_TMP="${CLIENT_MOUNT%%/tmp*}/tmp"
    elif [ "$(basename "${CLIENT_MOUNT%/}")" = "target" ]; then
        CLIENT_TMP="$(dirname "${CLIENT_MOUNT%/}")/tmp"
    else
        CLIENT_TMP="${CLIENT_MOUNT%/}/tmp"
    fi

    if [[ "${CLIENT_MOUNT}" == */target* ]]; then
        CLIENT_TARGET="${CLIENT_MOUNT%/}"
    elif [[ "${CLIENT_MOUNT}" == */tmp/* ]]; then
        CLIENT_TARGET="${CLIENT_MOUNT%%/tmp*}/target"
    else
        CLIENT_TARGET="${CLIENT_MOUNT%/}/target"
    fi
}

resolve_paths

SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o LogLevel=ERROR
    -o ConnectTimeout=10
)

# --- SETUP SERVER CACHE & DATA ---
setup_server_for_workload() {
    local label="$1"
    log_info "Setup Server: clearing caches..."
    
    sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" bash -s "$SERVER_PASS" <<'SSHEOF'
set -euo pipefail
SERVER_PASS="$1"
SERVER_BASE_DIR="/srv/nfs/thesis_data"
SERVER_SOURCE_DIR="$SERVER_BASE_DIR/target"
SERVER_WORK_DIR="$SERVER_BASE_DIR/tmp"

# Erstelle Work-Verzeichnis
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' mkdir -p "$SERVER_WORK_DIR"

# Leere tmp komplett
echo "[DEBUG] Clearing $SERVER_WORK_DIR..."
for i in 1 2 3; do
    printf '%s\n' "$SERVER_PASS" | sudo -S -p '' rm -rf "$SERVER_WORK_DIR"/* 2>/dev/null && break || sleep 1
done

# Kopiere Daten
echo "[DEBUG] Copying from $SERVER_SOURCE_DIR to $SERVER_WORK_DIR..."
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' cp -a "$SERVER_SOURCE_DIR"/* "$SERVER_WORK_DIR"/ 2>&1 | tail -3

# Fix Permissions - wichtig für NFS
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' chown -R nobody:nogroup "$SERVER_WORK_DIR" 2>/dev/null || true
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' chmod -R 777 "$SERVER_WORK_DIR" 2>/dev/null || true
if [ -n "$(find "$SERVER_WORK_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bash -c 'cd "$1" && chmod -R 777 ./*' _ "$SERVER_WORK_DIR" 2>/dev/null || true
fi

# Server-seitig synced
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' sync
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bash -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true

echo "OK"
SSHEOF
    
    local result=$?
    if [ $result -ne 0 ]; then
        log_error "Server setup failed"
        return 1
    fi
    
    # Client-seitig: Cache leeren
    log_info "Clearing client cache..."
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
    sleep 1
    
    log_success "Server and client caches cleared"
    return 0
}

# --- CLEAR CACHES ONLY (for compress, no copy) ---
clear_caches_only() {
    log_info "Clearing server tmp and caches..."
    
    # Server-seitig: leere tmp, sync caches
    sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" bash -s "$SERVER_PASS" <<'SSHEOF'
set -euo pipefail
SERVER_PASS="$1"
SERVER_WORK_DIR="/srv/nfs/thesis_data/tmp"

# Leere tmp (aber kopiere nicht, die Quelle ist schon da!)
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' rm -rf "$SERVER_WORK_DIR"/* 2>/dev/null || true

# Sync und drop caches
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' sync
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bash -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true

echo "OK"
SSHEOF
    
    # Client-seitig: Cache leeren
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
    sleep 1
    
    log_success "Server tmp cleared, caches dropped"
    return 0
}

# --- CLEANUP SERVER TMP (after workload iteration) ---
cleanup_server_tmp() {
    log_info "Cleaning up server tmp directory..."
    
    sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" bash -s "$SERVER_PASS" <<'SSHEOF'
set -euo pipefail
SERVER_PASS="$1"
SERVER_WORK_DIR="/srv/nfs/thesis_data/tmp"

# Remove all files from tmp to free up space
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' rm -rf "$SERVER_WORK_DIR"/* 2>/dev/null || true

# Sync to ensure deletion is written
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' sync

echo "OK"
SSHEOF
    
    local result=$?
    if [ $result -eq 0 ]; then
        log_success "Server tmp cleaned"
    else
        log_warn "Server tmp cleanup may have failed"
    fi
    
    return 0
}

# --- MONITOR FUNCTIONS ---
start_monitor() {
    local run_id="$1"
    local csv_path="/home/server/Desktop/run_evaluation.csv"
    
    log_info "Starting monitor on server..."
    
    # Launch monitor on server with sudo (using -S for password from stdin)
    sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" \
        "printf '%s\n' '$SERVER_PASS' | sudo -S -p '' $MONITOR_SCRIPT_DIR/ransomware_monitor.sh run-bg -o $csv_path --run-id $run_id --label benign 2>&1" &
    
    sleep 3  # Give monitor time to start on server
    
    # Verify monitor is running by checking PID file and process
    local monitor_check
    monitor_check=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" bash -s "$SERVER_PASS" <<'SSHEOF'
SERVER_PASS="$1"
PID_FILE="/tmp/ransomware_logger.pid"

if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "RUNNING:$pid"
        exit 0
    fi
fi
echo "NOT_RUNNING"
exit 1
SSHEOF
    ) || echo "NOT_RUNNING"
    
    if [[ "$monitor_check" == RUNNING:* ]]; then
        local pid="${monitor_check#RUNNING:}"
        log_success "Monitor started (PID $pid on server)"
        return 0
    else
        log_warn "Monitor may not have started - checking logs..."
        sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" \
            "tail -10 /tmp/ransomware_logger.bg.log 2>/dev/null" || true
        return 1
    fi
}

stop_monitor() {
    log_info "Stopping monitor on server..."
    
    # Use the monitor's built-in stop command (properly stops and unloads BPF)
    sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" bash -s "$SERVER_PASS" "$MONITOR_SCRIPT_DIR" <<'SSHEOF' 2>/dev/null || true
SERVER_PASS="$1"
MONITOR_SCRIPT_DIR="$2"

cd "$MONITOR_SCRIPT_DIR"
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bash ./ransomware_monitor.sh stop >/dev/null 2>&1 || true
SSHEOF
    
    sleep 1
    log_success "Monitor stopped"
}

check_detection_csv() {
    local csv_path="$1"
    local run_id="$2"
    
    # CSV format: run_id,label,attack_start_time,user_created_time,detection_status,detection_time
    # detection_status = 1 means ransomware was detected
    
    local result
    result=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" \
        "grep '^$run_id,' '$csv_path' 2>/dev/null | tail -1 | cut -d',' -f5" 2>/dev/null || echo "0")
    
    [ "$result" = "1" ] && return 0 || return 1
}

# --- WORKLOAD FUNCTIONS ---

run_compress_workload() {
    local source_arg="$1"
    local run_id="$2"
    
    # QUA LE: das Objekt zu komprimieren (z.B. /mnt/nfs/target/all)
    local client_source_path
    if [ "$source_arg" = "all" ]; then
        if [ -d "$CLIENT_TARGET/all" ]; then
            client_source_path="$CLIENT_TARGET/all"
        elif [ -d "$CLIENT_TMP/all" ]; then
            client_source_path="$CLIENT_TMP/all"
        else
            log_error "Source not found: $CLIENT_TARGET/all or $CLIENT_TMP/all"
            return 1
        fi
    else
        client_source_path="$CLIENT_TMP/$source_arg"
    fi
    
    # ZIEL: TAR-Archiv direkt in tmp
    log_info "Compressing: $client_source_path"
    log_info "Output dir: $CLIENT_TMP (tar archives)"
    
    # Ensure NFS tmp dir exists and is writable
    mkdir -p "$CLIENT_TMP" 2>/dev/null || true
    sudo chmod 777 "$CLIENT_TMP" 2>/dev/null || true
    
    local iter=0
    local end_time=$((SECONDS + DURATION))
    
    while [ "$SECONDS" -lt "$end_time" ]; do
        local archive="$CLIENT_TMP/benign_compress_${run_id}_${iter}.tar"
        
        # Delete previous archive if exists
        [ $iter -gt 0 ] && rm -f "$CLIENT_TMP/benign_compress_${run_id}_$((iter-1)).tar" 2>/dev/null || true
        
        # Clear caches BEFORE tar
        sync
        echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
        sleep 0.2
        
        # TAR: lese von source_path, schreibe Archiv direkt nach tmp
        local remaining=$((end_time - SECONDS))
        if [ "$remaining" -le 0 ]; then
            log_info "Duration reached before next tar run"
            break
        fi

        log_info "  [iter $iter] tar: $client_source_path -> $archive"
        if ! timeout --signal=TERM --kill-after=5s "${remaining}s" \
            tar -cf "$archive" -C "$(dirname "$client_source_path")" "$(basename "$client_source_path")"; then
            local tar_rc=$?
            if [ "$tar_rc" -eq 124 ]; then
                log_warn "  [iter $iter] tar stopped at duration limit (${DURATION}s)"
                rm -f "$archive" 2>/dev/null || true
                break
            fi
            log_error "Archive failed (rc=$tar_rc): $archive"
            return 1
        fi
        
        # Clear caches AFTER tar to flush writes to NFS
        sync
        echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
        sleep 0.1
        
        if [ -f "$archive" ]; then
            local size=$(du -h "$archive" | cut -f1)
            log_success "  [iter $iter] $size archive in tmp"
        else
            log_error "Archive failed: $archive"
            return 1
        fi
        
        iter=$((iter + 1))
    done
    
    log_success "Compress done ($iter archives)"
    return 0
}

run_fio_workload() {
    local target_arg="$1"
    local target_path="$CLIENT_TARGET"
    
    [ "$target_arg" != "target" ] && [ "$target_arg" != "all" ] && target_path="$CLIENT_TARGET/$target_arg"
    [ "$target_arg" = "all" ] && target_path="$CLIENT_TARGET/all"
    
    if [ ! -d "$target_path" ]; then
        log_error "FIO target not found: $target_path"
        return 1
    fi
    
    log_info "Running FIO on: $target_path"
    
    fio \
        --name=rw67_c33 \
        --directory="$target_path" \
        --rw=randrw \
        --rwmixread=67 \
        --buffer_compress_percentage=33 \
        --bsrange=4k-32k \
        --runtime="$DURATION" \
        --time_based \
        --overwrite=1 \
        --size=10G \
        >/dev/null 2>&1 &
    
    local fio_pid=$!
    wait $fio_pid || true
    
    log_success "FIO finished"
    return 0
}

run_copy_workload() {
    local source="$1"
    
    if [ ! -e "$source" ]; then
        log_error "Copy source not found: $source"
        return 1
    fi
    
    log_info "Copying from: $source"
    
    timeout "$DURATION" bash -c "
        while true; do
            cp -r '$source' '$CLIENT_TMP/' 2>/dev/null || true
        done
    " || rc=$?
    
    log_success "Copy finished"
    return 0
}

# --- MAIN ---
main() {
    echo -e "\n${BLUE}============================================${NC}"
    echo -e "${BLUE} BENIGN EVALUATION HARNESS${NC}"
    echo -e "${BLUE}============================================${NC}\n"
    
    log_info "WORKLOAD_TYPE=$WORKLOAD_TYPE"
    log_info "WORKLOAD_ARG=$WORKLOAD_ARG"
    log_info "DURATION=${DURATION}s, REPEAT_COUNT=$REPEAT_COUNT"
    log_info "CLIENT_TMP=$CLIENT_TMP, CLIENT_TARGET=$CLIENT_TARGET"
    echo ""
    
    for repeat in $(seq 1 "$REPEAT_COUNT"); do
        local run_id="${WORKLOAD_TYPE}_rep$(printf '%03d' $repeat)_$$"
        
        echo -e "\n${YELLOW}---- Run $repeat/$REPEAT_COUNT ($WORKLOAD_TYPE) ----${NC}"
        log_info "Run-ID: $run_id"
        
        # Setup server: compress needs cache clear only, others need data prep
        if [ "$WORKLOAD_TYPE" = "compress" ]; then
            clear_caches_only
        else
            setup_server_for_workload "$WORKLOAD_TYPE"
        fi
        
        # Start monitor
        if ! start_monitor "$run_id" 2>/dev/null; then
            log_warn "Monitor failed - continuing without monitoring"
        fi
        
        # Run workload
        log_info "Starting workload..."
        case "$WORKLOAD_TYPE" in
            compress)
                run_compress_workload "$WORKLOAD_ARG" "$run_id" || true
                ;;
            fio)
                run_fio_workload "$WORKLOAD_ARG" || true
                ;;
            copy)
                run_copy_workload "$WORKLOAD_ARG" || true
                ;;
            *)
                log_error "Unknown workload: $WORKLOAD_TYPE"
                stop_monitor
                return 1
                ;;
        esac
        
        # Check detection
        if check_detection_csv "/home/server/Desktop/run_evaluation.csv" "$run_id" 2>/dev/null; then
            log_warn "RANSOMWARE DETECTED! (False Positive)"
        else
            log_success "No ransomware detected (correct)"
        fi
        
        # Stop monitor
        stop_monitor
        
        # Cleanup server tmp after iteration (free up space)
        cleanup_server_tmp
        
        [ "$repeat" -lt "$REPEAT_COUNT" ] && sleep 2
    done
    
    echo -e "\n${GREEN}Done.${NC}"
    log_info "Results: $RESULTS_DIR/benign_evaluation_results.csv"
}

main "$@"
