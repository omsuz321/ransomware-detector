#!/bin/bash

# ============================================================
# OVERHEAD EVALUATION SCRIPT
# ============================================================
# PURPOSE:
#   Measures time and CPU overhead of ransomware detector on NFS
#   Performs A/B benchmarking: baseline (no detector) vs. with detector
#
# HOW IT WORKS:
#   1. Client runs FIO workload on NFS mount
#   2. Server pidstat monitors nfsd kernel thread CPU usage
#   3. In detector mode, also monitors detector process CPU
#   4. Collects: runtime, bandwidth, CPU metrics per run
#   5. Saves raw data (FIO JSON + pidstat logs) for reproducibility
#   6. Exports results to CSV for analysis
#
# USAGE:
#   ./run_overhead_evaluation.sh SERVER_IP MOUNT_PATH REPEAT COUNT PASSWORD [SCRIPT_DIR] [SIZE] [MODE]
#   Example: ./run_overhead_evaluation.sh 192.168.2.209 /mnt/nfs 5 1234 /home/server/Desktop/dev/scripts 100M randrw
#
# OUTPUT:
#   - CSV file: results/overhead_evaluation_TIMESTAMP.csv
#   - Raw data: results/raw_data_*/fio_*.json + pidstat_*.log
# ============================================================

set -euo pipefail

# --- DEBUG MODE ---
DEBUG="${DEBUG:-0}"
[ "$DEBUG" = "1" ] && set -x

# Redirect for hiding output (empty if DEBUG=1)
REDIRECT_OUTPUT="/dev/null"
REDIRECT_ERRORS="2>&1"
if [ "$DEBUG" = "1" ]; then
    REDIRECT_OUTPUT="/dev/stdout"
    REDIRECT_ERRORS=""
fi

# --- PARAMETERS: Command-line arguments ---
SERVER_IP="${1:-}"                              # Server IP address for SSH connection
CLIENT_MOUNT="${2:-/mnt/nfs}"                   # NFS mount path on client
REPEAT_COUNT="${3:-5}"                          # Number of runs per mode (baseline and detector separately)
SERVER_PASS="${4:-}"                            # Server password for sudo/SSH
MONITOR_SCRIPT_DIR="${5:-/home/server/Desktop/dev/scripts}"  # Path to detector scripts on server
FIO_SIZE="${6:-5G}"                             # Size of FIO test file (workload size)
FIO_MODE="${7:-write}"                          # FIO workload mode: write, read, randread, randwrite, randrw

# --- SERVER PATHS ---
SERVER_BASE_DIR="/srv/nfs/thesis_data"          # Base directory on NFS server
SERVER_WORK_DIR="$SERVER_BASE_DIR/tmp"          # Working directory on server (accessible via NFS)

# --- CLIENT-SIDE PATHS & FILES ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # Directory containing this script
RESULTS_DIR="$SCRIPT_DIR/../results"            # Directory for CSV results and raw data
mkdir -p "$RESULTS_DIR"

# Results CSV filename with timestamp (e.g., overhead_evaluation_20260303_210820.csv)
RESULTS_CSV="$RESULTS_DIR/overhead_evaluation_$(date +%Y%m%d_%H%M%S).csv"

# Determine where to put the FIO test file (derives tmp path from NFS mount)
# This ensures the test file is on the NFS-exported filesystem
if [[ "${CLIENT_MOUNT}" == */tmp* ]]; then
    CLIENT_TMP="${CLIENT_MOUNT%%/tmp*}/tmp"
elif [ "$(basename "${CLIENT_MOUNT%/}")" = "target" ]; then
    CLIENT_TMP="$(dirname "${CLIENT_MOUNT%/}")/tmp"
else
    CLIENT_TMP="${CLIENT_MOUNT%/}/tmp"
fi

# FIO test file location (will be created/deleted for each run)
FIO_TESTFILE="$CLIENT_TMP/fio_testfile"

# --- SSH OPTIONS ---
# Options for connecting to server without interactive prompts
SSH_OPTS=(
    -o StrictHostKeyChecking=no    # Skip host key verification (trusted connection)
    -o LogLevel=ERROR               # Suppress non-critical SSH messages
    -o ConnectTimeout=10            # 10 second timeout for connection attempts
)

# --- COLORS ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- LOGGING ---
log_info()    { echo -e " ${CYAN}[INFO]${NC}  $1"; }
log_success() { echo -e " ${GREEN}[OK]${NC}    $1"; }
log_error()   { echo -e " ${RED}[ERR]${NC}   $1"; }
log_warn()    { echo -e " ${YELLOW}[WARN]${NC}  $1"; }

# --- TRAP HANDLER FOR CTRL+C ---
# Ensures cleanup happens even when user interrupts with Ctrl+C
# This prevents detector from continuing to run during baseline measurements
cleanup_on_exit() {
    local exit_code=$?
    
    # CRITICAL: Remove trap handlers to prevent infinite loop
    # This allows user to force-quit with multiple Ctrl+C if needed
    trap - INT TERM EXIT
    
    echo ""
    log_warn "Script interrupted or exiting (code=$exit_code)"
    log_info "Performing emergency cleanup (press Ctrl+C again to force quit)..."
    
    # Stop all monitoring and detector processes (with timeout)
    timeout 5 bash -c "$(declare -f stop_cpu_monitoring); stop_cpu_monitoring" 2>/dev/null || true
    timeout 5 bash -c "$(declare -f stop_detector); stop_detector" 2>/dev/null || true
    
    # Aggressive cleanup on server (with timeout)
    if [ -n "${SERVER_PASS:-}" ] && [ -n "${SERVER_IP:-}" ]; then
        timeout 10 sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" bash -s "$SERVER_PASS" <<'TRAPEOF' >/dev/null 2>&1 || true
SERVER_PASS="$1"
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' pkill -9 pidstat 2>/dev/null || true
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' pkill -9 -f ransomware_logger 2>/dev/null || true
rm -f /tmp/pidstat*.pid /tmp/ransomware_logger.pid 2>/dev/null || true
TRAPEOF
    fi
    
    log_success "Cleanup complete. System state reset."
    exit $exit_code
}

# Register trap handlers for various exit conditions
# IMPORTANT: This ensures eBPF programs are unloaded even on Ctrl+C!
trap cleanup_on_exit INT TERM EXIT

