#!/bin/bash

# --- 1. PARAMETER ---
SERVER_IP=$1
CLIENT_MOUNT=${2:-"/mnt/nfs"} # Wo das NFS-Laufwerk auf dem Client liegt
DURATION=$3             # z.B. 20s
SERVER_PASS=$4
SERVER_MONITOR_SCRIPT_DIR="/home/server/Desktop/dev/scripts"
SERVER_MONITOR_LOG_DIR="/home/server/Desktop/monitor_logs"
SERVER_MONITOR_PID_FILE="/tmp/fileops_logger.pid"
ENABLE_REMOTE_MONITOR=1
MONITOR_ENTROPY_FLAG="--no-entropy"
MONITOR_BPF_LOG_FLAG="--no-bpf-log"
MONITOR_FLAGS=""
SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o LogLevel=ERROR
    -o ConnectTimeout=10
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=2
)

shift 4

# Optional: alte Positionsargumente für Monitor-Verzeichnisse weiterhin erlauben
if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
    SERVER_MONITOR_SCRIPT_DIR="$1"
    shift
fi
if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
    SERVER_MONITOR_LOG_DIR="$1"
    shift
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --remote-monitor)
            ENABLE_REMOTE_MONITOR=1
            ;;
        --no-remote-monitor)
            ENABLE_REMOTE_MONITOR=0
            ;;
        --entropy|--no-entropy)
            MONITOR_ENTROPY_FLAG="$1"
            ;;
        --bpf-log|--no-bpf-log)
            MONITOR_BPF_LOG_FLAG="$1"
            ;;
        *)
            echo "❌ Fehler: Ungültige Option '$1'"
            echo "Erlaubt: --remote-monitor | --no-remote-monitor | --entropy | --no-entropy | --bpf-log | --no-bpf-log"
            exit 1
            ;;
    esac
    shift
done

MONITOR_FLAGS="$MONITOR_ENTROPY_FLAG $MONITOR_BPF_LOG_FLAG"

# Verzeichnisse auf dem Server
SERVER_BASE_DIR="/srv/nfs/thesis_data"
SERVER_SOURCE_DIR="$SERVER_BASE_DIR/$(basename "$CLIENT_MOUNT")"
# Der Workdir ist bewusst ein Unterordner der Quelle:
#   SOURCE -> SOURCE/tmp
# So ist der Zielpfad für die Simulatoren über NFS konsistent.
SERVER_WORK_DIR="$SERVER_SOURCE_DIR/tmp"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX_SCRIPT="$SCRIPT_DIR/open_access_for_client.sh"
RANSOM_DIR="$SCRIPT_DIR/../run_ransomware"
CURRENT_MONITOR_PID=""
CURRENT_MONITOR_CSV=""
CURRENT_MONITOR_MODE=""
LAST_SERVER_FILE_COUNT=0
SKIP_NEXTRON=0
SERVER_TMP_MARKER=""
RESOLVED_CLIENT_TMP_PATH=""

# --- 2. ARGUMENT-CHECK ---
if [ -z "$SERVER_IP" ] || [ -z "$SERVER_PASS" ] || [ -z "$DURATION" ]; then
    echo "❌ Fehler: IP, Passwort oder Dauer fehlt."
    echo "Usage: $0 SERVER_IP CLIENT_MOUNT DURATION SERVER_PASS [SERVER_MONITOR_SCRIPT_DIR] [SERVER_MONITOR_LOG_DIR] [--remote-monitor|--no-remote-monitor] [--entropy|--no-entropy] [--bpf-log|--no-bpf-log]"
    exit 1
fi

