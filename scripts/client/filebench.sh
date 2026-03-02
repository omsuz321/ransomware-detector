#!/bin/bash
set -euo pipefail

# ==========================================
# Parameter-Logik & Standards
# ==========================================
TEST_DIR="/mnt/nfs/filebench"
RUNTIME="60"
THREADS="1"
TMP_FILES=()

register_tmp() { TMP_FILES+=("$1"); }
cleanup_tmp_files() {
    for f in "${TMP_FILES[@]:-}"; do
        [[ -n "${f:-}" ]] && rm -f "$f" 2>/dev/null || true
    done
}
trap cleanup_tmp_files EXIT TERM INT

run_as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

detect_bench_user() {
    # Optionales Override
    if [[ -n "${FILEBENCH_USER:-}" ]]; then
        echo "$FILEBENCH_USER"
        return
    fi

    # Wenn das Skript via sudo lief, nutze standardmäßig den ursprünglichen User.
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        echo "$SUDO_USER"
        return
    fi

    id -un
}

run_as_user() {
    local target_user="$1"
    shift

    local current_user
    current_user="$(id -un)"

    if [[ "$target_user" == "$current_user" ]]; then
        "$@"
        return
    fi

    if [[ "$target_user" == "root" ]]; then
        run_as_root "$@"
        return
    fi

    if [[ "$(id -u)" -eq 0 ]] && command -v runuser >/dev/null 2>&1; then
        runuser -u "$target_user" -- "$@"
    else
        sudo -u "$target_user" "$@"
    fi
}

can_write_target_as_user() {
    local target_user="$1"
    local target_dir="$2"
    local marker=".filebench_probe_$$.$RANDOM"

    run_as_user "$target_user" sh -c 'mkdir -p "$1" &&
        touch "$1/$2" &&
        rm -f "$1/$2"' _ "$target_dir" "$marker" >/dev/null 2>&1
}

repair_target_ownership() {
    local target_user="$1"
    local target_dir="$2"

    [[ "$target_user" == "root" ]] && return 0
    run_as_root chown -R "$target_user:$target_user" "$target_dir" >/dev/null 2>&1 || true
    run_as_root chmod -R u+rwX "$target_dir" >/dev/null 2>&1 || true
}

resolve_working_user() {
    local preferred_user="$1"
    local target_dir="$2"
    local current_user
    current_user="$(id -un)"

    local candidates=()
    candidates+=("$preferred_user")
    [[ "$current_user" != "$preferred_user" ]] && candidates+=("$current_user")
    [[ "root" != "$preferred_user" && "root" != "$current_user" ]] && candidates+=("root")

    local u
    for u in "${candidates[@]}"; do
        repair_target_ownership "$u" "$target_dir"
        if can_write_target_as_user "$u" "$target_dir"; then
            echo "$u"
            return 0
        fi
    done

    return 1
}

resolve_target_dir_from_profile() {
    local profile_file="$1"
    local from_profile
    local fallback

    from_profile="$(sed -nE 's/^[[:space:]]*set[[:space:]]+\$dir[[:space:]]*=[[:space:]]*([^[:space:]#]+).*$/\1/p' "$profile_file" | head -n1)"
    if [[ -n "$from_profile" ]]; then
        echo "$from_profile"
        return
    fi

    fallback="$TEST_DIR/$(basename "${profile_file%.f}")"
    echo "$fallback"
}

resolve_runtime_from_profile() {
    local profile_file="$1"
    local default_runtime="$2"
    local runtime_from_profile=""

    runtime_from_profile="$(sed -nE 's/^[[:space:]]*run[[:space:]]+([0-9]+)[[:space:]]*$/\1/p' "$profile_file" | head -n1)"
    if [[ -n "$runtime_from_profile" ]]; then
        echo "$runtime_from_profile"
        return
    fi

    if grep -qiE '^[[:space:]]*run[[:space:]]+\$runtime([[:space:]]|$)' "$profile_file"; then
        runtime_from_profile="$(sed -nE 's/^[[:space:]]*set[[:space:]]+\$runtime[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' "$profile_file" | head -n1)"
        if [[ -n "$runtime_from_profile" ]]; then
            echo "$runtime_from_profile"
            return
        fi
    fi

    echo "$default_runtime"
}

drop_client_caches() {
    run_as_root sh -c "sync; echo 3 > /proc/sys/vm/drop_caches"
}