# --- INITIALIZE CSV ---
# Creates empty CSV file with headers for storing benchmark results
# Columns:
#   mode - "baseline" or "detector"
#   run_num - run number (1, 2, 3...)
#   fio_runtime_sec - measured runtime in seconds
#   fio_bw_kbps - FIO bandwidth in KB/s
#   nfsd_avg_cpu_pct - average nfsd kernel thread CPU usage %
#   detector_avg_cpu_pct - average detector process CPU usage %
#   detector_cpu_seconds - CPU-seconds consumed by detector (cpu% * runtime)
#   timestamp - when the run was executed
#   fio_mode - FIO mode used (write, randrw, etc)
#   fio_size - FIO test file size
init_csv() {
    echo "mode,run_num,fio_runtime_sec,fio_bw_kbps,nfsd_avg_cpu_pct,detector_avg_cpu_pct,detector_cpu_seconds,timestamp,fio_mode,fio_size" > "$RESULTS_CSV"
    log_success "Results CSV: $RESULTS_CSV"
}

# --- VERIFY NO DETECTOR RUNNING ---
# CRITICAL: Verifies that NO detector is running on server
# This checks BOTH userspace process AND kernel eBPF programs!
# If either is active during baseline, results are INVALID
verify_no_detector_running() {
    log_info "Verifying NO detector is running on server..."
    
    local detector_check
    detector_check=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" bash -s "$SERVER_PASS" <<'VERIFYEOF'
SERVER_PASS="$1"

# Check for PID file
if [ -f /tmp/ransomware_logger.pid ]; then
    pid=$(cat /tmp/ransomware_logger.pid 2>/dev/null || echo "")
    if [ -n "$pid" ]; then
        if printf '%s\n' "$SERVER_PASS" | sudo -S -p '' kill -0 "$pid" 2>/dev/null; then
            echo "DETECTOR_RUNNING:$pid"
            exit 0
        fi
    fi
fi

# Check for any ransomware_logger process
if pgrep -f ransomware_logger >/dev/null 2>&1; then
    pid=$(pgrep -f ransomware_logger | head -1)
    echo "DETECTOR_RUNNING:$pid"
    exit 0
fi

# CRITICAL: Check for eBPF programs in kernel
# Even if userspace process is dead, eBPF might still be loaded!
if command -v bpftool >/dev/null 2>&1; then
    # Check for our specific eBPF program (ransomware detector)
    ebpf_count=$(printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bpftool prog list 2>/dev/null | grep -c "ransomware\|nfs_monitor\|file_monitor" 2>/dev/null || echo "0")
    if [ "$ebpf_count" -gt 0 ]; then
        echo "EBPF_LOADED:$ebpf_count"
        exit 0
    fi
fi

echo "NO_DETECTOR"
VERIFYEOF
    ) || echo "NO_DETECTOR"
    
    if [[ "$detector_check" == DETECTOR_RUNNING:* ]]; then
        local pid="${detector_check#DETECTOR_RUNNING:}"
        log_error "⚠️  DETECTOR PROCESS IS RUNNING (PID $pid) - THIS WILL CORRUPT RESULTS!"
        log_error "    Baseline measurements would include detector overhead!"
        log_error "    Stopping detector properly (including eBPF unload)..."
        
        # Use proper stop command to unload eBPF programs
        stop_detector
        sleep 2
        
        # Verify it's really dead (both userspace and eBPF)
        detector_check=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" bash -s "$SERVER_PASS" <<'RECHECKEOF'
SERVER_PASS="$1"

# Check userspace
if pgrep -f ransomware_logger >/dev/null 2>&1; then
    echo "STILL_RUNNING"
    exit 0
fi

# Check eBPF
if command -v bpftool >/dev/null 2>&1; then
    ebpf_count=$(printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bpftool prog list 2>/dev/null | grep -c "ransomware\|nfs_monitor\|file_monitor" 2>/dev/null || echo "0")
    if [ "$ebpf_count" -gt 0 ]; then
        echo "EBPF_STILL_LOADED"
        exit 0
    fi
fi

echo "CLEAN"
RECHECKEOF
)
        
        if [ "$detector_check" = "CLEAN" ]; then
            log_success "✓ Detector successfully stopped (userspace + eBPF)"
        else
            log_error "❌ Failed to stop detector completely!"
            log_error "    State: $detector_check"
            log_error "    Results will be INVALID!"
            return 1
        fi
        
    elif [[ "$detector_check" == EBPF_LOADED:* ]]; then
        local count="${detector_check#EBPF_LOADED:}"
        log_error "⚠️  eBPF PROGRAMS STILL LOADED IN KERNEL ($count programs)!"
        log_error "    This means kernel is still monitoring NFS operations!"
        log_error "    Unloading eBPF programs..."
        
        # Stop detector to unload eBPF
        stop_detector
        sleep 2
        
        # Verify eBPF is unloaded
        local ebpf_check
        ebpf_check=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" \
            "printf '%s\\n' '$SERVER_PASS' | sudo -S -p '' bpftool prog list 2>/dev/null | grep -c 'ransomware\|nfs_monitor\|file_monitor' 2>/dev/null || echo '0'")
        
        if [ "$ebpf_check" = "0" ]; then
            log_success "✓ eBPF programs successfully unloaded"
        else
            log_error "❌ Failed to unload eBPF programs! ($ebpf_check still loaded)"
            log_error "    Baseline results will be CORRUPTED!"
            return 1
        fi
    else
        log_success "✓ No detector running (verified: userspace + eBPF)"
    fi
}

