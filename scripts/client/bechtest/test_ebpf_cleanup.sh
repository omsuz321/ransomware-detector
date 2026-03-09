#!/bin/bash
# ==========================================
# Test: Verifiziert ob ebpf.sh unload wirklich eBPF entlädt
# ==========================================

set -euo pipefail

SERVER_IP="${1:-192.168.2.209}"
SERVER_PASS="${2:-1234}"
MONITOR_SCRIPT_DIR="${3:-/home/server/Desktop/dev/scripts}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_step() { echo -e "\n${BLUE}>>> $1${NC}"; }
log_ok()   { echo -e "${GREEN}✓${NC} $1"; }
log_fail() { echo -e "${RED}✗${NC} $1"; }
log_info() { echo -e "${YELLOW}ℹ${NC} $1"; }

SSH_OPTS=(-o StrictHostKeyChecking=no -o LogLevel=ERROR)

log_step "STEP 1: Detector starten (lädt eBPF in Kernel)"
sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" \
    "cd $MONITOR_SCRIPT_DIR && printf '%s\n' '$SERVER_PASS' | sudo -S -p '' bash ./ransomware_monitor.sh run-bg -o /tmp/test_cleanup.csv --run-id test --label test"

sleep 3

log_step "STEP 2: eBPF-Programme im Kernel prüfen (SOLLTE GEFUNDEN WERDEN)"
ebpf_before=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" \
    "printf '%s\n' '$SERVER_PASS' | sudo -S -p '' bpftool prog show 2>/dev/null | grep -c 'vfs_write' 2>/dev/null || echo '0'")

if [ "$ebpf_before" -gt 0 ]; then
    log_ok "eBPF-Programme AKTIV im Kernel: $ebpf_before Programme"
else
    log_fail "eBPF-Programme NICHT gefunden (Detector lief nicht?)"
    exit 1
fi

log_step "STEP 3: Detector stoppen mit ransomware_monitor.sh stop"
sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" \
    "cd $MONITOR_SCRIPT_DIR && printf '%s\n' '$SERVER_PASS' | sudo -S -p '' bash ./ransomware_monitor.sh stop" 2>&1 | tee /tmp/test_stop_output.log

sleep 2

log_step "STEP 4: eBPF-Programme im Kernel prüfen (SOLLTE LEER SEIN)"
ebpf_after=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" \
    "printf '%s\n' '$SERVER_PASS' | sudo -S -p '' bpftool prog show 2>/dev/null | grep -c 'vfs_write' 2>/dev/null || echo '0'")

echo ""
echo "=========================================="
echo "      TEST ERGEBNIS"
echo "=========================================="
echo "eBPF Programme VORHER:  $ebpf_before"
echo "eBPF Programme NACHHER: $ebpf_after"
echo ""

if [ "$ebpf_after" -eq 0 ]; then
    log_ok "✅ SUCCESS: eBPF-Programme wurden ENTFERNT!"
    echo ""
    echo "Das Script funktioniert korrekt. eBPF wurde aus dem Kernel entladen."
    exit 0
else
    log_fail "❌ FAILURE: eBPF-Programme sind NOCH IM KERNEL!"
    echo ""
    echo "Das Script hat einen BUG:"
    echo "  - Userspace-Prozess gestoppt: ✓"
    echo "  - eBPF aus Kernel entfernt:   ✗"
    echo ""
    echo "Details der noch aktiven Programme:"
    sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" \
        "printf '%s\n' '$SERVER_PASS' | sudo -S -p '' bpftool prog show | grep -A 5 'vfs_write'" || true
    echo ""
    echo "Stop-Befehl Output (Warnungen?):"
    cat /tmp/test_stop_output.log
    exit 1
fi
