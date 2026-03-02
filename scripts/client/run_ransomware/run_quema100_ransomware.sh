#!/bin/bash

# =================================================================
# RANSOMWARE EVALUATION HARNESS (Kugelsicherer Not-Aus)
# =================================================================

INSTALL_DIR="./EchoCrypt"

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
# 2. DER KUGELSICHERE NOT-AUS (Trap)
# -----------------------------------------------------------------
cleanup() {
    # 1. Verhindert, dass die Cleanup-Funktion mehrfach aufgerufen wird
    trap - INT TERM EXIT 
    
    echo -e "\n\n🚨🚨🚨 NOT-AUS WURDE AKTIVIERT 🚨🚨🚨"
    echo "[+] Vernichte alle zugehörigen Prozesse..."
    
    # 2. Server hart beenden
    kill -9 $SERVER_PID 2>/dev/null
    
    # 3. Alle direkten Kind-Prozesse dieses Skripts killen (timeout, bash, find)
    pkill -9 -P $$ 2>/dev/null
    
    # 4. Zur absoluten Sicherheit: Jeden EchoCrypt-Prozess auf dem System abschießen
    pkill -9 -f "python3 test.py" 2>/dev/null
    
    echo "[INFO] Alles gestoppt. Das Terminal gehört wieder dir!"
    exit 130
}

# Diese Zeile fängt Strg+C (INT), Beenden-Signale (TERM) und das normale Skript-Ende (EXIT) ab
trap cleanup INT TERM EXIT

# -----------------------------------------------------------------
# 3. DIE ENDLOSSCHLEIFE
# -----------------------------------------------------------------
echo "[*] Ziel-Share: $TARGET_DIR"
echo "[!] Starte Verschlüsselung... Drücke STRG+C zum Abbrechen!"
echo "----------------------------------------------------------"

cd "$INSTALL_DIR" || exit 1

timeout "${DURATION}s" bash -c "
    while true; do
        echo '[DEBUG] Suche nach Unterordnern...'
        
        find '$TARGET_DIR' -type d 2>/dev/null | while read -r SUBDIR; do
            echo \"[DEBUG] Führe EchoCrypt aus auf: \$SUBDIR\"
            python3 test.py --encrypt --target-dir \"\$SUBDIR\" > /dev/null 2>&1
        done
        
        sleep 1
    done
"

# Das Skript erreicht diesen Punkt nur, wenn das Zeitlimit regulär abläuft
echo "----------------------------------------------------------"
echo "[INFO] Zeitlimit von $DURATION s erreicht."
# Die Cleanup-Funktion wird durch den EXIT-Trap jetzt automatisch ausgelöst!