build_fb_script_from_profile() {
    local mode="$1"          # prepare|run
    local profile_file="$2"
    local target_dir="$3"
    local runtime="$4"
    local out="$5"
    local reuse_mode="${6:-auto}"  # auto|reuse|no-reuse
    local profile_body
    local has_createfile=0

    profile_body="$(
        sed -E \
            -e '/^[[:space:]]*set[[:space:]]+\$dir[[:space:]]*=.*/Id' \
            -e '/^[[:space:]]*set[[:space:]]+\$nthreads[[:space:]]*=.*/Id' \
            -e '/^[[:space:]]*set[[:space:]]+\$threads[[:space:]]*=.*/Id' \
            -e '/^[[:space:]]*run([[:space:]]|$).*/Id' \
            "$profile_file"
    )"

    if printf '%s\n' "$profile_body" | grep -qiE '^[[:space:]]*flowop[[:space:]]+createfile([[:space:]]|$)'; then
        has_createfile=1
    fi

    if [[ "$mode" == "prepare" ]]; then
        # In prepare sollen Dateien wirklich angelegt werden.
        profile_body="$(
            printf '%s\n' "$profile_body" | sed -E '/^[[:space:]]*define[[:space:]]+fileset[[:space:]]/{
                s/prealloc[[:space:]]*=[[:space:]]*[^,[:space:]]+/prealloc=100/
                t
                s/$/,prealloc=100/
            }'
        )"
    elif [[ "$mode" == "run" && "$reuse_mode" == "reuse" ]]; then
        # Bei Run standardmäßig bestehende Prepare-Daten wiederverwenden.
        # Für createfile-Workloads muss es freie Slots geben, sonst endet der Run sofort.
        # Deshalb: bei createfile nfiles vergrößern und prealloc auf 0 setzen.
        local run_reuse_prealloc="100"
        if [[ "$has_createfile" -eq 1 ]]; then
            local nfiles_current nfiles_new
            nfiles_current="$(printf '%s\n' "$profile_body" | sed -nE 's/^[[:space:]]*set[[:space:]]+\$nfiles[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$/\1/p' | head -n1)"
            if [[ -n "$nfiles_current" && "$nfiles_current" -gt 0 ]]; then
                nfiles_new=$((nfiles_current * 2))
                profile_body="$(
                    printf '%s\n' "$profile_body" | awk -v new_nfiles="$nfiles_new" '
                        BEGIN { done=0 }
                        {
                            if (!done && $0 ~ /^[[:space:]]*set[[:space:]]+\$nfiles[[:space:]]*=/) {
                                print "set $nfiles=" new_nfiles
                                done=1
                            } else {
                                print
                            }
                        }
                    '
                )"
            fi
            run_reuse_prealloc="0"
        fi

        profile_body="$(
            printf '%s\n' "$profile_body" | sed -E '/^[[:space:]]*define[[:space:]]+fileset[[:space:]]/{
                s/prealloc[[:space:]]*=[[:space:]]*[^,[:space:]]+/prealloc='"$run_reuse_prealloc"'/
                t prealloc_done
                s/$/,prealloc='"$run_reuse_prealloc"'/
                :prealloc_done
                /(^|,)reuse([,[:space:]]|$)/! s/$/,reuse/
            }'
        )"
    elif [[ "$mode" == "run" && "$reuse_mode" == "no-reuse" ]]; then
        # Explizit ohne Reuse laufen.
        profile_body="$(
            printf '%s\n' "$profile_body" | sed -E '/^[[:space:]]*define[[:space:]]+fileset[[:space:]]/{
                s/(^|,)reuse([,[:space:]]|$)/\1/g
                s/,,+/,/g
                s/,[[:space:]]*$//
            }'
        )"
    fi

    {
        echo "set \$dir=$target_dir"
        echo "set \$nthreads=$THREADS"
        echo "set \$threads=$THREADS"
        printf '%s\n' "$profile_body"
        if [[ "$mode" == "prepare" ]]; then
            echo "create files"
        else
            echo "run $runtime"
        fi
    } > "$out"
}

show_help() {
    echo "Usage: sudo $0 <command> <profile> [target_dir] [runtime] [options]"
    echo ""
    echo "Commands:"
    echo "  install                  Installiert Filebench mit Fixes"
    echo "  prepare <file> [dir]     Erstellt NUR die Dateien für ein Profil"
    echo "                           (ohne [dir] wird set \$dir aus dem Profil genutzt)"
    echo "  run <file> [dir] [sec]   Startet Benchmark (Reuse aktiv, Cache-Drop aktiv)"
    echo "                           (ohne [dir]/[sec] werden Profilwerte genutzt)"
    echo "  uninstall                Entfernt Filebench restlos"
    echo ""
    echo "Beispiele:"
    echo "  sudo $0 prepare profiles/fileserver.f"
    echo "  sudo $0 run profiles/fileserver.f"
    echo "  sudo $0 run profiles/fileserver.f /mnt/nfs/filebench/fileserver 600"
}

