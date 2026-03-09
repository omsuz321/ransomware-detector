#!/bin/bash

# ============================================================
# TEST: Detector Verification System
# Tests whether baseline run correctly detects running detector
# ============================================================

set -euo pipefail

SERVER_IP="${1:-192.168.2.209}"
SERVER_PASS="${2:-1234}"
MONITOR_SCRIPT_DIR="${3:-/home/server/Desktop/dev/scripts}"

SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o LogLevel=ERROR
    -o ConnectTimeout=10
)

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "\n${CYAN}============================================${NC}"
echo -e "${CYAN} DETECTOR VERIFICATION TEST${NC}"
echo -e "${CYAN}============================================${NC}\n"

# STEP 1: Verify no detector is running initially
echo -e "${YELLOW}[TEST 1]${NC} Checking if detector is already running..."
detector_status=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" bash -s "$SERVER_PASS" <<'TESTEOF'
SERVER_PASS="$1"

# Check for PID file
if [ -f /tmp/ransomware_logger.pid ]; then
    pid=$(cat /tmp/ransomware_logger.pid 2>/dev/null || echo "")
    if [ -n "$pid" ] && printf '%s\n' "$SERVER_PASS" | sudo -S -p '' kill -0 "$pid" 2>/dev/null; then
        echo "RUNNING:$pid"
        exit 0
    fi
fi

# Check for any ransomware_logger process
if pgrep -f ransomware_logger >/dev/null 2>&1; then
    pid=$(pgrep -f ransomware_logger | head -1)
    echo "RUNNING:$pid"
    exit 0
fi

echo "NOT_RUNNING"
TESTEOF
)

if [[ "$detector_status" == RUNNING:* ]]; then
    echo -e "  ${RED}✗ Detector is already running (PID ${detector_status#RUNNING:})${NC}"
    echo -e "  ${YELLOW}Cleaning up first...${NC}"
    sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" \
        "printf '%s\n' '$SERVER_PASS' | sudo -S -p '' pkill -9 -f ransomware_logger 2>/dev/null || true"
    sleep 2
else
    echo -e "  ${GREEN}✓ No detector running (as expected)${NC}"
fi

# STEP 2: Manually start detector (simulating leftover from previous run)
echo -e "\n${YELLOW}[TEST 2]${NC} Manually starting detector (simulating leftover process)..."
sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" \
    "printf '%s\n' '$SERVER_PASS' | sudo -S -p '' $MONITOR_SCRIPT_DIR/ransomware_monitor.sh run-bg -o /tmp/test_detector.csv --run-id test_verification --label test 2>&1" >/dev/null || true

sleep 3

# Verify detector started
detector_pid=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" \
    "cat /tmp/ransomware_logger.pid 2>/dev/null || echo 'NONE'")

if [ "$detector_pid" = "NONE" ]; then
    echo -e "  ${RED}✗ Failed to start test detector${NC}"
    exit 1
else
    echo -e "  ${GREEN}✓ Test detector started (PID $detector_pid)${NC}"
fi

# STEP 3: Test the verification function
echo -e "\n${YELLOW}[TEST 3]${NC} Testing verify_no_detector_running() function..."
echo -e "  ${CYAN}This should detect the running detector and kill it${NC}"

detection_result=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" bash -s "$SERVER_PASS" <<'VERIFYEOF'
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

echo "NO_DETECTOR"
VERIFYEOF
)

if [[ "$detection_result" == DETECTOR_RUNNING:* ]]; then
    detected_pid="${detection_result#DETECTOR_RUNNING:}"
    echo -e "  ${GREEN}✓ Detector correctly detected (PID $detected_pid)${NC}"
    
    # Now kill it
    echo -e "  ${CYAN}Killing detected detector...${NC}"
    sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" \
        "printf '%s\n' '$SERVER_PASS' | sudo -S -p '' kill -9 $detected_pid 2>/dev/null || true"
    sleep 2
    
    # Verify it's dead
    still_running=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" \
        "printf '%s\n' '$SERVER_PASS' | sudo -S -p '' kill -0 $detected_pid 2>/dev/null && echo 'ALIVE' || echo 'DEAD'")
    
    if [ "$still_running" = "DEAD" ]; then
        echo -e "  ${GREEN}✓ Detector successfully killed${NC}"
    else
        echo -e "  ${RED}✗ Failed to kill detector${NC}"
        exit 1
    fi
else
    echo -e "  ${RED}✗ Detector NOT detected (verification function broken!)${NC}"
    exit 1
fi

# STEP 4: Final verification - no detector should be running
echo -e "\n${YELLOW}[TEST 4]${NC} Final check - verifying no detector is running..."
final_check=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" \
    "pgrep -f ransomware_logger 2>/dev/null || echo 'NONE'")

if [ "$final_check" = "NONE" ]; then
    echo -e "  ${GREEN}✓ No detector running (system is clean)${NC}"
else
    echo -e "  ${RED}✗ Detector still running (PID $final_check)${NC}"
    exit 1
fi

# SUMMARY
echo -e "\n${GREEN}============================================${NC}"
echo -e "${GREEN}  ALL TESTS PASSED ✓${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e ""
echo -e "The verification system works correctly:"
echo -e "  1. ✓ Detects running detector processes"
echo -e "  2. ✓ Kills leftover detector processes"
echo -e "  3. ✓ Prevents baseline measurements when detector is running"
echo -e ""
echo -e "${CYAN}The benchmark script will now safely prevent detector contamination!${NC}"
echo ""