# --- ENSURE CLEAN STATE ---
# Ensures NO leftover processes or eBPF programs from previous runs
# Removes:
#   - pidstat processes
#   - detector userspace processes  
#   - eBPF programs in kernel
#   - PID files
# CRITICAL: This must clean BOTH userspace AND kernel (eBPF)!
ensure_clean_state() {
    log_info "Ensuring clean state (killing stray processes + unloading eBPF)..."
    
    sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" bash -s "$SERVER_PASS" "$MONITOR_SCRIPT_DIR" <<'SSHEOF' >/dev/null 2>&1 || true
SERVER_PASS="$1"
MONITOR_SCRIPT_DIR="$2"

# Kill any stray pidstat processes
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' pkill -9 pidstat 2>/dev/null || true

# Stop detector properly (unloads eBPF)
cd "$MONITOR_SCRIPT_DIR"
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bash ./ransomware_monitor.sh stop 2>/dev/null || true

# Kill any remaining detector processes
if [ -f /tmp/ransomware_logger.pid ]; then
    pid=$(cat /tmp/ransomware_logger.pid 2>/dev/null || true)
    if [ -n "$pid" ]; then
        printf '%s\n' "$SERVER_PASS" | sudo -S -p '' kill -9 "$pid" 2>/dev/null || true
    fi
fi
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' pkill -9 -f ransomware_logger 2>/dev/null || true

# Manually unload any remaining eBPF programs (fail-safe)
if command -v bpftool >/dev/null 2>&1; then
    ebpf_ids=$(printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bpftool prog list 2>/dev/null | grep -E "ransomware|nfs_monitor|file_monitor" | awk '{print $1}' | tr -d ':' 2>/dev/null || true)
    for prog_id in $ebpf_ids; do
        printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bpftool prog detach id "$prog_id" 2>/dev/null || true
    done
fi

# Remove PID files
rm -f /tmp/pidstat_nfsd.pid /tmp/pidstat_detector.pid /tmp/ransomware_logger.pid 2>/dev/null || true
SSHEOF
    
    log_success "Clean state ensured (userspace + eBPF)"
}

# --- PREPARE SERVER ---
# Prepares server for a clean measurement:
# - Clears kernel page caches (important for consistent I/O patterns)
# - Removes leftover test files from previous runs
# - Fixes NFS permissions
# Must be called before each benchmark run
prepare_server() {
    log_info "Preparing server (clearing caches, ensuring tmp dir)..."
    
    # First, remove old fio test file on client
    rm -f "$FIO_TESTFILE" 2>/dev/null || true
    
    local ssh_output
    if [ "$DEBUG" = "1" ]; then
        log_info "[DEBUG] Connecting to server: $SERVER_IP"
    fi
    
    ssh_output=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" bash -s "$SERVER_PASS" "$CLIENT_TMP" <<'SSHEOF' 2>&1
set -euo pipefail
SERVER_PASS="$1"
CLIENT_TMP="$2"
SERVER_WORK_DIR="/srv/nfs/thesis_data/tmp"

echo "[DEBUG] Preparing server..."

# Ensure tmp dir exists
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' mkdir -p "$SERVER_WORK_DIR" 2>/dev/null || true

# Remove any leftover fio test files
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' rm -f "$CLIENT_TMP/fio_testfile" "$SERVER_WORK_DIR/fio_testfile" 2>/dev/null || true

# Fix permissions for NFS
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' chown -R nobody:nogroup "$SERVER_WORK_DIR" 2>/dev/null || true
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' chmod -R 777 "$SERVER_WORK_DIR" 2>/dev/null || true

# Sync and drop caches
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' sync
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bash -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true

echo "[DEBUG] Server preparation complete"
echo "OK"
SSHEOF
    ) || {
        log_error "Server preparation failed!"
        [ "$DEBUG" = "1" ] && echo "$ssh_output"
        return 1
    }
    
    if [ "$DEBUG" = "1" ]; then
        echo "$ssh_output"
    fi
    
    if ! echo "$ssh_output" | grep -q "OK"; then
        log_error "Server preparation did not complete successfully"
        echo "$ssh_output"
        return 1
    fi
    
    # Client-side: drop caches
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
    sleep 1
    
    log_success "Server prepared, caches cleared"
}

# --- CLEANUP AFTER RUN ---
# Post-run cleanup to reset system state and prevent interference with next run
# - Removes FIO test file from client
# - Flushes caches on both client and server
# Called after each measurement completes
cleanup_after_run() {
    log_info "Cleaning up after run (removing test file, flushing caches)..."
    
    # Remove fio test file on client
    rm -f "$FIO_TESTFILE" 2>/dev/null || true
    
    # Client-side: force sync and drop caches
    sync
    sleep 1
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
    
    # Server-side: remove test file and flush caches
    sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" bash -s "$SERVER_PASS" "$CLIENT_TMP" <<'SSHEOF' >/dev/null 2>&1 || true
set -euo pipefail
SERVER_PASS="$1"
CLIENT_TMP="$2"

# Remove fio test file from NFS export
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' rm -f "$CLIENT_TMP/fio_testfile" 2>/dev/null || true

# Sync and drop caches on server
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' sync
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bash -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
SSHEOF
    
    log_success "Cleanup complete"
}

# --- START CPU MONITORING ON SERVER (nfsd) ---
# Launches pidstat on server to monitor nfsd kernel thread CPU usage
# Arguments:
#   $1: mode ("baseline" or "detector")
#   $2: run number
# Pidstat output goes to log file: /tmp/pidstat_nfsd_MODE_runN.log
start_cpu_monitoring() {
    local mode="$1"
    local run_num="$2"
    local pidstat_log="/tmp/pidstat_nfsd_${mode}_run${run_num}.log"
    
    log_info "Starting CPU monitoring on server (mode=$mode)..."
    
    # Kill any old pidstat processes, then start fresh monitoring
    # pidstat flags:
    #   -u = show CPU usage
    #   -t = show thread info
    #   -C nfsd = monitor only nfsd kernel threads
    #   1 = sample every 1 second
    local cmd="pkill -9 'pidstat.*nfsd' 2>/dev/null || true; sleep 0.5; \
        nohup pidstat -u -t -C nfsd 1 > $pidstat_log 2>&1 &"
    
    if ! sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" \
        "printf '%s\n' \"$SERVER_PASS\" | sudo -S -p '' sh -c \"$cmd\""; then
        log_error "Failed to start nfsd CPU monitoring"
        return 1
    fi
    
    sleep 2
    log_success "CPU monitoring started (nfsd)"
}

