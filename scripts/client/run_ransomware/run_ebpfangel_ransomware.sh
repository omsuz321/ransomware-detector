#!/bin/bash

# --- 1. PARAMETER ---
TARGET_DIR=${1:-"/mnt/nfs/tmp"}
DURATION=${2:-"10s"}
CLEAN_DURATION=$(echo $DURATION | sed 's/[^0-9]//g')
[ -z "$CLEAN_DURATION" ] || [ "$CLEAN_DURATION" -eq 0 ] && CLEAN_DURATION=10

REAL_USER=${SUDO_USER:-$(whoami)}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

as_user() {
    if [ "$(id -u)" -eq 0 ]; then
        sudo -u "$REAL_USER" "$@"
    else
        "$@"
    fi
}

# Pfade
REPO_URL="https://github.com/TomasPhilippart/ebpfangel.git"
REPO_DIR="$SCRIPT_DIR/ebpfangel"
SIM_DIR="$REPO_DIR/simulator"
VENV_DIR="$REPO_DIR/venv"
CURRENT_DIR="$(pwd)"

echo "--- START (ebpfangel mit Timeout-Check) ---"

# --- 2. SETUP ---
if [ ! -d "$REPO_DIR" ]; then
    as_user git clone "$REPO_URL" "$REPO_DIR" --quiet
fi

sudo chown -R "$REAL_USER":"$REAL_USER" "$REPO_DIR"
cd "$SIM_DIR" || exit

# SSL-Patch (verhindert Absturz bei neueren OpenSSL Versionen)
if ! grep -q "import ssl" simulator.py; then
    sed -i '1i import ssl' simulator.py
    sed -i 's/print(cryptography.hazmat.backends.openssl.backend.openssl_version_text())/print(ssl.OPENSSL_VERSION)/' simulator.py
fi

if [ ! -d "$VENV_DIR" ]; then
    as_user python3 -m venv "$VENV_DIR"
fi

# Venv kann bereits existieren, aber unvollständig sein (z.B. fehlendes pip/pyAesCrypt).
if ! as_user "$VENV_DIR/bin/python3" -m pip --version >/dev/null 2>&1; then
    echo "   [*] pip fehlt im venv, versuche ensurepip ..."
    as_user "$VENV_DIR/bin/python3" -m ensurepip --upgrade >/dev/null 2>&1 || true
fi

if ! as_user "$VENV_DIR/bin/python3" -m pip --version >/dev/null 2>&1; then
    echo "   ❌ Konnte pip im venv nicht bereitstellen."
    echo "      Venv: $VENV_DIR"
    echo "      Bitte manuell prüfen: $VENV_DIR/bin/python3 -m ensurepip --upgrade"
    exit 1
fi

if ! as_user "$VENV_DIR/bin/python3" -c "import pyAesCrypt" >/dev/null 2>&1; then
    echo "   [*] Installiere fehlende Python-Abhängigkeiten (pyAesCrypt)..."
    as_user "$VENV_DIR/bin/python3" -m pip install --upgrade pip >/dev/null 2>&1 || true
    if ! as_user "$VENV_DIR/bin/python3" -m pip install -r requirements.txt pyAesCrypt --quiet; then
        echo "   ❌ Installation der Python-Abhängigkeiten fehlgeschlagen."
        echo "      Prüfe Netzwerk/Python-Setup und führe erneut aus."
        exit 1
    fi
fi

if ! as_user "$VENV_DIR/bin/python3" -c "import pyAesCrypt" >/dev/null 2>&1; then
    echo "   ❌ pyAesCrypt ist weiterhin nicht importierbar."
    echo "      Venv: $VENV_DIR"
    exit 1
fi

# --- 3. START DER MESSUNG ---
START_TIME=$(date +%s)
END_TIME=$((START_TIME + CLEAN_DURATION))
counter=1

echo "=================================================="
echo " 🚀 ebpfangel Simulator (Detail-Check)"
echo "=================================================="
echo "[DEBUG] Target-Verzeichnis: $TARGET_DIR"
echo "[DEBUG] Existiert: $([ -d "$TARGET_DIR" ] && echo "JA" || echo "NEIN")"
if [ -d "$TARGET_DIR" ]; then
    echo "[DEBUG] Anzahl Dateien: $(find "$TARGET_DIR" -type f 2>/dev/null | wc -l)"
    echo "[DEBUG] Anzahl Ordner: $(find "$TARGET_DIR" -type d 2>/dev/null | wc -l)"
    echo "[DEBUG] Erste 5 Einträge:"
    ls -lh "$TARGET_DIR" 2>/dev/null | head -6 | sed 's/^/  /'
fi
echo ""

while [ $(date +%s) -lt $END_TIME ]; do
    REMAINING=$(( END_TIME - $(date +%s) ))
    [ $REMAINING -le 0 ] && break

    echo "[$(date +%T)] Durchgang $counter (Verfügbar: ${REMAINING}s)..."
    
    sync && sudo bash -c 'echo 3 > /proc/sys/vm/drop_caches'
    
    PASSWORD="thesis_test_$(date +%s)"
    
    # Ausführung & Fehler-Capture
    # Wir senden SIGINT (-s 2), was in Python als KeyboardInterrupt erscheint.
    SIM_ERR=$(as_user timeout -k 3s -s SIGINT "${REMAINING}s" "$VENV_DIR/bin/python3" ./simulator.py \
         --dir "$TARGET_DIR" \
         --password "$PASSWORD" 2>&1)
    EXIT_STATUS=$?

    # --- AUSWERTUNG ---
    # ebpfangel meldet bei Erfolg oft selbst die Anzahl verschlüsselter Dateien.
    AES_COUNT=$(ls -1 "$TARGET_DIR"/*.aes 2>/dev/null | wc -l)
    INPUT_COUNT=$(find "$TARGET_DIR" -type f ! -name '*.aes' 2>/dev/null | wc -l)

    if [ $EXIT_STATUS -eq 0 ]; then
        if echo "$SIM_ERR" | grep -q "0 files encrypted"; then
            echo "   ⚠️ KEIN WORKLOAD: Simulator lief, aber 0 Dateien verschlüsselt."
            echo "      -> Eingabedateien im Zielpfad: $INPUT_COUNT"
        elif [ $AES_COUNT -gt 0 ]; then
            echo "   ✅ ERFOLG: Dateien wurden verschlüsselt ($AES_COUNT .aes Dateien)."
        else
            echo "   ⚠️ KEIN ERKENNBARER OUTPUT: Exit-Code 0, aber keine .aes-Dateien gefunden."
            echo "      -> Eingabedateien im Zielpfad: $INPUT_COUNT"
        fi
    elif [ $EXIT_STATUS -eq 124 ] || [ $EXIT_STATUS -eq 130 ]; then
        # 124 = Timeout / 130 = SIGINT (KeyboardInterrupt)
        echo "   🛑 ABBRUCH: Zeitlimit erreicht (Timeout)."
        echo "      -> Verschlüsselte Dateien bis zum Abbruch: $AES_COUNT"
    else
        echo "   ❌ ECHTER FEHLER: Der Simulator ist abgestürzt."
        if [ -n "$SIM_ERR" ]; then
            echo "      Grund (Exit-Code: $EXIT_STATUS):"
            echo "$SIM_ERR" | sed 's/^/      /' | head -n 20
        else
            echo "      Grund: keine Fehlermeldung ausgegeben (Exit-Code: $EXIT_STATUS)"
        fi
    fi

    sleep 1
    ((counter++))
done

cd "$CURRENT_DIR" || exit
echo "🏁 Simulation beendet."
