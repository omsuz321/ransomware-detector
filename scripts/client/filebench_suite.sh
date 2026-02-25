#!/bin/bash
# ============================================================================
# Filebench Suite Runner
# - Orchestrates workloads only
# - Delegates all filebench behavior to filebench.sh
# - Workflow per workload: prepare -> run (Pause nach Preallocation) -> monitor start -> user bestätigt "y" -> run -> monitor stop
# ============================================================================

set -euo pipefail

SERVER_IP="${1:-}"
CLIENT_MOUNT="${2:-/mnt/nfs}"
DURATION="${3:-60}"
NTHREADS="${4:-4}"
WORKLOADS_RAW="${5:-webserver,fileserver,varmail}"
NFS_EXPORT="${6:-/srv/nfs/thesis_data}"
TARGET_ROOT_ARG="${7:-}"

NFS_VERS="4.1"
NFS_OPTS="rw,relatime"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILEBENCH_CTRL="$SCRIPT_DIR/filebench.sh"

# Remote monitor (optional, disabled by default)
ENABLE_REMOTE_MONITOR=0
SERVER_PASS=""
SERVER_MONITOR_SCRIPT_DIR="/home/server/Desktop/dev/scripts"
SERVER_MONITOR_LOG_DIR="/home/server/Desktop/monitor_logs"
SERVER_MONITOR_PID_FILE="/tmp/fileops_logger.pid"
MONITOR_ENTROPY_FLAG="--no-entropy"
MONITOR_BPF_LOG_FLAG="--no-bpf-log"
MONITOR_FLAGS=""
CURRENT_MONITOR_PID=""
CURRENT_MONITOR_MODE=""
CURRENT_MONITOR_CSV=""
SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o LogLevel=ERROR
  -o ConnectTimeout=10
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=2
)

REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME="$(eval echo "~$REAL_USER")"
FILEBENCH_REPO_DIR="${FILEBENCH_REPO_DIR:-$REAL_HOME/Desktop/filebench}"
PREFERRED_PROFILE_DIR="$SCRIPT_DIR/profiles"
if [ -d "$PREFERRED_PROFILE_DIR" ]; then
  DEFAULT_PROFILE_DIR="$PREFERRED_PROFILE_DIR"
else
  DEFAULT_PROFILE_DIR="$FILEBENCH_REPO_DIR/workloads"
fi

PROFILE_DIR="$DEFAULT_PROFILE_DIR"
TARGET_ROOT=""
LOG_DIR=""
ALWAYS_PREPARE=1
MONITOR_START_MODE="at-confirm"  # at-confirm|before-run
MONITOR_EVENT_LOG=""
PROFILE_DIR_USER_SET=0
RUN_MODE_OPTS=()

DURATION="$(echo "$DURATION" | sed 's/[^0-9]//g')"
NTHREADS="$(echo "$NTHREADS" | sed 's/[^0-9]//g')"
[ -z "$DURATION" ] && DURATION="60"
[ -z "$NTHREADS" ] && NTHREADS="4"

# Parse optional flags.
# If arg7 starts with "--", it's not TARGET_ROOT but already an option.
if [[ "${TARGET_ROOT_ARG:-}" == --* ]]; then
  TARGET_ROOT_ARG=""
  if [ "$#" -gt 6 ]; then
    set -- "${@:7}"
  else
    set --
  fi
