#!/bin/bash
# ============================================================================
# Simple Filebench Suite Runner
# - Direkter Aufruf via `filebench -f`
# - Keine Flag-Orgie, nur wenige Positionsargumente
# - Workflow je Workload: direkter Profil-Run
# - Nach Preallocation: drop caches -> start monitor
# ============================================================================

set -euo pipefail

SERVER_IP="${1:-}"
SERVER_PASS="${2:-}"
WORKLOADS_RAW="${3:-all}"   # all | webserver,fileserver,...

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$SCRIPT_DIR/profiles"

CLIENT_MOUNT="/mnt/nfs"
NFS_EXPORT="/srv/nfs/thesis_data"
NFS_VERS="4.1"
NFS_OPTS="rw,relatime"
TARGET_ROOT="$CLIENT_MOUNT/filebench"
LOG_DIR="$TARGET_ROOT/logs"

REAL_USER="${SUDO_USER:-$(whoami)}"
BENCH_USER="${FILEBENCH_USER:-$REAL_USER}"

MONITOR_USER="server"
MONITOR_SCRIPT_INPUT="/home/server/Desktop/dev/scripts"
MONITOR_LOG_DIR="/home/server/Desktop/monitor_logs"
MONITOR_PID_FILE="/tmp/fileops_logger.pid"
MONITOR_FLAGS="--no-entropy --no-bpf-log"
CURRENT_MONITOR_PID=""
CURRENT_MONITOR_MODE=""
CURRENT_MONITOR_CSV=""
MONITOR_EVENT_LOG=""

ASLR_ORIG=""

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o LogLevel=ERROR
  -o ConnectTimeout=10
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=2
)

usage() {
  cat <<USAGE
Usage:
  sudo bash $0 <SERVER_IP> <SERVER_PASS> [WORKLOADS]

Args:
  SERVER_IP     NFS/Monitor Server (z.B. 192.168.2.209)
  SERVER_PASS   Passwort für user '$MONITOR_USER' auf dem Server
  WORKLOADS     all (default) oder CSV-Liste, z.B. fileserver,webserver

Notes:
  - Profile werden aus: $PROFILE_DIR
  - Suite ruft direkt 'filebench -f <profil>' auf.
  - Nach "Population and pre-allocation ... completed":
      1) client cache gedroppt
      2) Monitor gestartet
USAGE
}

if [[ -z "$SERVER_IP" || "$SERVER_IP" == "-h" || "$SERVER_IP" == "--help" ]]; then
  usage
  exit 1
fi

if [[ -z "$SERVER_PASS" ]]; then
  read -r -s -p "Server password for $MONITOR_USER@$SERVER_IP: " SERVER_PASS
  echo
  [[ -n "$SERVER_PASS" ]] || { echo "❌ Kein Passwort angegeben."; exit 1; }
fi

as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

as_user() {
  local u="$1"
  shift
  if [[ "$(id -un)" == "$u" ]]; then
    "$@"
  elif [[ "$u" == "root" ]]; then
    as_root "$@"
  elif [[ "$(id -u)" -eq 0 ]] && command -v runuser >/dev/null 2>&1; then
    runuser -u "$u" -- "$@"
  else
    sudo -u "$u" "$@"
  fi
}

disable_aslr() {
  ASLR_ORIG="$(cat /proc/sys/kernel/randomize_va_space)"
  as_root sh -c "echo 0 > /proc/sys/kernel/randomize_va_space"
}

restore_aslr() {
  if [[ -n "${ASLR_ORIG:-}" ]]; then
    as_root sh -c "echo $ASLR_ORIG > /proc/sys/kernel/randomize_va_space"
    ASLR_ORIG=""
  fi
}

monitor_msg() {
  local msg="$1"
  echo "$msg"
  if [[ -n "${MONITOR_EVENT_LOG:-}" ]]; then
    printf '%s\n' "$msg" >> "$MONITOR_EVENT_LOG"
  fi
}

ensure_prereqs() {
  command -v filebench >/dev/null 2>&1 || { echo "❌ filebench fehlt."; exit 1; }
  command -v sshpass >/dev/null 2>&1 || { echo "❌ sshpass fehlt."; exit 1; }
  [[ -d "$PROFILE_DIR" ]] || { echo "❌ Profile-Ordner fehlt: $PROFILE_DIR"; exit 1; }
}

ensure_nfs_mount() {
  as_root mkdir -p "$CLIENT_MOUNT"
  if mountpoint -q "$CLIENT_MOUNT"; then
    echo "[✅] Bereits gemountet: $CLIENT_MOUNT"
  else
    as_root mount -t nfs -o "vers=${NFS_VERS},${NFS_OPTS}" "${SERVER_IP}:${NFS_EXPORT}" "$CLIENT_MOUNT"
    echo "[✅] Gemountet: ${SERVER_IP}:${NFS_EXPORT} -> $CLIENT_MOUNT"
  fi
}

