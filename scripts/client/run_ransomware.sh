#!/bin/bash

# --- KONFIGURATION ---
DURATION=${1:-60}  # Dauer in Sekunden (Standard: 60)

# Wir ermitteln den echten Nutzer, der sudo ausgeführt hat
REAL_USER=${SUDO_USER:-$(whoami)}
HOME_DIR=$(getent passwd "$REAL_USER" | cut -d: -f6)

# Pfade
TARGET_DIR="$HOME_DIR/Desktop/ebpfangel/simulator"
VENV_DIR="$TARGET_DIR/venv_auto"
VENV_PYTHON="$VENV_DIR/bin/python3"
NFS_PATH="/mnt/nfs"
TEST_DATA="$NFS_PATH/test"

# --- 1. SICHERHEITS-CHECK ---
if [ "$EUID" -ne 0 ]; then
  echo "❌ FEHLER: Bitte starte das Skript mit sudo!"
  echo "   Beispiel: sudo ./run_complete.sh 120"
  exit 1
fi

echo "================================================"
echo "   SETUP & START (User: $REAL_USER)"
echo "================================================"

# --- 2. INSTALLATIONEN (Root) ---

# A) vmtouch (Optional, nur noch für Diagnose)
if ! command -v vmtouch &> /dev/null; then
    echo "🔧 vmtouch wird installiert (für Diagnose)..."
    apt-get update -qq
    apt-get install -y -qq vmtouch
else
    echo "✅ vmtouch ist bereit."
fi

# B) Python Venv Module installieren
if ! dpkg -s python3-venv >/dev/null 2>&1; then
    echo "🔧 Installiere python3-venv..."
    apt-get install -y -qq python3-venv python3-full
else
    echo "✅ Python-Umgebung ist bereit."
fi

# --- 3. PYTHON UMGEBUNG (Als User) ---

# Verzeichnis prüfen
if [ ! -d "$TARGET_DIR" ]; then
    echo "❌ FEHLER: Verzeichnis $TARGET_DIR nicht gefunden!"
    exit 1
fi
cd "$TARGET_DIR" || exit 1

# Virtuelle Umgebung erstellen (als normaler User!)
if [ ! -d "$VENV_DIR" ]; then
    echo "🔧 Erstelle virtuelle Python-Umgebung..."
    sudo -u "$REAL_USER" python3 -m venv "$VENV_DIR"
fi

# Abhängigkeit installieren (als normaler User in die Venv!)
echo "🔧 Prüfe pyAesCrypt..."
sudo -u "$REAL_USER" "$VENV_DIR/bin/pip" install --quiet pyAesCrypt

# --- 4. START DER TEST-SCHLEIFE ---

START_TIME=$(date +%s)
END_TIME=$((START_TIME + DURATION))

echo "================================================"
echo "🚀 TEST GESTARTET ($DURATION Sekunden)"
echo "   Ziel: $TEST_DATA"
echo "================================================"

while [ $(date +%s) -lt $END_TIME ]; do
    
    # SCHRITT A: Cache leeren (Global Drop - Keine NFS Calls!)
    # -------------------------------------------------------
    echo "[$(date +%T)] 🧹 Cache leeren (Global Drop)..."
    
    # 1. Daten sicher auf die Platte schreiben
    sync
    
    # 2. Cache radikal löschen (RAM leeren)
    # Da das Skript schon als root läuft, können wir direkt schreiben
    sh -c 'echo 3 > /proc/sys/vm/drop_caches'

    # SCHRITT B: Simulator starten (Muss REAL_USER sein)
    # -------------------------------------------------------
    echo "[$(date +%T)] 🔒 Simulator läuft..."
    
    # Wir führen Python als der normale User aus, damit NFS Schreibrechte hat
    sudo -u "$REAL_USER" "$VENV_PYTHON" simulator.py --dir "$TEST_DATA" --password xu18d7wfe2edt

    # Kurze Pause
    sleep 1
done

echo "================================================"
echo "✅ FERTIG. Zeit abgelaufen."
echo "================================================"