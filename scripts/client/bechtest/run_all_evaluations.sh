#!/bin/bash

# ============================================================
# AUTOMATED EVALUATION RUNNER
# Führt alle Ransomware-Simulatoren nacheinander aus
# ============================================================

set -euo pipefail

# --- PARAMETER (nur Anzahl Runs) ---
REPEAT_COUNT="${1:-1}"  # Wie viele Male pro Simulator ausführen (default: 1)
CLIENT_MOUNT="${2:-/mnt/nfs}"  # Optionaler Client-Mount; /mnt/nfs/target wird intern auf /mnt/nfs/tmp umgebogen

# --- FESTE DEFAULTS ---
SERVER_IP="192.168.2.209"
DURATION="300"
SERVER_PASS="1234"
RANSOMWARE_SCRIPT_DIR="/home/server/Desktop/dev/scripts"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "\n${BLUE}============================================${NC}"
echo -e "${BLUE} 🚀 Starte alle Evaluations-Läufe${NC}"
echo -e "${BLUE} Wiederholungen pro Simulator: $REPEAT_COUNT${NC}"
echo -e "${BLUE} Client-Mount: $CLIENT_MOUNT${NC}"
echo -e "${BLUE}============================================${NC}\n"

# Array der Simulatoren
simulators=( "jimmy" "quema100")

for simulator in "${simulators[@]}"; do
    echo -e "\n${GREEN}========== Starte: $simulator ($REPEAT_COUNT Mal) ==========${NC}\n"
    
    "$SCRIPT_DIR/run_ransomware_evaluation.sh" \
        "$SERVER_IP" \
        "$CLIENT_MOUNT" \
        "$DURATION" \
        "$SERVER_PASS" \
        "$RANSOMWARE_SCRIPT_DIR" \
        "$simulator" \
        "$REPEAT_COUNT"
    
    echo -e "\n${GREEN}✅ $simulator abgeschlossen${NC}"
    echo "Warte 5 Sekunden vor nächstem Simulator..."
    sleep 5
done

echo -e "\n${GREEN}============================================${NC}"
echo -e "${GREEN} ✅ Alle Evaluationen abgeschlossen!${NC}"
echo -e "${GREEN}============================================${NC}\n"

echo "Ergebnisse in: $SCRIPT_DIR/../results/evaluation_results.csv"