# --- START CPU MONITORING (detector process) ---
# Launches pidstat to monitor the detector process CPU usage
# Arguments:
#   $1: run number
# Pidstat output goes to: /tmp/pidstat_detector_runN.log
start_detector_monitoring() {
    local run_num="$1"
    
    local pidstat_log="/tmp/pidstat_detector_run${run_num}.log"
    
    log_info "Starting CPU monitoring for detector..."
    
    # Wait a bit for detector to be running, then start pidstat
    sleep 2
    
    if ! sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" bash -s "$SERVER_PASS" "$pidstat_log" "$DEBUG" <<'SSHEOF'
set -euo pipefail
SERVER_PASS="$1"
PIDSTAT_LOG="$2"
DEBUG="$3"

if [ "$DEBUG" = "1" ]; then
    echo "[DEBUG] Starting pidstat for detector..." >&2
fi

# Get detector process ID from PID file (created by ransomware_monitor.sh)
    if [ ! -f /tmp/ransomware_logger.pid ]; then
        echo "ERROR: detector PID file missing (/tmp/ransomware_logger.pid)" >&2
        echo "  This means the detector didn't start properly" >&2
    exit 1
fi

DETECTOR_PID=$(cat /tmp/ransomware_logger.pid || echo "")
if [ -z "$DETECTOR_PID" ]; then
    echo "ERROR: detector PID file empty" >&2
    exit 1
fi

if [ "$DEBUG" = "1" ]; then
    echo "[DEBUG] Detector PID: $DETECTOR_PID" >&2
fi

# Start pidstat monitoring detector process
    # IMPORTANT: All commands must be in single sudo sh -c to maintain root context
    # Otherwise file redirection fails with "Permission denied"
    # pidstat flags:
    #   -u = show CPU usage
    #   -t = show thread info
    #   -p PID = monitor specific process only
    #   1 = sample every 1 second
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' sh -c "
    rm -f /tmp/pidstat_detector.pid \"$PIDSTAT_LOG\" 2>/dev/null || true
    nohup pidstat -u -t -p \"$DETECTOR_PID\" 1 > \"$PIDSTAT_LOG\" 2>&1 </dev/null &
    echo \$! > /tmp/pidstat_detector.pid
"

sleep 1

# Verify process is running
pid=$(printf '%s\n' "$SERVER_PASS" | sudo -S -p '' cat /tmp/pidstat_detector.pid 2>/dev/null || echo "")
if [ -z "$pid" ]; then
    echo "ERROR: detector pidstat PID file not created" >&2
    exit 1
fi
if ! printf '%s\n' "$SERVER_PASS" | sudo -S -p '' kill -0 "$pid" 2>/dev/null; then
    echo "ERROR: detector pidstat process not running (pid=$pid)" >&2
    exit 1
fi
echo "OK: detector pidstat started (pid=$pid)"
SSHEOF
    then
        log_error "Failed to start detector CPU monitoring"
        return 1
    fi
    
    sleep 1
    log_success "CPU monitoring started (detector)"
}

# --- STOP CPU MONITORING ---
# Terminates all pidstat processes on server
# Performs aggressive cleanup to ensure processes are dead
stop_cpu_monitoring() {
    log_info "Stopping CPU monitoring on server..."
    
    sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" bash -s "$SERVER_PASS" <<'SSHEOF' >/dev/null 2>&1 || true
SERVER_PASS="$1"

# Stop pidstat processes by PID file
for pidfile in /tmp/pidstat_nfsd.pid /tmp/pidstat_detector.pid; do
    if [ -f "$pidfile" ]; then
        pid=$(cat "$pidfile" 2>/dev/null || true)
        if [ -n "$pid" ]; then
            printf '%s\n' "$SERVER_PASS" | sudo -S -p '' kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$pidfile"
    fi
done

# Kill any remaining pidstat processes (aggressive cleanup)
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' pkill -9 -f "pidstat.*nfsd" 2>/dev/null || true
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' pkill -9 -f "pidstat.*-p" 2>/dev/null || true
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' pkill -9 pidstat 2>/dev/null || true
SSHEOF
    
    sleep 1
    log_success "CPU monitoring stopped"
}

# --- SAVE PIDSTAT LOGS FROM SERVER ---
# Downloads pidstat log files from server to local results directory
# These logs are saved for reproducibility and can be re-analyzed later
# Arguments:
#   $1: mode ("baseline" or "detector")
#   $2: run number
save_pidstat_logs() {
    local mode="$1"
    local run_num="$2"
    
    # Create results subdirectory for raw data (FIO JSON + pidstat logs)
    local results_subdir="$RESULTS_DIR/raw_data_$(basename "$RESULTS_CSV" .csv)"
    mkdir -p "$results_subdir"
    
    # Download nfsd CPU monitoring log from server
    local nfsd_log="/tmp/pidstat_nfsd_${mode}_run${run_num}.log"
    sshpass -p "$SERVER_PASS" scp -q "${SSH_OPTS[@]}" "server@$SERVER_IP:$nfsd_log" \
        "$results_subdir/pidstat_nfsd_${mode}_run${run_num}.log" 2>/dev/null || true
    
    # Download detector CPU monitoring log (only created in detector mode)
    # Used later to extract detector CPU usage statistics
    if [ "$mode" = "detector" ]; then
        local detector_log="/tmp/pidstat_detector_run${run_num}.log"
        sshpass -p "$SERVER_PASS" scp -q "${SSH_OPTS[@]}" "server@$SERVER_IP:$detector_log" \
            "$results_subdir/pidstat_detector_run${run_num}.log" 2>/dev/null || true
    fi
}

