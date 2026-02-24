#!/bin/bash

# --- 1. PARAMETER ---
TARGET_DIR=${1:-"/mnt/nfs/tmp"}
DURATION=${2:-"10s"}
CLEAN_DURATION=$(echo $DURATION | sed 's/[^0-9]//g')
[ -z "$CLEAN_DURATION" ] || [ "$CLEAN_DURATION" -eq 0 ] && CLEAN_DURATION=10

REAL_USER="cleint"

# Pfade
REPO_URL="https://github.com/TomasPhilippart/ebpfangel.git"
REPO_DIR="$(pwd)/ebpfangel"
SIM_DIR="$REPO_DIR/simulator"
VENV_DIR="$REPO_DIR/venv"
CURRENT_DIR="$(pwd)"

echo "--- START (ebpfangel mit Timeout-Check) ---"

# --- 2. SETUP ---
if [ ! -d "$REPO_DIR" ]; then
    git clone "$REPO_URL" "$REPO_DIR" --quiet
fi

sudo chown -R $REAL_USER:$REAL_USER "$REPO_DIR"
cd "$SIM_DIR" || exit

# SSL-Patch (verhindert Absturz bei neueren OpenSSL Versionen)
if ! grep -q "import ssl" simulator.py; then
    sed -i '1i import ssl' simulator.py
    sed -i 's/print(cryptography.hazmat.backends.openssl.backend.openssl_version_text())/print(ssl.OPENSSL_VERSION)/' simulator.py
fi

if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/python3" -m pip install -r requirements.txt --quiet
fi

# --- 3. START DER MESSUNG ---
START_TIME=$(date +%s)
END_TIME=$((START_TIME + CLEAN_DURATION))
counter=1

echo "=================================================="
echo " 🚀 ebpfangel Simulator (Detail-Check)"
echo "=================================================="

while [ $(date +%s) -lt $END_TIME ]; do
    REMAINING=$(( END_TIME - $(date +%s) ))
    [ $REMAINING -le 0 ] && break

    echo "[$(date +%T)] Durchgang $counter (Verfügbar: ${REMAINING}s)..."
    
    sync && sudo bash -c 'echo 3 > /proc/sys/vm/drop_caches'
    
    PASSWORD="thesis_test_$(date +%s)"
    
    # Ausführung & Fehler-Capture
    # Wir senden SIGINT (-s 2), was in Python als KeyboardInterrupt erscheint.
    SIM_ERR=$(sudo -u $REAL_USER timeout -k 3s -s SIGINT "${REMAINING}s" "$VENV_DIR/bin/python3" ./simulator.py \
         --dir "$TARGET_DIR" \
         --password "$PASSWORD" 2>&1 > /dev/null)
    EXIT_STATUS=$?

    # --- AUSWERTUNG ---
    # 1. Prüfen, ob überhaupt Dateien erzeugt wurden
    AES_COUNT=$(ls -1 "$TARGET_DIR"/*.aes 2>/dev/null | wc -l)

    if [ $AES_COUNT -gt 0 ] && [ $EXIT_STATUS -eq 0 ]; then
        echo "   ✅ ERFOLG: Alle Dateien wurden verschlüsselt ($AES_COUNT Dateien)."
    elif [ $EXIT_STATUS -eq 124 ] || [ $EXIT_STATUS -eq 130 ]; then
        # 124 = Timeout / 130 = SIGINT (KeyboardInterrupt)
        echo "   🛑 ABBRUCH: Zeitlimit erreicht (Timeout)."
        echo "      -> Verschlüsselte Dateien bis zum Abbruch: $AES_COUNT"
    else
        echo "   ❌ ECHTER FEHLER: Der Simulator ist abgestürzt."
        echo "      Grund: $SIM_ERR" | head -n 10
    fi

    sleep 1
    ((counter++))
done

cd "$CURRENT_DIR" || exit
echo "🏁 Simulation beendet."