check_local_runtime_prereqs() {
    local hard_fail=0

    if ! command -v python3 >/dev/null 2>&1; then
        echo "❌ python3 fehlt auf dem Client."
        hard_fail=1
    fi

    if ! command -v sshpass >/dev/null 2>&1; then
        echo "❌ sshpass fehlt auf dem Client."
        hard_fail=1
    fi

    if [ "$hard_fail" -eq 1 ]; then
        echo "Installiere fehlende Pakete, z.B.:"
        echo "  sudo apt update && sudo apt install -y python3 python3-venv python3-pip sshpass"
        exit 1
    fi

    # Harte Prüfung: funktioniert venv + pip wirklich?
    local venv_check_dir
    venv_check_dir="$(mktemp -d /tmp/run_test_venv_check.XXXXXX)"
    if ! python3 -m venv "$venv_check_dir" >/dev/null 2>&1; then
        rm -rf "$venv_check_dir" >/dev/null 2>&1 || true
        echo "❌ python3-venv/ensurepip ist nicht funktionsfähig."
        echo "   Bitte installieren: sudo apt install -y python3-venv python3-pip"
        exit 1
    fi
    if ! "$venv_check_dir/bin/python3" -m pip --version >/dev/null 2>&1; then
        rm -rf "$venv_check_dir" >/dev/null 2>&1 || true
        echo "❌ pip im erstellten venv nicht verfügbar."
        echo "   Bitte installieren: sudo apt install -y python3-venv python3-pip"
        exit 1
    fi
    rm -rf "$venv_check_dir" >/dev/null 2>&1 || true

    if ! command -v go >/dev/null 2>&1; then
        SKIP_NEXTRON=1
        echo "⚠️  go fehlt auf dem Client. run_nextron_systems_ransomware.sh wird übersprungen."
        echo "   Installieren mit: sudo apt install -y golang-go"
    fi
}

# --- 3. SERVER-VORBEREITUNG ---
restore_data_on_server() {
    echo -e "\n   [♻️] Bereite Server-Workdir vor ($SERVER_IP)..."
    SERVER_TMP_MARKER=".run_test_tmp_marker_$(date +%s)_$RANDOM"
    echo "   [📁] Restore-Quelle: $SERVER_SOURCE_DIR -> $SERVER_WORK_DIR"

    if ! sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" 'bash -s' -- \
        "$SERVER_PASS" \
        "$SERVER_SOURCE_DIR" \
        "$SERVER_WORK_DIR" \
        "$SERVER_BASE_DIR" \
        "$SERVER_TMP_MARKER" <<'EOF'
set -euo pipefail
SERVER_PASS="$1"
SOURCE_DIR="$2"
WORK_DIR="$3"
BASE_DIR="$4"
MARKER="$5"

if [ ! -d "$SOURCE_DIR" ]; then
    echo "ERROR: Quellordner fehlt: $SOURCE_DIR" >&2
    exit 1
fi

if [ "$SOURCE_DIR" = "$WORK_DIR" ]; then
    echo "ERROR: Quelle und Ziel (tmp) dürfen nicht identisch sein: $SOURCE_DIR" >&2
    exit 1
fi

printf '%s\n' "$SERVER_PASS" | sudo -S -p '' mkdir -p "$BASE_DIR" "$WORK_DIR"

# Robustes Leeren: mehrere Versuche gegen temporäre NFS-Race-Zustände.
for i in 1 2 3; do
    printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bash -c '
set -e
WORK_DIR="$1"
mkdir -p "$WORK_DIR"
find "$WORK_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
' _ "$WORK_DIR" && break
    sleep 1
done

if [ -n "$(printf '%s\n' "$SERVER_PASS" | sudo -S -p '' ls -A "$WORK_DIR" 2>/dev/null || true)" ]; then
    echo "ERROR: Konnte tmp nicht vollständig leeren: $WORK_DIR" >&2
    exit 1
fi

# Kopiere Quelle nach tmp.
# Falls WORK_DIR innerhalb SOURCE_DIR liegt, kopieren wir nur Top-Level-Einträge
# und schließen den tmp-Ordner aus, um Rekursion (tmp -> tmp/tmp/...) zu vermeiden.
if [[ "$WORK_DIR" == "$SOURCE_DIR/"* ]]; then
    WORK_BASENAME="$(basename "$WORK_DIR")"
    printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bash -c '
set -e
SOURCE_DIR="$1"
WORK_DIR="$2"
WORK_BASENAME="$3"
find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 ! -name "$WORK_BASENAME" -exec cp -a -t "$WORK_DIR" -- {} +
' _ "$SOURCE_DIR" "$WORK_DIR" "$WORK_BASENAME"
else
    printf '%s\n' "$SERVER_PASS" | sudo -S -p '' cp -a "$SOURCE_DIR"/. "$WORK_DIR"/
fi

# Warteprüfung: enthält tmp nach dem Kopieren Nutzdaten?
if [ -z "$(printf '%s\n' "$SERVER_PASS" | sudo -S -p '' ls -A "$WORK_DIR" 2>/dev/null || true)" ]; then
    echo "ERROR: tmp ist nach dem Kopieren leer: $WORK_DIR" >&2
    exit 1
fi

printf '%s\n' "$SERVER_PASS" | sudo -S -p '' touch "$WORK_DIR/$MARKER"
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' sync
EOF
    then
        echo "   [❌] Restore auf Server fehlgeschlagen (Quelle -> tmp)."
        return 1
    fi

    # Rechte-Fix auf dem Server ausführen
    if ! sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" 'bash -s' -- "$SERVER_WORK_DIR" "$SERVER_PASS" < "$FIX_SCRIPT"; then
        echo "   [❌] Rechte-Fix auf Server fehlgeschlagen."
        return 1
    fi

    # Sichtbarkeit: Wieviel Workload liegt nach Restore wirklich im Workdir?
    local file_count
    file_count=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" "find '$SERVER_WORK_DIR' -type f 2>/dev/null | wc -l" | tr -d '[:space:]')
    if [[ "$file_count" =~ ^[0-9]+$ ]]; then
        LAST_SERVER_FILE_COUNT="$file_count"
        echo "   [📦] Dateien im Server-Workdir nach Restore: $file_count"
        if [ "$file_count" -eq 0 ]; then
            echo "   [⚠️] Workdir ist leer. Einzelne Simulatoren (z.B. ebpfangel) verschlüsseln dann 0 Dateien."
        fi
    else
        LAST_SERVER_FILE_COUNT=0
    fi

    # Client-Cache leeren
    sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    return 0
}