# --- GET CPU STATS FROM PIDSTAT LOG ---
# Parses pidstat log file and extracts average CPU usage percentage
# Arguments:
#   $1: mode ("baseline" or "detector")
#   $2: run number
#   $3: process type ("nfsd" or "detector")
# Returns: average CPU % across all samples in log
get_cpu_stats() {
    local mode="$1"
    local run_num="$2"
    local process_type="$3"  # "nfsd" or "detector"
    
    local pidstat_log="/tmp/pidstat_${process_type}_run${run_num}.log"
    if [ "$process_type" = "nfsd" ]; then
        pidstat_log="/tmp/pidstat_nfsd_${mode}_run${run_num}.log"
    fi
    
    if [ "$DEBUG" = "1" ]; then
        log_info "[DEBUG] Parsing CPU stats from: $pidstat_log" >&2
    fi
    
    # Parse pidstat output robustly using simple file-based approach
    local avg_cpu sample_count
    
    # Check if log file exists and has content
    local log_exists
    log_exists=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" \
        "[ -f '$pidstat_log' ] && [ -s '$pidstat_log' ] && echo '1' || echo '0'" 2>/dev/null || echo 0)
    
    if [ "$log_exists" -eq 0 ]; then
        # Log doesn't exist or is empty
        avg_cpu="0"
        sample_count="0"
    else
        # Parse pidstat output and calculate average CPU usage
        # AWK extracts %CPU column (3rd from right), validates it's numeric, sums and averages
        # Format: %.1f for one decimal place
        local result
        result=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" \
            "tail -100 '$pidstat_log' 2>/dev/null | awk 'NF>6 {cpu=\$(NF-2); if(cpu ~ /^[0-9]+(\\.[0-9]+)?$/) {sum+=cpu; count++}} END{if(count>0) printf \"%.1f,%d\", sum/count, count; else print \"0,0\"}' 2>/dev/null" || echo "0,0")
        
        avg_cpu="${result%%,*}"
        sample_count="${result##*,}"
    fi

    if [ "${sample_count:-0}" -eq 0 ]; then
        log_warn "⚠️  No CPU samples for $process_type (run $run_num)" >&2
        if [ "$process_type" = "detector" ]; then
            log_error "DETECTOR CPU IS 0% - This suggests detector is not running properly!" >&2
            log_error "Check if detector process exists and pidstat is monitoring it." >&2
        fi
        debug_pidstat_log "$pidstat_log"
        avg_cpu="0"
    elif [ "$DEBUG" = "1" ]; then
        log_info "[DEBUG] $process_type: avg_cpu=$avg_cpu%, samples=$sample_count" >&2
    fi
    
    # Special warning for detector with 0 or very low CPU
    if [ "$process_type" = "detector" ] && [ "${avg_cpu}" = "0" ] || [ "${avg_cpu}" = "0.0" ]; then
        log_error "⚠️  WARNING: Detector CPU is 0%!" >&2
        log_error "    This usually means:" >&2
        log_error "    1. Detector is not actually running" >&2
        log_error "    2. pidstat failed to monitor the detector process" >&2
        log_error "    3. Detector crashed immediately after start" >&2
        debug_pidstat_log "$pidstat_log"
    fi

    echo "$avg_cpu"
}

is_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

sanitize_number() {
    local value="$1"
    local fallback="${2:-0}"
    if is_number "$value"; then
        echo "$value"
    else
        echo "$fallback"
    fi
}

debug_pidstat_log() {
    local log_path="$1"
    [ "$DEBUG" != "1" ] && return 0

    log_info "[DEBUG] Checking pidstat log: $log_path" >&2
    sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" bash -s "$SERVER_PASS" <<DBGEOF >&2 || true
echo "[DEBUG] Log info for: $log_path"
printf '%s\n' "$1" | sudo -S -p '' ls -lh "$log_path" 2>/dev/null || echo "  Log file not found"
printf '%s\n' "$1" | sudo -S -p '' wc -l "$log_path" 2>/dev/null || echo "  Cannot read log"
echo "[DEBUG] First 10 lines:"
printf '%s\n' "$1" | sudo -S -p '' head -10 "$log_path" 2>/dev/null || echo "  Cannot read"
echo "[DEBUG] Last 20 lines:"
printf '%s\n' "$1" | sudo -S -p '' tail -20 "$log_path" 2>/dev/null || echo "  Cannot read"
DBGEOF
}

# --- START DETECTOR PROCESS ---
# Launches the ransomware detector on the server in background mode
# Uses ransomware_monitor.sh script on server
# Arguments:
#   $1: run ID (unique identifier for this detector instance)
start_detector() {
    local run_id="$1"
    local csv_path="/home/server/Desktop/run_evaluation.csv"
    
    log_info "Starting detector on server..."
    
    if [ "$DEBUG" = "1" ]; then
        log_info "[DEBUG] Detector script: $MONITOR_SCRIPT_DIR/ransomware_monitor.sh"
        log_info "[DEBUG] Run ID: $run_id"
    fi
    
    local detector_output
    detector_output=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" \
        "printf '%s\n' '$SERVER_PASS' | sudo -S -p '' $MONITOR_SCRIPT_DIR/ransomware_monitor.sh run-bg -o $csv_path --run-id $run_id --label overhead_test 2>&1")
    
    sleep 3
    
    # Verify detector is running
    local monitor_check
    monitor_check=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" bash -s "$SERVER_PASS" <<'SSHEOF'
SERVER_PASS="$1"
PID_FILE="/tmp/ransomware_logger.pid"
if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && printf '%s\n' "$SERVER_PASS" | sudo -S -p '' kill -0 "$pid" 2>/dev/null; then
        echo "RUNNING:$pid"
        exit 0
    fi
fi
echo "NOT_RUNNING"
SSHEOF
    ) || echo "NOT_RUNNING"
    
    if [[ "$monitor_check" == RUNNING:* ]]; then
        local pid="${monitor_check#RUNNING:}"
        log_success "Detector started (PID $pid)"
        
        # Double-check that detector is REALLY doing something
        sleep 2
        local cpu_test
        cpu_test=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" \
            "printf '%s\\n' '$SERVER_PASS' | sudo -S -p '' ps -p $pid -o pid,ppid,cpu,cmd --no-headers 2>/dev/null || echo 'NOT_FOUND'")
        
        if [ "$cpu_test" = "NOT_FOUND" ]; then
            log_error "Detector PID $pid not found in process list!"
            return 1
        else
            log_info "Detector process info: $cpu_test"
        fi
        
        return 0
    else
        log_error "Detector failed to start"
        log_error "Checking detector logs on server..."
        
        # Show detector logs from server
        sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" bash -s <<'SSHEOF' || true
echo "--- Detector background log ---"
tail -20 /tmp/ransomware_logger.bg.log 2>/dev/null || echo "No bg log found"
echo ""
echo "--- Detector PID file ---"
cat /tmp/ransomware_logger.pid 2>/dev/null || echo "No PID file found"
echo ""
echo "--- Recent detector processes ---"
ps aux | grep -i ransom | grep -v grep || echo "No detector process found"
SSHEOF
        
        return 1
    fi
}