else
  if [ "$#" -gt 7 ]; then
    set -- "${@:8}"
  else
    set --
  fi
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --remote-monitor)
      ENABLE_REMOTE_MONITOR=1
      shift
      ;;
    --no-remote-monitor)
      ENABLE_REMOTE_MONITOR=0
      shift
      ;;
    --server-pass)
      [ $# -lt 2 ] && { echo "❌ --server-pass benötigt ein Argument."; exit 1; }
      SERVER_PASS="$2"
      shift 2
      ;;
    --monitor-script-dir)
      [ $# -lt 2 ] && { echo "❌ --monitor-script-dir benötigt ein Argument."; exit 1; }
      SERVER_MONITOR_SCRIPT_DIR="$2"
      shift 2
      ;;
    --monitor-log-dir)
      [ $# -lt 2 ] && { echo "❌ --monitor-log-dir benötigt ein Argument."; exit 1; }
      SERVER_MONITOR_LOG_DIR="$2"
      shift 2
      ;;
    --entropy|--no-entropy)
      MONITOR_ENTROPY_FLAG="$1"
      shift
      ;;
    --bpf-log|--no-bpf-log)
      MONITOR_BPF_LOG_FLAG="$1"
      shift
      ;;
    --profiles-dir)
      [ $# -lt 2 ] && { echo "❌ --profiles-dir benötigt ein Argument."; exit 1; }
      PROFILE_DIR="$2"
      PROFILE_DIR_USER_SET=1
      shift 2
      ;;
    --always-prepare)
      ALWAYS_PREPARE=1
      shift
      ;;
    --reuse-data)
      ALWAYS_PREPARE=0
      shift
      ;;
    --monitor-at-confirm)
      MONITOR_START_MODE="at-confirm"
      shift
      ;;
    --monitor-before-run)
      MONITOR_START_MODE="before-run"
      shift
      ;;
    --no-reuse)
      RUN_MODE_OPTS=("--no-reuse")
      shift
      ;;
    --reuse)
      RUN_MODE_OPTS=("--reuse")
      shift
      ;;
    # Backward compatibility: these options were used by an older filebench.sh.
    --nfiles|--filesize|--dirwidth|--prealloc)
      echo "ℹ️  Hinweis: $1 wird von der aktuellen filebench.sh nicht unterstützt und wird ignoriert."
      if [[ "$1" == "--nfiles" || "$1" == "--filesize" || "$1" == "--dirwidth" || "$1" == "--prealloc" ]]; then
        [ $# -lt 2 ] && { echo "❌ $1 benötigt ein Argument."; exit 1; }
        shift 2
      else
        shift
      fi
      ;;
    # Backward compatibility: these used to be suite-local options, now ignored.
    --run-as-user|--run-as-root|--compat-no-prealloc|--keep-prealloc)
      echo "ℹ️  Hinweis: $1 wird in filebench_suite.sh nicht mehr verwendet (filebench.sh ist autonom)."
      shift
      ;;
    *)
      echo "❌ Unbekannte Option: $1"
      echo "Erlaubt: --remote-monitor | --no-remote-monitor | --server-pass PASS | --monitor-script-dir DIR|FILE | --monitor-log-dir DIR | --entropy|--no-entropy | --bpf-log|--no-bpf-log | --profiles-dir DIR | --always-prepare|--reuse-data | --monitor-at-confirm|--monitor-before-run | --reuse|--no-reuse"
      exit 1
      ;;
  esac
done

MONITOR_FLAGS="$MONITOR_ENTROPY_FLAG $MONITOR_BPF_LOG_FLAG"

resolve_profiles_dir() {
  local candidates=()
  local c

  if [ -d "$PROFILE_DIR" ]; then
    return 0
  fi

  if [ "$PROFILE_DIR_USER_SET" -eq 1 ]; then
    echo "⚠️  Angegebener --profiles-dir nicht gefunden: $PROFILE_DIR"
  fi

  candidates+=("$SCRIPT_DIR/profiles")
  candidates+=("$FILEBENCH_REPO_DIR/workloads")
  candidates+=("$(pwd)/profiles")
  candidates+=("$(pwd)/workloads")

  for c in "${candidates[@]}"; do
    if [ -d "$c" ]; then
      echo "ℹ️  Nutze Fallback PROFILE_DIR: $c"
      PROFILE_DIR="$c"
      return 0
    fi
  done

  echo "❌ PROFILE_DIR nicht gefunden. Geprüft:"
  echo "   - $PROFILE_DIR"
  for c in "${candidates[@]}"; do
    echo "   - $c"
  done
  exit 1
}