if [[ $# -lt 1 ]]; then
    show_help
    exit 1
fi

COMMAND="$1"
shift || true

# ==========================================
# COMMAND: INSTALL
# ==========================================
if [[ "$COMMAND" == "install" ]]; then
    echo "=== Installiere Filebench mit Buffer-Overflow Fix ==="
    sudo apt-get update
    sudo apt-get install -y git build-essential flex bison automake autoconf libtool pkg-config

    if [ ! -d "filebench-src" ]; then
        git clone --depth 1 https://github.com/filebench/filebench.git filebench-src
    fi
    
    cd filebench-src
    echo "[+] Konfiguriere mit CFLAGS Fix..."
    libtoolize && aclocal && autoheader && automake --add-missing && autoconf
    ./configure CFLAGS="-O2 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 -fno-stack-protector"
    make -j"$(nproc)"
    sudo make install
    sudo ldconfig
    cd ..
    echo "=== Installation erfolgreich! ==="
    exit 0
fi

# ==========================================
# COMMAND: UNINSTALL
# ==========================================
if [[ "$COMMAND" == "uninstall" ]]; then
    echo "=== Entferne Filebench vom System ==="
    if [ -d "filebench-src" ]; then
        (cd filebench-src && sudo make uninstall 2>/dev/null || true)
        rm -rf filebench-src
    fi
    sudo apt-get remove --purge -y filebench 2>/dev/null || true
    sudo rm -f /usr/local/bin/filebench /usr/bin/filebench
    echo "=== Deinstallation abgeschlossen! ==="
    exit 0
fi

# ==========================================
# COMMAND: PREPARE (Daten erstellen)
# ==========================================
if [[ "$COMMAND" == "prepare" ]]; then
    PROFILE_FILE="${1:-}"
    TARGET_DIR=""
    BENCH_USER_PREFERRED="$(detect_bench_user)"
    BENCH_USER=""

    shift || true

    # Optionales positionsbasiertes Zielverzeichnis (abwärtskompatibel)
    if [[ $# -gt 0 && "$1" != --* ]]; then
        TARGET_DIR="$1"
        shift || true
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target-dir)
                [[ $# -lt 2 ]] && { echo "Fehler: --target-dir benötigt ein Argument."; exit 1; }
                TARGET_DIR="$2"
                shift 2
                ;;
            --threads)
                [[ $# -lt 2 ]] && { echo "Fehler: --threads benötigt ein Argument."; exit 1; }
                THREADS="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    if ! command -v filebench &> /dev/null; then
        echo "Fehler: Filebench ist nicht installiert."
        exit 1
    fi

    if [[ ! -f "$PROFILE_FILE" ]]; then
        echo "Fehler: Profil-Datei '$PROFILE_FILE' nicht gefunden!"
        exit 1
    fi

    if [[ -z "$TARGET_DIR" ]]; then
        TARGET_DIR="$(resolve_target_dir_from_profile "$PROFILE_FILE")"
    fi

    echo "=== PREPARE: Erstelle Daten ==="
    echo "[+] Profil: $PROFILE_FILE"
    echo "[+] Ziel:   $TARGET_DIR"
    run_as_user "$BENCH_USER_PREFERRED" mkdir -p "$TARGET_DIR" 2>/dev/null || run_as_root mkdir -p "$TARGET_DIR"
    if ! BENCH_USER="$(resolve_working_user "$BENCH_USER_PREFERRED" "$TARGET_DIR")"; then
        echo "Fehler: Kein geeigneter User mit Schreibrechten für '$TARGET_DIR' gefunden."
        exit 1
    fi
    echo "[+] User:   $BENCH_USER"

    # ASLR Workaround
    ORIG_ASLR=$(cat /proc/sys/kernel/randomize_va_space)
    sudo sh -c "echo 0 > /proc/sys/kernel/randomize_va_space"

    # Wir erzeugen ein temporäres WML-Script und führen es non-interaktiv aus.
    PREP_SCRIPT="$(mktemp /tmp/filebench_prepare.XXXXXX.f)"
    register_tmp "$PREP_SCRIPT"
    build_fb_script_from_profile "prepare" "$PROFILE_FILE" "$TARGET_DIR" "$RUNTIME" "$PREP_SCRIPT" "auto"
    run_as_root chmod 0644 "$PREP_SCRIPT"
    run_as_user "$BENCH_USER" filebench -f "$PREP_SCRIPT"

    CREATED_FILES=$(find "$TARGET_DIR" -type f 2>/dev/null | wc -l || true)
    echo "[+] Dateien (rekursiv): $CREATED_FILES"

    sudo sh -c "echo $ORIG_ASLR > /proc/sys/kernel/randomize_va_space"
    echo "=== Vorbereitung abgeschlossen! ==="
    exit 0
fi

# ==========================================
# COMMAND: RUN (Benchmark ausführen)
# ==========================================
if [[ "$COMMAND" == "run" ]]; then
    PROFILE_FILE="${1:-}"
    TARGET_DIR=""
    RUNTIME_VALUE=""
    BENCH_USER_PREFERRED="$(detect_bench_user)"
    BENCH_USER=""
    REUSE_MODE="reuse"
    DROP_CACHES=1

    shift || true

    # Optionale positionsbasierte Werte (abwärtskompatibel)
    if [[ $# -gt 0 && "$1" != --* ]]; then
        TARGET_DIR="$1"
        shift || true
    fi
    if [[ $# -gt 0 && "$1" != --* ]]; then
        RUNTIME_VALUE="$1"
        shift || true
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target-dir)
                [[ $# -lt 2 ]] && { echo "Fehler: --target-dir benötigt ein Argument."; exit 1; }
                TARGET_DIR="$2"
                shift 2
                ;;
            --runtime)
                [[ $# -lt 2 ]] && { echo "Fehler: --runtime benötigt ein Argument."; exit 1; }
                RUNTIME_VALUE="$2"
                shift 2
                ;;
            --threads)
                [[ $# -lt 2 ]] && { echo "Fehler: --threads benötigt ein Argument."; exit 1; }
                THREADS="$2"
                shift 2
                ;;
            --reuse)
                REUSE_MODE="reuse"
                shift
                ;;
            --no-reuse)
                REUSE_MODE="no-reuse"
                shift
                ;;
            --drop-caches)
                DROP_CACHES=1
                shift
                ;;
            --no-drop-caches)
                DROP_CACHES=0
                shift
                ;;
            --confirm-drop|--no-confirm-drop)
                # Nur Kompatibilität zur Suite; in diesem Skript keine Nachfrage.
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    if [[ ! -f "$PROFILE_FILE" ]]; then
        echo "Fehler: Profil-Datei '$PROFILE_FILE' nicht gefunden!"
        exit 1
    fi

    if [[ -z "$TARGET_DIR" ]]; then
        TARGET_DIR="$(resolve_target_dir_from_profile "$PROFILE_FILE")"
    fi
    if [[ -z "$RUNTIME_VALUE" || ! "$RUNTIME_VALUE" =~ ^[0-9]+$ ]]; then
        RUNTIME_VALUE="$(resolve_runtime_from_profile "$PROFILE_FILE" "$RUNTIME")"
    fi

    if ! command -v filebench &> /dev/null; then
        echo "Fehler: Filebench ist nicht installiert."
        exit 1
    fi

    echo "=== RUN: Starte Benchmark (Reuse aktiv) ==="
    echo "[+] Profil: $PROFILE_FILE"
    echo "[+] Ziel:   $TARGET_DIR"
    echo "[+] Dauer:  $RUNTIME_VALUE Sek."
    run_as_user "$BENCH_USER_PREFERRED" mkdir -p "$TARGET_DIR" 2>/dev/null || run_as_root mkdir -p "$TARGET_DIR"
    if ! BENCH_USER="$(resolve_working_user "$BENCH_USER_PREFERRED" "$TARGET_DIR")"; then
        echo "Fehler: Kein geeigneter User mit Schreibrechten für '$TARGET_DIR' gefunden."
        exit 1
    fi
    echo "[+] User:   $BENCH_USER"
    echo "[+] Reuse:  $REUSE_MODE"
    if [[ "$DROP_CACHES" -eq 1 ]]; then
        echo "[+] Cache:  drop vor Run"
    else
        echo "[+] Cache:  kein drop"
    fi

    # ASLR Workaround
    ORIG_ASLR=$(cat /proc/sys/kernel/randomize_va_space)
    sudo sh -c "echo 0 > /proc/sys/kernel/randomize_va_space"

    if [[ "$DROP_CACHES" -eq 1 ]]; then
        drop_client_caches
    fi

    # Wir erzeugen ein temporäres WML-Script und führen es non-interaktiv aus.
    # WICHTIG: Im Profil sollte beim fileset 'reuse' stehen, wenn vorhandene Dateien genutzt werden sollen.
    RUN_SCRIPT="$(mktemp /tmp/filebench_run.XXXXXX.f)"
    register_tmp "$RUN_SCRIPT"
    build_fb_script_from_profile "run" "$PROFILE_FILE" "$TARGET_DIR" "$RUNTIME_VALUE" "$RUN_SCRIPT" "$REUSE_MODE"
    run_as_root chmod 0644 "$RUN_SCRIPT"
    run_as_user "$BENCH_USER" filebench -f "$RUN_SCRIPT"

    sudo sh -c "echo $ORIG_ASLR > /proc/sys/kernel/randomize_va_space"
    exit 0
fi

show_help
