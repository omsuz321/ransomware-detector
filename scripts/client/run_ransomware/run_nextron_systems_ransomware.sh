#!/bin/bash

# --- 1. PARAMETER ---
REAL_USER=${SUDO_USER:-$(whoami)}
BASE_DIR="$(eval echo ~$REAL_USER)/Desktop/nextron_sim_build"
TARGET_DIR=${1:-"/mnt/nfs/tmp"}
DURATION=${2:-"60s"}
CLEAN_DURATION=$(echo $DURATION | sed 's/[^0-9]//g')

as_user() { sudo -u "$REAL_USER" "$@"; }

# --- 2. SETUP & MOUNT-POINT FIX ---
if [ ! -d "$BASE_DIR" ]; then
    as_user git clone https://github.com/NextronSystems/ransomware-simulator.git "$BASE_DIR" --quiet
fi
chown -R "$REAL_USER":"$REAL_USER" "$BASE_DIR"
cd "$BASE_DIR" || exit

# WICHTIG: Wir entfernen den os.RemoveAll-Befehl, damit der NFS-Mountpoint nicht gelöscht wird.
# Wir rühren die 10.000 Dokumente im Code NICHT an.
echo "[*] Deaktiviere os.RemoveAll (Mount-Point Fix)..."
for f in $(grep -rl "os.RemoveAll" .); do
    as_user sed -i 's/os.RemoveAll(c.TargetDir)/\/\/ os.RemoveAll(c.TargetDir)/g' "$f"
    as_user sed -i 's/os.RemoveAll(targetDir)/\/\/ os.RemoveAll(targetDir)/g' "$f"
done

# Sauberer Build
as_user go build -buildvcs=false -o ransomware-simulator ./cmd/...

# --- 3. SIMULATION ---
echo "=================================================="
echo " 🚀 Nextron Simulator (Original Workload)"
echo "=================================================="

START_TIME=$(date +%s)
END_TIME=$((START_TIME + CLEAN_DURATION))
counter=1

while [ $(date +%s) -lt $END_TIME ]; do
    REMAINING=$(( END_TIME - $(date +%s) ))
    [ $REMAINING -le 0 ] && break

    echo "[$(date +%T)] Durchgang $counter (Verfügbare Zeit: ${REMAINING}s)..."
    sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    
    # Der Simulator läuft mit der dynamisch berechneten Restzeit.
    SIM_OUT=$(as_user timeout -k 5s "${REMAINING}s" ./ransomware-simulator run \
                               --dir "$TARGET_DIR" \
                               --disable-macro-simulation \
                               --disable-shadow-copy-deletion \
                               --note-location "$TARGET_DIR/ransom_note_$counter.txt" 2>&1)
    EXIT_STATUS=$?

    # --- AUSWERTUNG DER URSACHE ---
    if [ -f "$TARGET_DIR/ransom_note_$counter.txt" ]; then
        echo "   ✅ VOLLSTÄNDIG: Alle Dateien und Ransom-Note erstellt."
    elif [ $EXIT_STATUS -eq 124 ]; then
        # Exit Status 124 bedeutet bei Linux immer TIMEOUT.
        echo "   🛑 ABBRUCH: Zeitlimit ($DURATION) erreicht."
        echo "      Der Simulator hat gearbeitet, wurde aber vom Timer gestoppt."
    else
        # Jeder andere Code ist ein echter Bug oder ein Rechte-Problem.
        echo "   ❌ FEHLER (Programm-Bug oder Systemfehler):"
        echo "      $SIM_OUT" | head -n 10
    fi

    sleep 2
    ((counter++))
done