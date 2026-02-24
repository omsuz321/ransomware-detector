#!/bin/bash

# --- 1. PARAMETER ---
SERVER_IP=$1
CLIENT_MOUNT="/mnt/nfs" # Wo das NFS-Laufwerk auf dem Client liegt
DURATION=$3             # z.B. 20s
SERVER_PASS=$4

# Verzeichnisse auf dem Server
SERVER_BASE_DIR="/srv/nfs/thesis_data"
SERVER_WORK_DIR="$SERVER_BASE_DIR/tmp"
SERVER_BACKUP_DIR="/srv/nfs/clean_backup"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX_SCRIPT="$SCRIPT_DIR/open_access_for_client.sh"
RANSOM_DIR="$SCRIPT_DIR/../run_ransomware"

# --- 2. ARGUMENT-CHECK ---
if [ -z "$SERVER_IP" ] || [ -z "$SERVER_PASS" ] || [ -z "$DURATION" ]; then
    echo "❌ Fehler: IP, Passwort oder Dauer fehlt."
    exit 1
fi

# --- 3. SERVER-VORBEREITUNG ---
restore_data_on_server() {
    echo -e "\n   [♻️] Bereite Server-Workdir vor ($SERVER_IP)..."

    sshpass -p "$SERVER_PASS" ssh -o StrictHostKeyChecking=no "server@$SERVER_IP" "
        if [ ! -d '$SERVER_WORK_DIR' ]; then
            echo '$SERVER_PASS' | sudo -S mkdir -p '$SERVER_WORK_DIR'
        else
            echo '$SERVER_PASS' | sudo -S rm -rf '$SERVER_WORK_DIR'/*
        fi
        echo '$SERVER_PASS' | sudo -S cp -r '$SERVER_BACKUP_DIR'/. '$SERVER_WORK_DIR'/
    "

    # Rechte-Fix auf dem Server ausführen
    sshpass -p "$SERVER_PASS" ssh -o StrictHostKeyChecking=no "server@$SERVER_IP" 'bash -s' -- "$SERVER_WORK_DIR" "$SERVER_PASS" < "$FIX_SCRIPT"

    # Client-Cache leeren
    sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
}

echo "=================================================="
echo " 🚀 Master Suite: Automatisierter Testlauf"
echo "=================================================="

SIMS=("run_ebpfangel_ransomware.sh" "run_h4kd3v_ransomware.sh" "run_serdarumut_ransomware.sh" "run_nextron_systems_ransomware.sh")

for sim in "${SIMS[@]}"; do
    if [ -f "$RANSOM_DIR/$sim" ]; then
        restore_data_on_server
        
        echo -e "\n[🔥] Starte Simulator: $sim"
        # Wir übergeben den /tmp Pfad des NFS-Mounts
        bash "$RANSOM_DIR/$sim" "$CLIENT_MOUNT/tmp" "$DURATION"
        
        sleep 5
    fi
done