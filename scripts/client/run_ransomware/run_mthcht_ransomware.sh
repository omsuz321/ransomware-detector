#!/bin/bash
set -u

run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Konfiguration
GIT_REPO="https://github.com/mthcht/Purpleteam.git"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR/Purpleteam"
# Der Pfad zum Skript innerhalb des geklonten Repositories
TARGET_SCRIPT="$REPO_DIR/Simulation/Linux/ransomware/python_ransomware.py"

DEFAULT_TEST_DIR="$HOME/ransomware_simulation_dir"
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    SUDO_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    if [ -n "$SUDO_HOME" ]; then
        DEFAULT_TEST_DIR="$SUDO_HOME/ransomware_simulation_dir"
    fi
fi

# Optional: Zielverzeichnis als 1. Parameter übergeben
TEST_DIR="${1:-$DEFAULT_TEST_DIR}"
# Optional: Laufzeit in Sekunden als 2. Parameter (0 = bis Ctrl+C)
RUN_DURATION_SECONDS="${2:-0}"
# Pause zwischen zwei Durchläufen
ROUND_INTERVAL_SECONDS="${3:-3}"

echo "--- Ransomware-Simulations-Manager (Git Version) ---"

# 1. Repository klonen oder updaten
if [ ! -d "$REPO_DIR" ]; then
    echo "[i] Repository nicht gefunden. Klone von $GIT_REPO..."
    git clone "$GIT_REPO" "$REPO_DIR"
    
    if [ $? -ne 0 ]; then
        echo "[!] Fehler beim Klonen. Bitte Git-Installation und Internetverbindung prüfen."
        exit 1
    fi
else
    echo "[+] Repository ist bereits lokal vorhanden. Ziehe neueste Updates..."
    # Wechselt ins Verzeichnis, zieht Updates und geht wieder zurück
    cd "$REPO_DIR" && git pull && cd "$SCRIPT_DIR"
fi

# Prüfen, ob das Skript im geklonten Repo existiert, und ausführbar machen
if [ -f "$TARGET_SCRIPT" ]; then
    :
else
    echo "[!] Das Skript $TARGET_SCRIPT wurde im Repository nicht gefunden. Pfad prüfen!"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "[!] python3 wurde nicht gefunden. Bitte python3 installieren."
    exit 1
fi

if [ -z "$TEST_DIR" ] || [ "$TEST_DIR" = "/" ]; then
    echo "[!] Ungültiges Test-Verzeichnis: '$TEST_DIR'"
    exit 1
fi

if ! [[ "$RUN_DURATION_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "[!] Ungültige Laufzeit: '$RUN_DURATION_SECONDS' (erwartet: Sekunden als Zahl)"
    exit 1
fi

if ! [[ "$ROUND_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || [ "$ROUND_INTERVAL_SECONDS" -lt 1 ]; then
    echo "[!] Ungültiges Intervall: '$ROUND_INTERVAL_SECONDS' (erwartet: >= 1)"
    exit 1
fi

# 2. Test-Umgebung vorbereiten
run_as_root mkdir -p "$TEST_DIR"
echo "Geheime Daten" | run_as_root tee "$TEST_DIR/test_01.txt" >/dev/null
echo "System-Konfiguration" | run_as_root tee "$TEST_DIR/test_02.cfg" >/dev/null
echo "[+] Test-Verzeichnis vorbereitet: $TEST_DIR"

# 3. Sicherheits-Check
echo "--------------------------------------------------------"
echo "ACHTUNG: Das Skript wird jetzt wiederholt Dateien in $TEST_DIR verschlüsseln."
if [ "$RUN_DURATION_SECONDS" -eq 0 ]; then
    echo "Laufmodus: Endlos bis manuell mit Ctrl+C beendet."
else
    echo "Laufmodus: $RUN_DURATION_SECONDS Sekunden."
fi
read -p "Möchtest du die Simulation jetzt starten? (y/n): " confirm

if [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]]; then
    echo "[!] Starte Simulation..."

    start_epoch="$(date +%s)"
    run_count=0
    if [ "$RUN_DURATION_SECONDS" -eq 0 ]; then
        STOP_REQUESTED=0
        trap 'STOP_REQUESTED=1' INT TERM

        while [ "$STOP_REQUESTED" -eq 0 ]; do
            run_count=$((run_count + 1))
            echo "[i] Durchlauf #$run_count ..."

            if ! run_as_root python3 "$TARGET_SCRIPT" "$TEST_DIR"; then
                status=$?
                if [ "$STOP_REQUESTED" -eq 1 ] || [ "$status" -eq 130 ]; then
                    break
                fi
                trap - INT TERM
                echo "--------------------------------------------------------"
                echo "[!] Simulation fehlgeschlagen (Exit-Code: $status) in Durchlauf #$run_count."
                exit "$status"
            fi

            sleep "$ROUND_INTERVAL_SECONDS" || true
        done

        trap - INT TERM
    else
        if ! command -v timeout >/dev/null 2>&1; then
            echo "[!] 'timeout' wurde nicht gefunden. Bitte coreutils installieren."
            exit 1
        fi

        counter_file="$(mktemp)"
        loop_code='
target_script="$1"
test_dir="$2"
interval="$3"
counter_file="$4"
run_count=0
while true; do
    run_count=$((run_count + 1))
    echo "$run_count" > "$counter_file"
    echo "[i] Durchlauf #$run_count ..."
    python3 "$target_script" "$test_dir" || exit $?
    sleep "$interval"
done
'

        timeout_status=0
        run_as_root timeout --foreground --signal=INT --kill-after=5s "${RUN_DURATION_SECONDS}s" \
            bash -c "$loop_code" _ "$TARGET_SCRIPT" "$TEST_DIR" "$ROUND_INTERVAL_SECONDS" "$counter_file" || timeout_status=$?

        if [ -f "$counter_file" ]; then
            run_count="$(cat "$counter_file" 2>/dev/null || echo 0)"
        fi
        rm -f "$counter_file"

        if [ "$timeout_status" -ne 0 ] && [ "$timeout_status" -ne 124 ] && [ "$timeout_status" -ne 130 ]; then
            echo "--------------------------------------------------------"
            echo "[!] Simulation fehlgeschlagen (Exit-Code: $timeout_status)."
            exit "$timeout_status"
        fi
    fi

    total_runtime=$(( $(date +%s) - start_epoch ))

    echo "--------------------------------------------------------"
    echo "[OK] Simulation abgeschlossen."
    echo "Durchläufe: $run_count | Laufzeit: ${total_runtime}s"
    echo "Die Dateien in $TEST_DIR sollten nun verändert/verschlüsselt sein."
    ls -l "$TEST_DIR"
else
    echo "[x] Abbruch durch Benutzer."
fi