if [ -n "$TARGET_ROOT_ARG" ]; then
  if [[ "$TARGET_ROOT_ARG" = /* ]]; then
    TARGET_ROOT="$TARGET_ROOT_ARG"
  else
    TARGET_ROOT="$CLIENT_MOUNT/$TARGET_ROOT_ARG"
  fi
else
  TARGET_ROOT="$CLIENT_MOUNT/filebench"
fi
LOG_DIR="$TARGET_ROOT/logs"

usage() {
  cat <<EOF
Usage:
  bash $0 SERVER_IP [CLIENT_MOUNT] [DURATION_SEC] [NTHREADS] [WORKLOADS] [NFS_EXPORT] [TARGET_ROOT]
       [--remote-monitor --server-pass PASS [--monitor-script-dir DIR|FILE] [--monitor-log-dir DIR] [--entropy|--no-entropy] [--bpf-log|--no-bpf-log]]
       [--profiles-dir DIR] [--always-prepare|--reuse-data] [--monitor-at-confirm|--monitor-before-run] [--reuse|--no-reuse]

Examples:
  bash $0 192.168.2.209 /mnt/nfs 45 1 all /srv/nfs/thesis_data /mnt/nfs/filebench --no-remote-monitor
  bash $0 192.168.2.209 /mnt/nfs 45 1 webserver,fileserver /srv/nfs/thesis_data /mnt/nfs/filebench --remote-monitor --server-pass 1234 --no-entropy --no-bpf-log

Notes:
  - filebench_suite.sh orchestriert nur; die Filebench-Logik liegt in filebench.sh.
  - Workflow pro Workload:
      prepare -> run (Pause nach Preallocation) -> optional Monitor-Start -> user bestätigt "y" -> Run läuft weiter -> monitor stop
  - WORKLOADS=all liest alle *.f in PROFILE_DIR und nutzt deren Basename als Workload-Name.
  - Default ist --always-prepare; mit --reuse-data wird prepare übersprungen, falls Daten schon da sind.
  - Bei --remote-monitor ist Default --monitor-at-confirm:
      Der Monitor startet erst wenn Filebench "Population and pre-allocation ... completed" meldet.
      Danach kannst du im Filebench-Prompt mit "y" fortfahren.
  - TARGET_ROOT:
      absolute path  -> used directly
      relative path  -> interpreted as \$CLIENT_MOUNT/<TARGET_ROOT>
EOF
}

if [ -z "$SERVER_IP" ] || [ "$SERVER_IP" = "-h" ] || [ "$SERVER_IP" = "--help" ]; then
  usage
  exit 1
fi

if [ ! -f "$FILEBENCH_CTRL" ]; then
  echo "❌ filebench.sh nicht gefunden: $FILEBENCH_CTRL"
  exit 1
fi

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

as_user() {
  if [ "$(id -u)" -eq 0 ]; then
    sudo -u "$REAL_USER" "$@"
  else
    "$@"
  fi
}

ensure_dir() {
  local d="$1"
  if ! as_user mkdir -p "$d" 2>/dev/null; then
    as_root mkdir -p "$d"
  fi
}

monitor_msg() {
  local msg="$1"
  echo "$msg"
  if [ -n "${MONITOR_EVENT_LOG:-}" ]; then
    printf '%s\n' "$msg" >> "$MONITOR_EVENT_LOG"
  fi
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

resolve_profile_file() {
  local workload="$1"
  if [ -f "$workload" ]; then
    printf '%s' "$workload"
    return 0
  fi
  if [ -f "$PROFILE_DIR/$workload" ]; then
    printf '%s' "$PROFILE_DIR/$workload"
    return 0
  fi
  if [ -f "$PROFILE_DIR/$workload.f" ]; then
    printf '%s' "$PROFILE_DIR/$workload.f"
    return 0
  fi
  return 1
}

count_files() {
  local d="$1"
  if [ -d "$d" ]; then
    find "$d" -type f 2>/dev/null | wc -l | tr -d '[:space:]'
  else
    echo "0"
  fi
}

drop_client_caches() {
  echo "   [🧹] Drop client caches ..."
  as_root sh -c "sync; echo 3 > /proc/sys/vm/drop_caches"
}

run_filebench_cmd() {
  local log_file="$1"
  shift
  local subcmd="${1:-}"
  local rc=0

  bash "$FILEBENCH_CTRL" "$@" > >(tee "$log_file") 2>&1 || rc=$?
  if grep -Eiq "syntax error at|Cannot open file|buffer overflow detected" "$log_file"; then
    rc=1
  fi
  # "Warning: no run command" ist bei "prepare" erwartbar (create files only).
  if [ "$subcmd" = "run" ] && grep -Eiq "Warning: no run command" "$log_file"; then
    rc=1
  fi

  return "$rc"
}

run_filebench_run_with_monitor_hook() {
  local workload="$1"
  local log_file="$2"
  shift 2
  local fb_pipe fb_pid fb_status line
  local hook_seen=0
  local rc=0

  : > "$log_file"
  fb_pipe="$(mktemp -u /tmp/filebench_suite_stream.XXXXXX.pipe)"
  mkfifo "$fb_pipe"

  if command -v stdbuf >/dev/null 2>&1; then
    stdbuf -oL -eL bash "$FILEBENCH_CTRL" "$@" >"$fb_pipe" 2>&1 &
  else
    bash "$FILEBENCH_CTRL" "$@" >"$fb_pipe" 2>&1 &
  fi
  fb_pid=$!

  set +e
  while IFS= read -r line; do
    echo "$line"
    printf '%s\n' "$line" >> "$log_file"
    if [ "$ENABLE_REMOTE_MONITOR" = "1" ] && [ "$hook_seen" -eq 0 ]; then
      if [[ "$line" == *"Population and pre-allocation of filesets completed"* ]] || [[ "$line" == *"Pre-allocation of filesets completed"* ]]; then
        hook_seen=1
        monitor_msg "   [📡] Preallocation abgeschlossen. Starte Remote-Monitor jetzt ..."
        if ! start_monitor_on_server "$workload"; then
          monitor_msg "   [❌] Monitor-Start am Checkpoint fehlgeschlagen."
          rc=1
        else
          monitor_msg "   [👉] Monitor läuft. Jetzt im Filebench-Prompt mit 'y' bestätigen."
        fi
      fi
    fi
  done < "$fb_pipe"
  wait "$fb_pid"
  fb_status=$?
  set -e
  rm -f "$fb_pipe" 2>/dev/null || true

  if [ "$ENABLE_REMOTE_MONITOR" = "1" ] && [ "$MONITOR_START_MODE" = "at-confirm" ] && [ "$hook_seen" -eq 0 ]; then
    monitor_msg "   [⚠️] Checkpoint für Monitor-Start nicht erkannt."
    monitor_msg "   [⚠️] Ursache: Run zu kurz, anderes Profil, oder abweichende Filebench-Ausgabe."
    rc=1
  fi

  if grep -Eiq "syntax error at|Warning: no run command|Cannot open file|buffer overflow detected" "$log_file"; then
    rc=1
  fi
  if [ "$fb_status" -ne 0 ]; then
    rc="$fb_status"
  fi

  return "$rc"
}

ensure_monitor_prereqs() {
  if [ "$ENABLE_REMOTE_MONITOR" != "1" ]; then
    return 0
  fi

  if ! command -v sshpass >/dev/null 2>&1; then
    echo "❌ sshpass fehlt auf dem Client, aber --remote-monitor wurde gesetzt."
    echo "   Installiere mit: sudo apt install -y sshpass"
    exit 1
  fi

  if [ -z "$SERVER_PASS" ]; then
    echo "❌ --remote-monitor benötigt --server-pass PASS."
    exit 1
  fi
}

start_monitor_on_server() {
  local workload="$1"
  local timestamp
  timestamp="$(date +%Y%m%d_%H%M%S)"
  local csv_path="$SERVER_MONITOR_LOG_DIR/filebench_${workload}_${timestamp}.csv"
  local monitor_stdout="$SERVER_MONITOR_LOG_DIR/filebench_${workload}_${timestamp}.monitor.log"

  monitor_msg "   [📡] Starte Monitor auf Server für Workload '$workload' ..."
  monitor_msg "      -> CSV: $csv_path"

  local ssh_out=""
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
    exit 1
fi

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
      monitor_msg "   [⚠️] Monitor-Start meldete Fehler, Logger läuft aber (PID: $CURRENT_MONITOR_PID)."
      return 0
    fi

    monitor_msg "   [❌] Monitor-Start per SSH fehlgeschlagen."
    if [ -n "$ssh_out" ]; then
      monitor_msg "      Remote-Output:"
      if [ -n "${MONITOR_EVENT_LOG:-}" ]; then
        echo "$ssh_out" | sed 's/^/      /' | tee -a "$MONITOR_EVENT_LOG"
      else
        echo "$ssh_out" | sed 's/^/      /'
      fi
    fi
    return 1
  fi

  CURRENT_MONITOR_PID="$(echo "$ssh_out" | tr -d '\r' | sed -n 's/.*__MONITOR_RESULT__ mode=[^ ]* pid=\([0-9][0-9]*\).*/\1/p' | tail -n1)"
  CURRENT_MONITOR_MODE="$(echo "$ssh_out" | tr -d '\r' | sed -n 's/.*__MONITOR_RESULT__ mode=\([^ ]*\) pid=.*/\1/p' | tail -n1)"
  CURRENT_MONITOR_CSV="$csv_path"

  if ! [[ "$CURRENT_MONITOR_PID" =~ ^[0-9]+$ ]]; then
    monitor_msg "   [❌] Monitor PID konnte nicht ermittelt werden."
    if [ -n "$ssh_out" ]; then
      if [ -n "${MONITOR_EVENT_LOG:-}" ]; then
        echo "$ssh_out" | sed 's/^/      /' | tee -a "$MONITOR_EVENT_LOG"
      else
        echo "$ssh_out" | sed 's/^/      /'
      fi
    fi
    return 1
  fi

  [ -z "$CURRENT_MONITOR_MODE" ] && CURRENT_MONITOR_MODE="legacy"
  monitor_msg "   [✅] Monitor läuft (mode=$CURRENT_MONITOR_MODE, PID=$CURRENT_MONITOR_PID)"
  return 0
}

stop_monitor_on_server() {
  if [ -z "$CURRENT_MONITOR_PID" ]; then
    return 0
  fi

  monitor_msg "   [🛑] Stoppe Monitor auf Server (PID: $CURRENT_MONITOR_PID) ..."
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

  monitor_msg "   [✅] Monitor gestoppt."
  if [ -n "$CURRENT_MONITOR_CSV" ]; then
    monitor_msg "      CSV gespeichert unter: $CURRENT_MONITOR_CSV"
  fi
  CURRENT_MONITOR_PID=""
  CURRENT_MONITOR_MODE=""
  CURRENT_MONITOR_CSV=""
}

cleanup_on_exit() {
  if [ "$ENABLE_REMOTE_MONITOR" = "1" ]; then
    stop_monitor_on_server || true
  fi
}

resolve_workloads() {
  WORKLOADS=()
  if [ "$WORKLOADS_RAW" = "all" ]; then
    if [ -d "$PROFILE_DIR" ]; then
      while IFS= read -r -d '' profile_path; do
        profile_name="$(basename "$profile_path")"
        workload_name="${profile_name%.f}"
        [ -n "$workload_name" ] && WORKLOADS+=("$workload_name")
      done < <(find "$PROFILE_DIR" -maxdepth 1 -type f -name '*.f' -print0 | sort -z)
    else
      echo "   [⚠️] PROFILE_DIR nicht gefunden: $PROFILE_DIR"
      echo "   [⚠️] Fallback auf Standard-Workloads: webserver,fileserver,varmail,netsfs"
      WORKLOADS=(webserver fileserver varmail netsfs)
    fi
  else
    WORKLOADS_EXPANDED="${WORKLOADS_RAW//,/ }"
    read -r -a WORKLOADS <<< "$WORKLOADS_EXPANDED"
  fi
}

ensure_nfs_41_mount() {
  echo "   [🔗] Ensure NFS mount (v$NFS_VERS) ..."
  as_root mkdir -p "$CLIENT_MOUNT"
  if mountpoint -q "$CLIENT_MOUNT"; then
    echo "   [✅] Bereits gemountet: $CLIENT_MOUNT"
    return 0
  fi
  as_root mount -t nfs -o "vers=${NFS_VERS},${NFS_OPTS}" "${SERVER_IP}:${NFS_EXPORT}" "$CLIENT_MOUNT"
  echo "   [✅] Gemountet: ${SERVER_IP}:${NFS_EXPORT} -> $CLIENT_MOUNT"
}

trap cleanup_on_exit EXIT INT TERM

echo "=================================================="
echo " 🚀 Filebench Suite"
echo "=================================================="
echo "Server IP:        $SERVER_IP"
echo "NFS Export:       $NFS_EXPORT"
echo "Client Mount:     $CLIENT_MOUNT"
echo "NFS Version:      $NFS_VERS"
echo "Duration:         ${DURATION}s"
echo "Threads:          $NTHREADS"
echo "Workloads:        $WORKLOADS_RAW"
echo "Profiles Dir:     $PROFILE_DIR"
if [ "$ALWAYS_PREPARE" = "1" ]; then
  echo "Prepare Mode:     immer (Default)"
else
  echo "Prepare Mode:     reuse vorhandene Daten"
fi
if [ "$ENABLE_REMOTE_MONITOR" = "1" ]; then
  echo "Remote Monitor:   aktiviert"
  echo "Monitor Start:    $MONITOR_START_MODE"
else
  echo "Remote Monitor:   deaktiviert"
fi
if [ "${#RUN_MODE_OPTS[@]}" -gt 0 ]; then
  echo "Run Mode Opts:    ${RUN_MODE_OPTS[*]}"
fi

ensure_monitor_prereqs
resolve_profiles_dir
ensure_nfs_41_mount

ensure_dir "$TARGET_ROOT"
ensure_dir "$LOG_DIR"
echo "   [📁] NFS-Zielordner: $TARGET_ROOT"

resolve_workloads
if [ "${#WORKLOADS[@]}" -eq 0 ]; then
  echo "❌ Keine Workloads gefunden."
  echo "   WORKLOADS='$WORKLOADS_RAW' PROFILE_DIR='$PROFILE_DIR'"
  exit 1
fi

FAILED_RUNS=0

for wl_raw in "${WORKLOADS[@]}"; do
  workload="$(trim "$wl_raw")"
  [ -z "$workload" ] && continue

  profile_file="$(resolve_profile_file "$workload" || true)"
  if [ -z "$profile_file" ]; then
    echo "   [❌] Profil für Workload '$workload' nicht gefunden (PROFILE_DIR=$PROFILE_DIR)."
    FAILED_RUNS=$((FAILED_RUNS + 1))
    continue
  fi

  workload_dir="$TARGET_ROOT/$workload"
  ensure_dir "$workload_dir"
  existing_count="$(count_files "$workload_dir")"
  MONITOR_EVENT_LOG="$LOG_DIR/${workload}_monitor_$(date +%Y%m%d_%H%M%S).log"

  echo
  echo "--------------------------------------------------"
  echo " ▶ Workload: $workload"
  echo "   Profil:   $profile_file"
  echo "   Ziel:     $workload_dir"
  echo "   Dateien:  $existing_count"

  if [ "$ALWAYS_PREPARE" = "1" ] || [ "${existing_count:-0}" -eq 0 ]; then
    echo "   [⚙️] Prepare via filebench.sh ..."
    prepare_log="$LOG_DIR/${workload}_prepare_$(date +%Y%m%d_%H%M%S).log"
    if ! run_filebench_cmd "$prepare_log" prepare "$profile_file" "$workload_dir"; then
      echo "   [❌] Prepare fehlgeschlagen für '$workload'."
      FAILED_RUNS=$((FAILED_RUNS + 1))
      continue
    fi
  else
    echo "   [♻️] Reuse vorhandene Workload-Daten (kein prepare)."
  fi

  monitor_started=0
  run_log="$LOG_DIR/${workload}_run_$(date +%Y%m%d_%H%M%S).log"

  if [ "$ENABLE_REMOTE_MONITOR" = "1" ] && [ "$MONITOR_START_MODE" = "before-run" ]; then
    if ! start_monitor_on_server "$workload"; then
      echo "   [❌] Monitor-Start fehlgeschlagen. Überspringe '$workload'."
      FAILED_RUNS=$((FAILED_RUNS + 1))
      continue
    fi
    monitor_started=1
  fi

  echo "   [🏁] Run via filebench.sh ..."
  if [ "$ENABLE_REMOTE_MONITOR" = "1" ] && [ "$MONITOR_START_MODE" = "at-confirm" ]; then
    echo "   [ℹ️] Bitte im Filebench-Prompt 'y' erst drücken, wenn '[👉] Monitor läuft' angezeigt wurde."
    if ! run_filebench_run_with_monitor_hook "$workload" "$run_log" run \
      "$profile_file" \
      "$workload_dir" \
      "$DURATION" \
      --threads "$NTHREADS" \
      --drop-caches \
      --confirm-drop \
      "${RUN_MODE_OPTS[@]}"; then
      echo "   [❌] Filebench-Run fehlgeschlagen für '$workload'."
      FAILED_RUNS=$((FAILED_RUNS + 1))
    fi
    if [ -n "$CURRENT_MONITOR_PID" ]; then
      monitor_started=1
    fi
  else
    # Ohne at-confirm Start: optional Cache-Drop vor Run, dann normaler run ohne Prompt.
    drop_client_caches
    if ! run_filebench_cmd "$run_log" run \
      "$profile_file" \
      "$workload_dir" \
      "$DURATION" \
      --threads "$NTHREADS" \
      --no-drop-caches \
      --no-confirm-drop \
      "${RUN_MODE_OPTS[@]}"; then
      echo "   [❌] Filebench-Run fehlgeschlagen für '$workload'."
      FAILED_RUNS=$((FAILED_RUNS + 1))
    fi
  fi

  if [ "$monitor_started" -eq 1 ]; then
    stop_monitor_on_server || true
  fi
done

echo
echo "✅ Suite abgeschlossen. Logs unter: $LOG_DIR"
if [ "$FAILED_RUNS" -gt 0 ]; then
  echo "⚠️  Fehlgeschlagene Runs: $FAILED_RUNS"
  exit 1
fi
