#!/bin/bash

# ============================================================
# AUTOMATED BENIGN EVALUATION RUNNER
# Runs copy/compress/fio benign workloads sequentially
# ============================================================

set -euo pipefail

REPEAT_COUNT="${1:-1}"
COPY_SOURCE="${2:-}"           # optional: required only for copy workload
CLIENT_MOUNT="${3:-/mnt/nfs/target}"
DURATION="${4:-300}"

SERVER_IP="192.168.2.209"
SERVER_PASS="1234"
MONITOR_SCRIPT_DIR="/home/server/Desktop/dev/scripts"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$SCRIPT_DIR/run_benign_evaluation.sh"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "\n${BLUE}============================================${NC}"
echo -e "${BLUE} Start benign evaluations${NC}"
echo -e "${BLUE} Repeat count: $REPEAT_COUNT${NC}"
echo -e "${BLUE} Client mount: $CLIENT_MOUNT${NC}"
echo -e "${BLUE} Duration: ${DURATION}s${NC}"
echo -e "${BLUE}============================================${NC}\n"

if [ ! -x "$HARNESS" ]; then
    echo -e "${YELLOW}[WARN] Harness is not executable, fixing...${NC}"
    chmod +x "$HARNESS"
fi

run_workload() {
    local workload="$1"
    local arg="$2"
    echo -e "\n${GREEN}========== Workload: $workload (${REPEAT_COUNT}x) ==========${NC}\n"
    "$HARNESS" \
        "$SERVER_IP" \
        "$CLIENT_MOUNT" \
        "$DURATION" \
        "$SERVER_PASS" \
        "$workload" \
        "$arg" \
        "$REPEAT_COUNT" \
        "$MONITOR_SCRIPT_DIR"
}

if [ -n "$COPY_SOURCE" ]; then
    run_workload "copy" "$COPY_SOURCE"
else
    echo -e "${YELLOW}[WARN] No COPY_SOURCE provided - skipping copy workload.${NC}"
    echo -e "${YELLOW}       Pass as 2nd arg to include copy workload.${NC}"
fi

run_workload "compress" "all"
run_workload "fio" "target"

echo -e "\n${GREEN}============================================${NC}"
echo -e "${GREEN} Done: all benign workloads finished${NC}"
echo -e "${GREEN}============================================${NC}\n"