# --- STOP DETECTOR PROCESS ---
# Stops the running detector process on server
# Uses ransomware_monitor.sh stop command
# --- STOP DETECTOR PROCESS ---
# Stops detector PROPERLY using ransomware_monitor.sh stop
# This ensures BOTH userspace process AND eBPF programs are unloaded
# CRITICAL: Just killing the process leaves eBPF in kernel!
stop_detector() {
    log_info "Stopping detector on server (userspace + eBPF)..."
    
    sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" bash -s "$SERVER_PASS" "$MONITOR_SCRIPT_DIR" <<'SSHEOF' 2>/dev/null || true
SERVER_PASS="$1"
MONITOR_SCRIPT_DIR="$2"

# Use proper stop command to unload eBPF programs
cd "$MONITOR_SCRIPT_DIR"
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bash ./ransomware_monitor.sh stop 2>&1 || true

sleep 1

# Fallback: Ensure detector process is really stopped
if [ -f /tmp/ransomware_logger.pid ]; then
    pid=$(cat /tmp/ransomware_logger.pid 2>/dev/null || true)
    if [ -n "$pid" ]; then
        # Check if still running
        if printf '%s\n' "$SERVER_PASS" | sudo -S -p '' kill -0 "$pid" 2>/dev/null; then
            printf '%s\n' "$SERVER_PASS" | sudo -S -p '' kill -9 "$pid" 2>/dev/null || true
        fi
    fi
    rm -f /tmp/ransomware_logger.pid
fi

# Fallback: Manually unload any remaining eBPF programs
if command -v bpftool >/dev/null 2>&1; then
    # Get IDs of our eBPF programs
    ebpf_ids=$(printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bpftool prog list 2>/dev/null | grep -E "ransomware|nfs_monitor|file_monitor" | awk '{print $1}' | tr -d ':' 2>/dev/null || true)
    
    if [ -n "$ebpf_ids" ]; then
        echo "[WARN] Manually unloading eBPF programs: $ebpf_ids" >&2
        for prog_id in $ebpf_ids; do
            printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bpftool prog detach id "$prog_id" 2>/dev/null || true
        done
    fi
fi
SSHEOF
    
    sleep 1
    log_success "Detector stopped (userspace + eBPF unloaded)"
}

# --- RUN FIO WORKLOAD ---
# Executes FIO benchmark on the NFS-mounted test file
# Collects: runtime (ms), bandwidth (KB/s), IOPS, latency
# Arguments:
#   $1: mode ("baseline" or "detector")
#   $2: run number
run_fio() {
    local mode="$1"
    local run_num="$2"
    
    local fio_json="/tmp/fio_${mode}_run${run_num}.json"
    
    log_info "Running fio (mode=$mode, run=$run_num)..."
    
    # Configure FIO workload parameters based on FIO_MODE
    # Supports: write, read, randread, randwrite, randrw (mixed), custom
    local fio_rw="write"
    local fio_rwmixread=""        # percentage of reads in mixed workload
    local fio_compress=""          # compression percentage
    local fio_bsrange=""           # block size range (e.g., 4k-32k)
    
    case "$FIO_MODE" in
        write|seq_write) 
            fio_rw="write"
            ;;
        randwrite|rand_write) 
            fio_rw="randwrite"
            ;;
        read|seq_read) 
            fio_rw="read"
            ;;
        randread|rand_read) 
            fio_rw="randread"
            ;;
        randrw|mixed|rw)
            fio_rw="randrw"
            fio_rwmixread="67"
            fio_compress="56"
            fio_bsrange="4k-32k"
            ;;
        *) 
            fio_rw="write"
            ;;
    esac
    
    # Build fio command with optional parameters
    local fio_cmd="fio \
        --name=overhead_test \
        --filename=$FIO_TESTFILE \
        --rw=$fio_rw \
        --size=$FIO_SIZE \
        --direct=1 \
        --end_fsync=1 \
        --output-format=json \
        --output=$fio_json"
    
    # Add bs or bsrange
    if [ -n "$fio_bsrange" ]; then
        fio_cmd="$fio_cmd --bsrange=$fio_bsrange"
    else
        fio_cmd="$fio_cmd --bs=128k"
    fi
    
    # Add rwmixread for mixed workloads
    [ -n "$fio_rwmixread" ] && fio_cmd="$fio_cmd --rwmixread=$fio_rwmixread"
    
    # Add compression percentage
    [ -n "$fio_compress" ] && fio_cmd="$fio_cmd --buffer_compress_percentage=$fio_compress"
    
    # Show fio command in debug mode
    if [ "$DEBUG" = "1" ]; then
        log_info "[DEBUG] FIO command: $fio_cmd"
    fi
    
    # Run fio
    local fio_output
    if [ "$DEBUG" = "1" ]; then
        eval "$fio_cmd"
        local fio_rc=$?
    else
        fio_output=$(eval "$fio_cmd" 2>&1)
        local fio_rc=$?
    fi
    
    if [ $fio_rc -ne 0 ]; then
        log_error "fio failed (rc=$fio_rc)"
        if [ "$DEBUG" != "1" ] && [ -n "$fio_output" ]; then
            echo "--- FIO Error Output ---"
            echo "$fio_output"
            echo "------------------------"
        fi
        log_error "fio failed (rc=$fio_rc)"
        return 1
    fi
    
    # Parse JSON: extract runtime (ms) and bandwidth (KB/s)
    local runtime_ms bw_kbps
    runtime_ms=$(jq -r '.jobs[0].job_runtime // 0' "$fio_json" 2>/dev/null || echo "0")
    
    # Bandwidth depends on read or write
    if [[ "$fio_rw" == *read* ]]; then
        bw_kbps=$(jq -r '.jobs[0].read.bw // 0' "$fio_json" 2>/dev/null || echo "0")
    else
        bw_kbps=$(jq -r '.jobs[0].write.bw // 0' "$fio_json" 2>/dev/null || echo "0")
    fi
    
    local runtime_sec=$(awk "BEGIN {print $runtime_ms / 1000.0}")
    
    log_success "fio completed: ${runtime_sec}s, ${bw_kbps} KB/s"
    
    # Force sync to ensure all data is written to NFS server
    log_info "Syncing data to server..."
    sync
    sleep 1
    
    # Return values via file for parent process to read
    echo "$runtime_sec" > "/tmp/fio_runtime_${mode}_${run_num}.tmp"
    echo "$bw_kbps" > "/tmp/fio_bw_${mode}_${run_num}.tmp"
    
    # Save FIO JSON to results directory for later reproducibility and re-analysis
    # Raw data files allow independent verification and re-analysis without re-running benchmark
    local results_subdir="$RESULTS_DIR/raw_data_$(basename "$RESULTS_CSV" .csv)"
    mkdir -p "$results_subdir"
    if [ -f "$fio_json" ]; then
        cp "$fio_json" "$results_subdir/fio_${mode}_run${run_num}.json"
    fi
    
    # Cleanup fio test file (will be cleaned again in cleanup_after_run)
    rm -f "$FIO_TESTFILE" 2>/dev/null || true
    rm -f "$fio_json" 2>/dev/null || true
    
    return 0
}