resolve_workloads() {
  local raw="$1"
  local out=()

  if [[ "$raw" == "all" ]]; then
    while IFS= read -r -d '' f; do
      out+=("$(basename "${f%.f}")")
    done < <(find "$PROFILE_DIR" -maxdepth 1 -type f -name '*.f' -print0 | sort -z)
  else
    local expanded="${raw//,/ }"
    read -r -a out <<< "$expanded"
  fi

  printf '%s\n' "${out[@]}"
}

resolve_profile_file() {
  local wl="$1"
  if [[ -f "$PROFILE_DIR/$wl" ]]; then
    echo "$PROFILE_DIR/$wl"
    return
  fi
  if [[ -f "$PROFILE_DIR/$wl.f" ]]; then
    echo "$PROFILE_DIR/$wl.f"
    return
  fi
  echo ""
}

resolve_target_dir_from_profile() {
  local profile_file="$1"
  local fallback_workload="$2"
  local from_profile=""

  from_profile="$(sed -nE 's/^[[:space:]]*set[[:space:]]+\$dir[[:space:]]*=[[:space:]]*([^[:space:]#]+).*$/\1/p' "$profile_file" | head -n1)"
  if [[ -n "$from_profile" ]]; then
    echo "$from_profile"
  else
    echo "$TARGET_ROOT/$fallback_workload"
  fi
}

resolve_runtime_from_profile() {
  local profile_file="$1"
  local run_num=""
  local runtime_set=""

  run_num="$(sed -nE 's/^[[:space:]]*run[[:space:]]+([0-9]+)[[:space:]]*$/\1/p' "$profile_file" | head -n1)"
  if [[ -n "$run_num" ]]; then
    echo "$run_num"
    return
  fi

  if grep -qiE '^[[:space:]]*run[[:space:]]+\$runtime([[:space:]]|$)' "$profile_file"; then
    runtime_set="$(sed -nE 's/^[[:space:]]*set[[:space:]]+\$runtime[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "$profile_file" | head -n1)"
    if [[ -n "$runtime_set" ]]; then
      echo "$runtime_set"
      return
    fi
  fi

  echo "60"
}

count_files() {
  local d="$1"
  find "$d" -type f 2>/dev/null | wc -l | tr -d '[:space:]'
}

drop_client_caches() {
  monitor_msg "   [🧹] Drop client caches ..."
  as_root sh -c "sync; echo 3 > /proc/sys/vm/drop_caches"
}