clear_server_tmp_dir() {
    sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" 'bash -s' -- \
        "$SERVER_PASS" \
        "$SERVER_WORK_DIR" <<'EOF'
set -euo pipefail
SERVER_PASS="$1"
WORK_DIR="$2"
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' mkdir -p "$WORK_DIR"
for i in 1 2 3; do
    printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bash -c '
set -e
WORK_DIR="$1"
find "$WORK_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
' _ "$WORK_DIR" && break
    sleep 1
done
EOF
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

count_files_local() {
    local dir="$1"
    if [ -d "$dir" ]; then
        find "$dir" -type f 2>/dev/null | wc -l | tr -d '[:space:]'
    else
        echo "0"
    fi
}

ensure_client_nfs_visibility() {
    local with_tmp="$CLIENT_MOUNT/tmp"
    local nested_tmp="$CLIENT_MOUNT/$(basename "$SERVER_SOURCE_DIR")/tmp"
    local sibling_tmp
    sibling_tmp="$(dirname "$CLIENT_MOUNT")/tmp"
    local candidate_paths=("$with_tmp" "$nested_tmp" "$sibling_tmp")
    local marker_found_at=""
    local cnt_tmp
    local cnt_nested
    local cnt_sibling
    local needs_remount=0

    cnt_tmp="$(count_files_local "$with_tmp")"
    cnt_nested="$(count_files_local "$nested_tmp")"
    cnt_sibling="$(count_files_local "$sibling_tmp")"
    echo "   [📡] Client-Sicht: $with_tmp=$cnt_tmp, $nested_tmp=$cnt_nested, $sibling_tmp=$cnt_sibling"

    for p in "${candidate_paths[@]}"; do
        if [ -f "$p/$SERVER_TMP_MARKER" ]; then
            marker_found_at="$p"
            break
        fi
    done

    # Strikt: wir arbeiten nur mit .../tmp.
    if [ -z "$marker_found_at" ]; then
        needs_remount=1
        echo "   [⚠️] tmp-Marker auf Client nicht sichtbar. Versuche NFS-Remount ..."
    fi

    if [ "$needs_remount" -eq 1 ]; then
        if mountpoint -q "$CLIENT_MOUNT"; then
            as_root umount "$CLIENT_MOUNT" >/dev/null 2>&1 || as_root umount -l "$CLIENT_MOUNT" >/dev/null 2>&1 || true
        fi
        as_root mkdir -p "$CLIENT_MOUNT"
        as_root mount "$CLIENT_MOUNT" >/dev/null 2>&1 || as_root mount -a >/dev/null 2>&1 || true
        sleep 1

        cnt_tmp="$(count_files_local "$with_tmp")"
        cnt_nested="$(count_files_local "$nested_tmp")"
        cnt_sibling="$(count_files_local "$sibling_tmp")"
        echo "   [📡] Nach Remount: $with_tmp=$cnt_tmp, $nested_tmp=$cnt_nested, $sibling_tmp=$cnt_sibling"

        for p in "${candidate_paths[@]}"; do
            if [ -f "$p/$SERVER_TMP_MARKER" ]; then
                marker_found_at="$p"
                break
            fi
        done
    fi

    if [ -z "$marker_found_at" ]; then
        echo "   [❌] Konnte den tmp-Marker auf dem Client nicht finden."
        echo "      Erwartet in einem der Pfade: $with_tmp | $nested_tmp | $sibling_tmp"
        echo "      Prüfe Client-Mount manuell: mount | grep nfs"
        return 1
    fi

    RESOLVED_CLIENT_TMP_PATH="$marker_found_at"
    echo "   [✅] Erkannter tmp-Zielpfad auf Client: $RESOLVED_CLIENT_TMP_PATH"

    return 0
}

enforce_server_access_for_all() {
    echo "   [🔐] Erzwinge Server-Zugriffsrechte (alle Benutzer) ..."

    sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" 'bash -s' -- \
        "$SERVER_PASS" \
        "$SERVER_BASE_DIR" \
        "$SERVER_WORK_DIR" <<'EOF'
set -euo pipefail
SERVER_PASS="$1"
BASE_DIR="$2"
WORK_DIR="$3"

printf '%s\n' "$SERVER_PASS" | sudo -S -p '' mkdir -p "$BASE_DIR" "$WORK_DIR"

# Harte Rechte-Strategie für reproduzierbare NFS-Schreibbarkeit
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' chown -R 1001:1001 "$BASE_DIR"
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' find "$BASE_DIR" -type d -exec chmod 0777 {} +
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' find "$BASE_DIR" -type f -exec chmod 0666 {} +
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' chmod 0777 "$BASE_DIR" "$WORK_DIR"

if command -v setfacl >/dev/null 2>&1; then
    printf '%s\n' "$SERVER_PASS" | sudo -S -p '' setfacl -R -m u::rwx,g::rwx,o::rwx "$BASE_DIR" || true
    printf '%s\n' "$SERVER_PASS" | sudo -S -p '' setfacl -R -d -m u::rwx,g::rwx,o::rwx "$BASE_DIR" || true
fi

# Schreibtest auf dem tatsächlichen Workdir
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bash -c "touch \"$WORK_DIR/.perm_probe\" && rm -f \"$WORK_DIR/.perm_probe\""
EOF
}

resolve_client_target_path() {
    if [ -n "$RESOLVED_CLIENT_TMP_PATH" ]; then
        echo "$RESOLVED_CLIENT_TMP_PATH"
    else
        echo "$CLIENT_MOUNT/tmp"
    fi
}

start_monitor_on_server() {
    local sim_name="$1"
    local sim_base="${sim_name%.sh}"
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"
    local csv_path="$SERVER_MONITOR_LOG_DIR/${sim_base}_${timestamp}.csv"
    local monitor_stdout="$SERVER_MONITOR_LOG_DIR/${sim_base}_${timestamp}.monitor.log"

    echo -e "\n   [📡] Starte Monitor auf Server für $sim_name ..."
    echo "      -> CSV: $csv_path"

    local ssh_out
    if ! ssh_out=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" 'bash -s' -- \
        "$SERVER_PASS" \
        "$SERVER_MONITOR_SCRIPT_DIR" \
        "$SERVER_MONITOR_LOG_DIR" \
        "$csv_path" \
        "$monitor_stdout" \
        "$SERVER_MONITOR_PID_FILE" \
        "$MONITOR_FLAGS" 2>&1 <<'EOF'
set -euo pipefail
SERVER_PASS="$1"
MONITOR_INPUT="$2"
LOG_DIR="$3"
CSV_PATH="$4"
MONITOR_STDOUT="$5"
PID_FILE="$6"
MONITOR_FLAGS="$7"

resolve_monitor_path() {
    local input="$1"
    local parent
    parent="$(dirname "$input")"
    local candidates=(
        "$input"
        "$input/monitor.sh"
        "$input/security/my_lsm/scripts/monitor.sh"
        "$parent/security/my_lsm/scripts/monitor.sh"
        "/home/server/Desktop/dev/scripts/monitor.sh"
        "/home/server/Desktop/dev/security/my_lsm/scripts/monitor.sh"
        "/work/security/my_lsm/scripts/monitor.sh"
    )
    local c
    for c in "${candidates[@]}"; do
        if [ -f "$c" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

MONITOR_SH="$(resolve_monitor_path "$MONITOR_INPUT" || true)"
if [ -z "${MONITOR_SH:-}" ]; then
    echo "ERROR: monitor.sh not found." >&2
    echo "       Given path: $MONITOR_INPUT" >&2
    echo "       Tip: pass arg5 as SERVER_MONITOR_SCRIPT_DIR (dir or full monitor.sh path)." >&2
    exit 1
fi
MONITOR_DIR="$(dirname "$MONITOR_SH")"

printf '%s\n' "$SERVER_PASS" | sudo -S -p '' mkdir -p "$LOG_DIR"
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' touch "$CSV_PATH"

HELP_TXT="$(bash "$MONITOR_SH" help 2>/dev/null || true)"
HAS_RUN_BG=0
HAS_ENTROPY_FLAG=0
HAS_BPF_LOG_FLAG=0

if echo "$HELP_TXT" | grep -q "run-bg"; then
    HAS_RUN_BG=1
fi
if echo "$HELP_TXT" | grep -q -- "--no-entropy"; then
    HAS_ENTROPY_FLAG=1
fi
if echo "$HELP_TXT" | grep -q -- "--no-bpf-log"; then
    HAS_BPF_LOG_FLAG=1
fi

EFFECTIVE_FLAGS=()
for f in $MONITOR_FLAGS; do
    case "$f" in
        --entropy|--no-entropy)
            [ "$HAS_ENTROPY_FLAG" -eq 1 ] && EFFECTIVE_FLAGS+=("$f")
            ;;
        --bpf-log|--no-bpf-log)
            [ "$HAS_BPF_LOG_FLAG" -eq 1 ] && EFFECTIVE_FLAGS+=("$f")
            ;;
        *)
            EFFECTIVE_FLAGS+=("$f")
            ;;
    esac
done
FLAGS_STR="${EFFECTIVE_FLAGS[*]}"

MODE="legacy"
START_CMD_FAILED=0
if [ "$HAS_RUN_BG" -eq 1 ]; then
    MODE="run-bg"
    if ! printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bash -c "bash \"$MONITOR_SH\" run-bg $FLAGS_STR -o \"$CSV_PATH\" --stdout \"$MONITOR_STDOUT\""; then
        START_CMD_FAILED=1
        echo "WARN: monitor.sh run-bg returned non-zero, continuing with PID validation" >&2
    fi
else
    echo "WARN: remote monitor.sh has no run-bg/teardown, using legacy mode" >&2
    if ! printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bash -c "nohup bash \"$MONITOR_SH\" run $FLAGS_STR -o \"$CSV_PATH\" > \"$MONITOR_STDOUT\" 2>&1 & echo \$! > \"$PID_FILE\""; then
        START_CMD_FAILED=1
        echo "WARN: legacy monitor start command returned non-zero, continuing with PID validation" >&2
    fi
fi

if ! printf '%s\n' "$SERVER_PASS" | sudo -S -p '' test -f "$PID_FILE"; then
    echo "ERROR: monitor pid file not found ($PID_FILE)" >&2
    exit 1
fi

if ! PID_RAW="$(printf '%s\n' "$SERVER_PASS" | sudo -S -p '' cat "$PID_FILE" 2>/dev/null)"; then
    echo "ERROR: cannot read monitor pid file ($PID_FILE)" >&2
    exit 1
fi

PID="$(printf '%s' "$PID_RAW" | tr -d '[:space:]')"
if ! [[ "$PID" =~ ^[0-9]+$ ]]; then
    echo "ERROR: invalid monitor pid '$PID' in $PID_FILE" >&2
    exit 1
fi
if ! printf '%s\n' "$SERVER_PASS" | sudo -S -p '' kill -0 "$PID" >/dev/null 2>&1; then
    echo "ERROR: monitor process not alive after start (PID: $PID)" >&2
    exit 1
fi
if [ "$START_CMD_FAILED" -eq 1 ]; then
    echo "WARN: monitor start command failed but PID $PID is alive; proceeding" >&2
fi
echo "__MONITOR_RESULT__ mode=$MODE pid=$PID"
EOF
    ); then
        local fallback_pid
        fallback_pid="$(echo "$ssh_out" | tr -d '\r' | sed -n 's/.*PID: \([0-9][0-9]*\).*/\1/p' | tail -n1)"
        if [[ "$fallback_pid" =~ ^[0-9]+$ ]]; then
            CURRENT_MONITOR_PID="$fallback_pid"
            CURRENT_MONITOR_MODE="run-bg"
            CURRENT_MONITOR_CSV="$csv_path"
            echo "   [⚠️] Monitor-Start meldete Fehler, Logger läuft aber (PID: $CURRENT_MONITOR_PID)."
            echo "   [✅] Monitor läuft (mode=$CURRENT_MONITOR_MODE, PID=$CURRENT_MONITOR_PID)"
            sleep 2
            return 0
        fi

        echo "   [❌] Monitor-Start per SSH fehlgeschlagen."
        if [ -n "$ssh_out" ]; then
            echo "      Remote-Output:"
            echo "$ssh_out" | sed 's/^/      /'
        fi
        return 1
    fi

    CURRENT_MONITOR_PID="$(echo "$ssh_out" | tr -d '\r' | sed -n 's/.*__MONITOR_RESULT__ mode=[^ ]* pid=\([0-9][0-9]*\).*/\1/p' | tail -n1)"
    CURRENT_MONITOR_MODE="$(echo "$ssh_out" | tr -d '\r' | sed -n 's/.*__MONITOR_RESULT__ mode=\([^ ]*\) pid=.*/\1/p' | tail -n1)"
    CURRENT_MONITOR_CSV="$csv_path"

    if ! [[ "$CURRENT_MONITOR_PID" =~ ^[0-9]+$ ]]; then
        echo "   [❌] Monitor PID konnte nicht ermittelt werden."
        if [ -n "$ssh_out" ]; then
            echo "      SSH-Ausgabe war:"
            echo "$ssh_out"
        fi
        return 1
    fi

    if [ -z "$CURRENT_MONITOR_MODE" ]; then
        CURRENT_MONITOR_MODE="legacy"
    fi
    echo "   [✅] Monitor läuft (mode=$CURRENT_MONITOR_MODE, PID=$CURRENT_MONITOR_PID)"
    sleep 2
    return 0
}