# === RUN ONE MEASUREMENT CYCLE ===
# Complete workflow for a single benchmark run:
# 1. Ensure clean state (no stray processes)
# 2. Prepare server (clear caches)
# 3. Start CPU monitoring (pidstat)
# 4. Start detector (if detector mode)
# 5. Run FIO workload
# 6. Stop monitoring and detector
# 7. Collect results (runtime, bandwidth, CPU stats)
# 8. Save raw data (FIO JSON, pidstat logs)
# 9. Cleanup (remove test file, flush caches)
run_measurement() {
    local mode="$1"       # "baseline" or "detector"
    local run_num="$2"
    
    echo -e "\n${YELLOW}=== Run $run_num ($mode) ===${NC}"
    
    # === STEP 1: Ensure clean state ===
    # Kill any stray processes from previous runs to prevent interference
    ensure_clean_state
    
    # === STEP 1b: Verify no detector running (CRITICAL for baseline) ===
    # In baseline mode, verify that NO detector is running
    # If detector runs during baseline, overhead measurements are INVALID
    if [ "$mode" = "baseline" ]; then
        if ! verify_no_detector_running; then
            log_error "Cannot proceed with baseline - detector is still running!"
            return 1
        fi
    fi
    
    # === STEP 2: Prepare server ===
    # Clear caches and ensure directories exist with correct permissions
    prepare_server
    
    # === STEP 3: Start CPU monitoring ===
    # Launch pidstat on server to monitor nfsd kernel thread CPU usage
    start_cpu_monitoring "$mode" "$run_num"
    
    # === STEP 4: Start detector (detector mode only) ===
    # In detector mode, start the ransomware detector and its CPU monitoring
    local detector_pid=""
    if [ "$mode" = "detector" ]; then
        local run_id="overhead_${mode}_run${run_num}_$$"
        if ! start_detector "$run_id"; then
            log_error "Failed to start detector, skipping this run"
            stop_cpu_monitoring
            return 1
        fi
        start_detector_monitoring "$run_num"
    fi
    
    # Wait a bit for monitoring to stabilize before starting I/O
    sleep 2
    
    # === STEP 5: Run FIO workload ===
    # Execute FIO benchmark on NFS mount
    if ! run_fio "$mode" "$run_num"; then
        log_error "fio failed, skipping this run"
        [ "$mode" = "detector" ] && stop_detector
        stop_cpu_monitoring
        return 1
    fi
    
    # === STEP 6: Stop monitoring ===
    # Wait a bit for final samples to be collected
    sleep 2
    stop_cpu_monitoring
    
    # === STEP 7: Save raw data ===
    # Download pidstat logs from server for reproducibility
    save_pidstat_logs "$mode" "$run_num"
    
    # === STEP 8: Stop detector (detector mode only) ===
    [ "$mode" = "detector" ] && stop_detector
    
    # === STEP 9: Collect and record results ===
    # Extract measurements from saved files and logs
    local runtime_sec bw_kbps nfsd_cpu detector_cpu detector_cpu_sec
    
    runtime_sec=$(sanitize_number "$(cat "/tmp/fio_runtime_${mode}_${run_num}.tmp" 2>/dev/null || echo "0")" 0)
    bw_kbps=$(sanitize_number "$(cat "/tmp/fio_bw_${mode}_${run_num}.tmp" 2>/dev/null || echo "0")" 0)
    nfsd_cpu=$(sanitize_number "$(get_cpu_stats "$mode" "$run_num" "nfsd")" 0)
    
    if [ "$mode" = "detector" ]; then
        detector_cpu=$(sanitize_number "$(get_cpu_stats "$mode" "$run_num" "detector")" 0)
        detector_cpu_sec=$(awk "BEGIN {print ($detector_cpu / 100.0) * $runtime_sec}")
        
        # CRITICAL CHECK: Detector CPU should NOT be 0
        if [ "$detector_cpu" = "0" ] || [ "$detector_cpu" = "0.0" ]; then
            log_error "⚠️⚠️⚠️  DETECTOR CPU IS 0%! ⚠️⚠️⚠️"
            log_error "This measurement is likely INVALID!"
            log_error "The detector may not have been running properly."
            log_error "Consider re-running this measurement or investigating detector logs."
        fi
    else
        detector_cpu="0"
        detector_cpu_sec="0"
    fi
    
    # Write results to CSV file for later analysis
    local timestamp=$(date +%Y-%m-%d_%H:%M:%S)
    echo "$mode,$run_num,$runtime_sec,$bw_kbps,$nfsd_cpu,$detector_cpu,$detector_cpu_sec,$timestamp,$FIO_MODE,$FIO_SIZE" >> "$RESULTS_CSV"
    
    log_success "Results saved: runtime=${runtime_sec}s, nfsd_cpu=${nfsd_cpu}%, detector_cpu=${detector_cpu}%"
    
    # Clean up temporary files from this run
    rm -f "/tmp/fio_runtime_${mode}_${run_num}.tmp" "/tmp/fio_bw_${mode}_${run_num}.tmp"
    
    # === STEP 10: Cleanup system state ===
    # Reset system state to prevent interference with next run
    cleanup_after_run
    
    return 0
}