start_monitor_on_server() {
  local workload="$1"
  local timestamp
  timestamp="$(date +%Y%m%d_%H%M%S)"
  local csv_path="$MONITOR_LOG_DIR/filebench_${workload}_${timestamp}.csv"
  local monitor_stdout="$MONITOR_LOG_DIR/filebench_${workload}_${timestamp}.monitor.log"

  monitor_msg "   [📡] Starte Monitor auf Server für Workload '$workload' ..."
  monitor_msg "      -> CSV: $csv_path"

  local ssh_out=""
  local ssh_rc=0
  local parsed_pid=""
  local parsed_mode=""
  local fallback_pid=""
  ssh_out=$(sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "$MONITOR_USER@$SERVER_IP" 'bash -s' -- \
      "$SERVER_PASS" \
      "$MONITOR_SCRIPT_INPUT" \
      "$MONITOR_LOG_DIR" \
      "$csv_path" \
      "$monitor_stdout" \
      "$MONITOR_PID_FILE" \
      "$MONITOR_FLAGS" 2>&1 <<'REMOTE_EOF'
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
  exit 1
fi

printf '%s\n' "$SERVER_PASS" | sudo -S -p '' mkdir -p "$LOG_DIR"
printf '%s\n' "$SERVER_PASS" | sudo -S -p '' touch "$CSV_PATH"

HELP_TXT="$(bash "$MONITOR_SH" help 2>/dev/null || true)"
HAS_RUN_BG=0
if echo "$HELP_TXT" | grep -q "run-bg"; then
  HAS_RUN_BG=1
fi

MODE="legacy"
if [ "$HAS_RUN_BG" -eq 1 ]; then
  MODE="run-bg"
  printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bash -c "bash \"$MONITOR_SH\" run-bg $MONITOR_FLAGS -o \"$CSV_PATH\" --stdout \"$MONITOR_STDOUT\"" || true
else
  printf '%s\n' "$SERVER_PASS" | sudo -S -p '' bash -c "nohup bash \"$MONITOR_SH\" run $MONITOR_FLAGS -o \"$CSV_PATH\" > \"$MONITOR_STDOUT\" 2>&1 & echo \$! > \"$PID_FILE\"" || true
fi

if ! printf '%s\n' "$SERVER_PASS" | sudo -S -p '' test -f "$PID_FILE"; then
  echo "ERROR: monitor pid file not found ($PID_FILE)" >&2
  exit 1
fi

PID="$(printf '%s\n' "$SERVER_PASS" | sudo -S -p '' cat "$PID_FILE" 2>/dev/null | tr -d '[:space:]')"
if ! [[ "$PID" =~ ^[0-9]+$ ]]; then
  echo "ERROR: invalid monitor pid '$PID'" >&2
  exit 1
fi
if ! printf '%s\n' "$SERVER_PASS" | sudo -S -p '' kill -0 "$PID" >/dev/null 2>&1; then
  echo "ERROR: monitor process not alive after start (PID: $PID)" >&2
  exit 1
fi

echo "__MONITOR_RESULT__ mode=$MODE pid=$PID"
REMOTE_EOF
  ) || ssh_rc=$?

  fallback_pid="$(echo "$ssh_out" | tr -d '\r' | sed -n 's/.*PID:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -n1)"
  parsed_pid="$(echo "$ssh_out" | tr -d '\r' | sed -n 's/.*__MONITOR_RESULT__ mode=[^ ]* pid=\([0-9][0-9]*\).*/\1/p' | tail -n1)"
  parsed_mode="$(echo "$ssh_out" | tr -d '\r' | sed -n 's/.*__MONITOR_RESULT__ mode=\([^ ]*\) pid=.*/\1/p' | tail -n1)"

  if [[ "$ssh_rc" -ne 0 ]]; then
    if [[ "$fallback_pid" =~ ^[0-9]+$ ]]; then
      CURRENT_MONITOR_PID="$fallback_pid"
      CURRENT_MONITOR_MODE="legacy"
      CURRENT_MONITOR_CSV="$csv_path"
      monitor_msg "   [⚠️] Monitor-Start meldete Fehler, Logger läuft aber (PID: $CURRENT_MONITOR_PID)."
      return 0
    fi
    monitor_msg "   [❌] Monitor-Start fehlgeschlagen."
    if [ -n "$ssh_out" ]; then
      monitor_msg "      Remote-Output:"
      echo "$ssh_out" | sed 's/^/      /'
    fi
    return 1
  fi

  CURRENT_MONITOR_PID="$parsed_pid"
  CURRENT_MONITOR_MODE="$parsed_mode"
  CURRENT_MONITOR_CSV="$csv_path"

  if ! [[ "$CURRENT_MONITOR_PID" =~ ^[0-9]+$ ]]; then
    if [[ "$fallback_pid" =~ ^[0-9]+$ ]]; then
      CURRENT_MONITOR_PID="$fallback_pid"
      CURRENT_MONITOR_MODE="legacy"
      monitor_msg "   [⚠️] Monitor-Result ohne Marker, nutze PID aus Output: $CURRENT_MONITOR_PID"
      return 0
    fi
    monitor_msg "   [❌] Monitor PID konnte nicht ermittelt werden."
    return 1
  fi

  monitor_msg "   [✅] Monitor läuft (mode=$CURRENT_MONITOR_MODE, PID=$CURRENT_MONITOR_PID)"
  return 0
}

stop_monitor_on_server() {
  if [ -z "$CURRENT_MONITOR_PID" ]; then
    return 0
  fi

  monitor_msg "   [🛑] Stoppe Monitor auf Server (PID: $CURRENT_MONITOR_PID) ..."
  sshpass -p "$SERVER_PASS" ssh "${SSH_OPTS[@]}" "$MONITOR_USER@$SERVER_IP" 'bash -s' -- \
    "$SERVER_PASS" \
    "$MONITOR_SCRIPT_INPUT" \
    "$CURRENT_MONITOR_MODE" \
    "$MONITOR_PID_FILE" \
    "$CURRENT_MONITOR_PID" <<'REMOTE_EOF'
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
REMOTE_EOF

  monitor_msg "   [✅] Monitor gestoppt."
  if [ -n "$CURRENT_MONITOR_CSV" ]; then
    monitor_msg "      CSV gespeichert unter: $CURRENT_MONITOR_CSV"
  fi
  CURRENT_MONITOR_PID=""
  CURRENT_MONITOR_MODE=""
  CURRENT_MONITOR_CSV=""
}