stop_monitor_on_server() {
    if [ -z "$CURRENT_MONITOR_PID" ]; then
        return 0
    fi

    echo -e "\n   [🛑] Stoppe Monitor auf Server (PID: $CURRENT_MONITOR_PID) ..."

    sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "server@$SERVER_IP" 'bash -s' -- \
        "$SERVER_PASS" \
        "$SERVER_MONITOR_SCRIPT_DIR" \
        "$CURRENT_MONITOR_MODE" \
        "$SERVER_MONITOR_PID_FILE" \
        "$CURRENT_MONITOR_PID" <<'EOF'
set -euo pipefail
SERVER_PASS="$1"
MONITOR_INPUT="$2"
MODE="$3"
PID_FILE="$4"
PID_TO_STOP="$5"

resolve_monitor_path() {
    local input="$1"
    local parent
    parent="$(dirname "$input")"
    local candidates=(
        "$input"
        "$input/monitor.sh"
        "$input/security/my_lsm/scripts/monitor.sh"
        "$parent/security/my_lsm/scripts/monitor.sh"
        "/home/server/Desktop/dev/scripts/monitor.sh"
        "/home/server/Desktop/dev/security/my_lsm/scripts/monitor.sh"
        "/work/security/my_lsm/scripts/monitor.sh"
    )
    local c
    for c in "${candidates[@]}"; do
        if [ -f "$c" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

MONITOR_SH="$(resolve_monitor_path "$MONITOR_INPUT" || true)"
if [ -z "${MONITOR_SH:-}" ]; then
    exit 0
fi

if [ "$MODE" = "run-bg" ]; then
    printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bash "$MONITOR_SH" teardown >/dev/null 2>&1 || true
else
    if [ -n "$PID_TO_STOP" ] && printf '%s\n' "$SERVER_PASS" | sudo -S -p '' kill -0 "$PID_TO_STOP" >/dev/null 2>&1; then
        printf '%s\n' "$SERVER_PASS" | sudo -S -p '' kill -INT "$PID_TO_STOP" >/dev/null 2>&1 || true
        sleep 1
        if printf '%s\n' "$SERVER_PASS" | sudo -S -p '' kill -0 "$PID_TO_STOP" >/dev/null 2>&1; then
            printf '%s\n' "$SERVER_PASS" | sudo -S -p '' kill -TERM "$PID_TO_STOP" >/dev/null 2>&1 || true
        fi
    fi
    printf '%s\n' "$SERVER_PASS" | sudo -S -p '' rm -f "$PID_FILE" >/dev/null 2>&1 || true
    printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bash "$MONITOR_SH" unload >/dev/null 2>&1 || true
fi
EOF

    echo "   [✅] Monitor gestoppt."
    if [ -n "$CURRENT_MONITOR_CSV" ]; then
        echo "      CSV gespeichert unter: $CURRENT_MONITOR_CSV"
    fi
    CURRENT_MONITOR_PID=""
    CURRENT_MONITOR_CSV=""
    CURRENT_MONITOR_MODE=""
}

cleanup_on_exit() {
    if [ "$ENABLE_REMOTE_MONITOR" = "1" ]; then
        stop_monitor_on_server || true
    fi
    clear_server_tmp_dir || true
}

trap cleanup_on_exit EXIT INT TERM

echo "=================================================="
echo " 🚀 Master Suite: Automatisierter Testlauf"
echo "=================================================="

check_local_runtime_prereqs

SIMS=("run_ebpfangel_ransomware.sh" "run_h4kd3v_ransomware.sh" "run_serdarumut_ransomware.sh" "run_nextron_systems_ransomware.sh")

for sim in "${SIMS[@]}"; do
    if [ -f "$RANSOM_DIR/$sim" ]; then
        if [ "$SKIP_NEXTRON" -eq 1 ] && [ "$sim" = "run_nextron_systems_ransomware.sh" ]; then
            echo "   [⏭️] Überspringe $sim (go nicht verfügbar)."
            continue
        fi

        if ! restore_data_on_server; then
            echo "   [❌] Restore fehlgeschlagen. Überspringe $sim."
            continue
        fi
        enforce_server_access_for_all
        if ! ensure_client_nfs_visibility; then
            echo "   [❌] NFS-Sichtprüfung fehlgeschlagen. Überspringe $sim."
            continue
        fi

        if [ "$ENABLE_REMOTE_MONITOR" = "1" ]; then
            if ! start_monitor_on_server "$sim"; then
                echo "   [❌] Monitor-Start fehlgeschlagen. Überspringe $sim."
                continue
            fi
        fi

        echo -e "\n[🔥] Starte Simulator: $sim"
        target_dir="$(resolve_client_target_path)"
        target_count="$(find "$target_dir" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
        echo "   [📁] Client-Zielpfad: $target_dir (Dateien: ${target_count:-0})"

        if ! bash "$RANSOM_DIR/$sim" "$target_dir" "$DURATION"; then
            echo "   [❌] Simulator fehlgeschlagen: $sim"
        fi

        if [ "$ENABLE_REMOTE_MONITOR" = "1" ]; then
            stop_monitor_on_server
        fi
        clear_server_tmp_dir || true
        sleep 5
    fi
done