# --- CALCULATE AND DISPLAY SUMMARY ---
# Analyzes results CSV and displays overhead statistics
# Calculates: median runtime, CPU usage, and overhead percentages
display_summary() {
    log_info "Calculating summary statistics..."
    
    # Use python or awk to calculate median and overhead
    python3 <<EOF
import csv
import statistics

with open("$RESULTS_CSV", "r") as f:
    reader = csv.DictReader(f)
    data = list(reader)

baseline = [d for d in data if d["mode"] == "baseline"]
detector = [d for d in data if d["mode"] == "detector"]

if baseline and detector:
    baseline_times = [float(d["fio_runtime_sec"]) for d in baseline]
    detector_times = [float(d["fio_runtime_sec"]) for d in detector]
    
    baseline_median = statistics.median(baseline_times)
    detector_median = statistics.median(detector_times)
    
    time_overhead_pct = ((detector_median - baseline_median) / baseline_median) * 100
    
    baseline_cpu_nfsd = [float(d["nfsd_avg_cpu_pct"]) for d in baseline]
    detector_cpu_nfsd = [float(d["nfsd_avg_cpu_pct"]) for d in detector]
    detector_cpu_det = [float(d["detector_avg_cpu_pct"]) for d in detector]
    
    baseline_nfsd_median = statistics.median(baseline_cpu_nfsd)
    detector_nfsd_median = statistics.median(detector_cpu_nfsd)
    detector_det_median = statistics.median(detector_cpu_det)
    
    print("")
    print("=" * 60)
    print("OVERHEAD SUMMARY")
    print("=" * 60)
    print("")
    print(f"Baseline (no detector):")
    print(f"  Median runtime:     {baseline_median:.2f}s")
    print(f"  Median nfsd CPU:    {baseline_nfsd_median:.2f}%")
    print("")
    print(f"With detector:")
    print(f"  Median runtime:     {detector_median:.2f}s")
    print(f"  Median nfsd CPU:    {detector_nfsd_median:.2f}%")
    print(f"  Median detector CPU: {detector_det_median:.2f}%")
    print("")
    print(f"Overhead:")
    print(f"  Time overhead:      {time_overhead_pct:+.2f}%")
    print(f"  nfsd CPU change:    {detector_nfsd_median - baseline_nfsd_median:+.2f}%")
    print(f"  Detector CPU:       {detector_det_median:.2f}%")
    print("")
    print("=" * 60)
    print("")
else:
    print("Not enough data for summary")
EOF
}

# --- MAIN ---
main() {
    echo -e "\n${BLUE}============================================${NC}"
    echo -e "${BLUE} OVERHEAD EVALUATION${NC}"
    if [ "$DEBUG" = "1" ]; then
        echo -e "${YELLOW} [DEBUG MODE ENABLED]${NC}"
    fi
    echo -e "${BLUE}============================================${NC}\n"
    
    # Check dependencies
    for cmd in fio jq sshpass python3; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Required command not found: $cmd"
            log_error "Install with: sudo apt-get install $cmd"
            exit 1
        fi
    done
    if [ "$DEBUG" = "1" ]; then
        log_info "[DEBUG] All client dependencies found"
    fi
    
    log_info "Server: $SERVER_IP"
    log_info "Mount: $CLIENT_MOUNT"
    log_info "Repeat count: $REPEAT_COUNT per mode"
    log_info "FIO: size=$FIO_SIZE, mode=$FIO_MODE"
    log_info "Test file: $FIO_TESTFILE"
    
    if [ "$DEBUG" = "1" ]; then
        log_info "[DEBUG] Monitor script dir: $MONITOR_SCRIPT_DIR"
        log_info "[DEBUG] Results dir: $RESULTS_DIR"
        log_info "[DEBUG] Client TMP: $CLIENT_TMP"
    fi
    echo ""
    
    # Check if sysstat is installed on server
    log_info "Checking server dependencies..."
    if ! sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" "command -v pidstat >/dev/null 2>&1"; then
        log_error "pidstat not found on server. Install sysstat package:"
        log_error "  sudo apt-get install sysstat"
        exit 1
    fi
    log_success "Server dependencies OK"
    
    # Initialize CSV
    init_csv
    
    # === PHASE 1: BASELINE MEASUREMENTS ===
    # Run benchmark without detector to establish baseline performance
    echo -e "\n${CYAN}>>> Phase 1: Baseline measurements (no detector) <<<${NC}"
    for i in $(seq 1 "$REPEAT_COUNT"); do
        run_measurement "baseline" "$i" || log_warn "Baseline run $i failed"
        sleep 3        # Wait between runs for system stabilization
    done
    
    # === PHASE 2: DETECTOR MEASUREMENTS ===
    # Run benchmark with detector running to measure its overhead
    echo -e "\n${CYAN}>>> Phase 2: Detector measurements <<<${NC}"
    for i in $(seq 1 "$REPEAT_COUNT"); do
        run_measurement "detector" "$i" || log_warn "Detector run $i failed"
        sleep 3        # Wait between runs for system stabilization
    done
    
    echo -e "\n${GREEN}>>> All measurements complete <<<${NC}\n"
    
    # === FINAL SUMMARY ===
    # Display statistical summary of all measurements
    display_summary
    
    # Show where results were saved
    local results_subdir="$RESULTS_DIR/raw_data_$(basename "$RESULTS_CSV" .csv)"
    log_success "Results saved to: $RESULTS_CSV"
    log_success "Raw data (FIO JSON, pidstat logs) saved to: $results_subdir/"
    echo ""
    echo -e "${CYAN}To analyze results later, run:${NC}"
    echo -e "  python3 $SCRIPT_DIR/analyze_overhead_results.py $RESULTS_CSV"
    echo -e "${CYAN}Or for raw data directory:${NC}"
    echo -e "  python3 $SCRIPT_DIR/analyze_overhead_results.py $results_subdir/"
    echo ""
}

# --- USAGE ---
if [ $# -lt 4 ]; then
    echo "Usage: $0 SERVER_IP CLIENT_MOUNT REPEAT_COUNT SERVER_PASS [MONITOR_SCRIPT_DIR] [FIO_SIZE] [FIO_MODE]"
    echo ""
    echo "Examples:"
    echo "  $0 192.168.1.10 /mnt/nfs 5 mypassword /home/server/Desktop/dev/scripts 5G write"
    echo "  $0 192.168.1.10 /mnt/nfs 5 mypassword /home/server/Desktop/dev/scripts 5G randrw"
    echo ""
    echo "FIO_MODE options:"
    echo "  write      - Sequential write (default)"
    echo "  randwrite  - Random write"
    echo "  read       - Sequential read"
    echo "  randread   - Random read"
    echo "  randrw     - Mixed random RW (67% read / 33% write, 56% compressed)"
    echo ""
    echo "Debug mode:"
    echo "  DEBUG=1 $0 <args>   - Show detailed output and errors"
    exit 1
fi

main "$@"