run_with_hook() {
  local workload="$1"
  local profile_file="$2"
  local log_file="$3"
  local pipe_path=""
  local fb_pid=0
  local fb_status=0
  local rc=0
  local hook_seen=0

  : > "$log_file"
  pipe_path="$(mktemp -u /tmp/filebench_suite_stream.XXXXXX.pipe)"
  mkfifo "$pipe_path"

  as_user "$BENCH_USER" filebench -f "$profile_file" > "$pipe_path" 2>&1 &
  fb_pid=$!

  set +e
  while IFS= read -r line; do
    echo "$line"
    printf '%s\n' "$line" >> "$log_file"

    if [[ "$hook_seen" -eq 0 ]] && [[ "$line" == *"Population and pre-allocation of filesets completed"* || "$line" == *"Pre-allocation of filesets completed"* ]]; then
      hook_seen=1
      monitor_msg "   [📍] Prealloc erreicht: drop caches + monitor start"
      drop_client_caches || rc=1
      start_monitor_on_server "$workload" || rc=1
    fi
  done < "$pipe_path"

  wait "$fb_pid"
  fb_status=$?
  set -e

  rm -f "$pipe_path" 2>/dev/null || true

  if [[ "$hook_seen" -eq 0 ]]; then
    monitor_msg "   [⚠️] Prealloc-Checkpoint nicht erkannt."
    rc=1
  fi

  if grep -Eiq "syntax error at|Cannot open file|buffer overflow detected" "$log_file"; then
    rc=1
  fi
  if grep -Eiq "WARNING! Run stopped early|NO VALID RESULTS|could not obtain a file|failed to create file" "$log_file"; then
    rc=1
  fi
  if [[ "$fb_status" -ne 0 ]]; then
    rc=$fb_status
  fi

  return "$rc"
}

cleanup_on_exit() {
  restore_aslr || true
  stop_monitor_on_server || true
}
trap cleanup_on_exit EXIT INT TERM

ensure_prereqs
ensure_nfs_mount

as_root mkdir -p "$TARGET_ROOT"
as_root mkdir -p "$LOG_DIR"

mapfile -t WORKLOADS < <(resolve_workloads "$WORKLOADS_RAW")
if [[ "${#WORKLOADS[@]}" -eq 0 ]]; then
  echo "❌ Keine Workloads gefunden."
  exit 1
fi

echo "=================================================="
echo " 🚀 Simple Filebench Suite"
echo "=================================================="
echo "Server IP:      $SERVER_IP"
echo "Profile Dir:    $PROFILE_DIR"
echo "Workloads:      ${WORKLOADS[*]}"
echo "Bench User:     $BENCH_USER"
echo "NFS Mount:      $CLIENT_MOUNT"
echo "Target Root:    $TARGET_ROOT"
echo "Monitor:        aktiviert (auto nach prealloc)"

FAILED=0

for wl in "${WORKLOADS[@]}"; do
  [[ -n "$wl" ]] || continue

  profile_file="$(resolve_profile_file "$wl")"
  if [[ -z "$profile_file" ]]; then
    echo "❌ Profil nicht gefunden für Workload '$wl'"
    FAILED=$((FAILED + 1))
    continue
  fi

  workload_dir="$(resolve_target_dir_from_profile "$profile_file" "$wl")"
  runtime="$(resolve_runtime_from_profile "$profile_file")"

  MONITOR_EVENT_LOG="$LOG_DIR/${wl}_monitor_$(date +%Y%m%d_%H%M%S).log"
  run_log="$LOG_DIR/${wl}_run_$(date +%Y%m%d_%H%M%S).log"

  as_root mkdir -p "$workload_dir"

  echo
  echo "--------------------------------------------------"
  echo " ▶ Workload: $wl"
  echo "   Profil:   $profile_file"
  echo "   Ziel:     $workload_dir"
  echo "   Runtime:  ${runtime}s"

  disable_aslr
  echo "   [🏁] Direktlauf (filebench -f Profil) ..."
  if ! run_with_hook "$wl" "$profile_file" "$run_log"; then
    echo "   [❌] Lauf fehlgeschlagen für '$wl'"
    FAILED=$((FAILED + 1))
  fi

  files_now="$(count_files "$workload_dir")"
  echo "   [📁] Dateien nach Lauf: $files_now"

  stop_monitor_on_server || true
  restore_aslr

done

echo
if [[ "$FAILED" -gt 0 ]]; then
  echo "⚠️  Suite beendet mit Fehlern: $FAILED"
  echo "Logs: $LOG_DIR"
  exit 1
fi

echo "✅ Suite abgeschlossen. Logs unter: $LOG_DIR"
