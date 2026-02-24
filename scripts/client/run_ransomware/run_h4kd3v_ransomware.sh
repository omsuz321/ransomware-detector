#!/bin/bash

# --- 1. PARAMETER & USER-ERKENNUNG ---
TARGET_DIR=${1:-"/mnt/nfs/tmp"}
DURATION=${2:-"10s"}
CLEAN_DURATION=$(echo $DURATION | sed 's/[^0-9]//g')
[ -z "$CLEAN_DURATION" ] || [ "$CLEAN_DURATION" -eq 0 ] && CLEAN_DURATION=10

REAL_USER=${SUDO_USER:-$(whoami)}
REPO_DIR="$(pwd)/Ransomware-Simulation-And-Detection"
PY_FILE="$REPO_DIR/simulation/encryptor.py"
VENV_DIR="$REPO_DIR/venv"

as_user() {
    sudo -u "$REAL_USER" "$@"
}

echo "--- START (h4kd3v mit Fehler-Diagnose) ---"

# --- 2. SETUP ---
if [ ! -d "$REPO_DIR" ]; then
    as_user git clone https://github.com/h4kd3v/Ransomware-Simulation-And-Detection.git "$REPO_DIR" --quiet
fi

chown -R "$REAL_USER":"$REAL_USER" "$REPO_DIR"

if [ ! -d "$VENV_DIR" ]; then
    as_user python3 -m venv "$VENV_DIR"
    as_user "$VENV_DIR/bin/pip" install cryptography --quiet
fi

# Pfad im Python-Skript anpassen (Original-Dateimenge bleibt erhalten)
as_user sed -i "s|directory_to_encrypt = .*|directory_to_encrypt = \"$TARGET_DIR\"|g" "$PY_FILE"

# --- 3. START DER MESSUNG ---
START_TIME_SEC=$(date +%s)
END_TIME_LIMIT=$((START_TIME_SEC + CLEAN_DURATION))
counter=1

echo "=================================================="
echo " 🚀 h4kd3v Simulator (Detail-Check aktiv)"
echo "=================================================="

while [ $(date +%s) -lt $END_TIME_LIMIT ]; do
    REMAINING=$(( END_TIME_LIMIT - $(date +%s) ))
    [ $REMAINING -le 0 ] && break

    echo "[$(date +%T)] Durchgang $counter (Verfügbar: ${REMAINING}s)..."
    
    # Cache leeren (Sudo für Systembefehl)
    sync && sysctl -w vm.drop_caches=3 > /dev/null
    
    # Ausführung & Fehler-Capture
    # stdout wird unterdrückt, stderr (Fehler) wird in SIM_ERR gespeichert
    SIM_ERR=$(cd "$REPO_DIR/simulation" && as_user timeout -k 5s -s SIGINT "${REMAINING}s" "$VENV_DIR/bin/python3" encryptor.py 2>&1 > /dev/null)
    EXIT_STATUS=$?

    # --- AUSWERTUNG DER URSACHE ---
    # Wir zählen die verschlüsselten Dateien für das Feedback
    ENCRYPTED_COUNT=$(ls -1 "$TARGET_DIR"/*.encrypted 2>/dev/null | wc -l)

    if [ $EXIT_STATUS -eq 0 ]; then
        echo "   ✅ ERFOLGREICH: Alle Dateien im Verzeichnis verschlüsselt."
    elif [ $EXIT_STATUS -eq 124 ] || [ $EXIT_STATUS -eq 130 ]; then
        # 124 = Timeout-Befehl / 130 = SIGINT (KeyboardInterrupt)
        echo "   🛑 ABBRUCH: Zeitlimit ($CLEAN_DURATION s) erreicht."
        echo "      -> Verschlüsselte Dateien bis zum Timeout: $ENCRYPTED_COUNT"
        echo "      (Das ist POSITIV für deine Messung, da I/O-Last stattfand!)"
    else
        echo "   ❌ ECHTER FEHLER: Das Skript ist abgestürzt."
        echo "      Grund: $SIM_ERR" | head -n 10
    fi

    sleep 1
    ((counter++))
done

echo "=================================================="
echo "✅ Simulation beendet um: $(date +"%T")"