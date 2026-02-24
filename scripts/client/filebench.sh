#!/bin/bash
set -euo pipefail

# ==========================================
# Parameter-Logik & Standards
# ==========================================
TEST_DIR="/mnt/nfs"
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

build_fb_script_from_profile() {
    local mode="$1"          # prepare|run
    local profile_file="$2"
    local target_dir="$3"
    local runtime="$4"
    local out="$5"
    local profile_body

    profile_body="$(
        sed -E \
            -e '/^[[:space:]]*set[[:space:]]+\$dir[[:space:]]*=.*/Id' \
            -e '/^[[:space:]]*set[[:space:]]+\$nthreads[[:space:]]*=.*/Id' \
            -e '/^[[:space:]]*set[[:space:]]+\$threads[[:space:]]*=.*/Id' \
            -e '/^[[:space:]]*run([[:space:]]|$).*/Id' \
            "$profile_file"
    )"

    if [[ "$mode" == "prepare" ]]; then
        # In prepare sollen Dateien wirklich angelegt werden.
        profile_body="$(
            printf '%s\n' "$profile_body" | sed -E '/^[[:space:]]*define[[:space:]]+fileset[[:space:]]/{
                s/prealloc[[:space:]]*=[[:space:]]*[^,[:space:]]+/prealloc=100/
                t
                s/$/,prealloc=100/
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
    echo "Usage: sudo $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  install                  Installiert Filebench mit Fixes"
    echo "  prepare <file> <dir>     Erstellt NUR die Dateien für ein Profil"
    echo "  run <file> <dir> [sec]   Startet Benchmark (nutzt vorhandene Daten)"
    echo "  uninstall                Entfernt Filebench restlos"
    echo ""
    echo "Beispiele:"
    echo "  sudo $0 prepare tests/my.f /mnt/nfs    <- Erstellt Daten auf NFS"
    echo "  sudo $0 run tests/my.f /mnt/nfs 30     <- Startet Test für 30s"
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
    TARGET_DIR="${2:-$TEST_DIR}"

    if ! command -v filebench &> /dev/null; then
        echo "Fehler: Filebench ist nicht installiert."
        exit 1
    fi

    if [[ ! -f "$PROFILE_FILE" ]]; then
        echo "Fehler: Profil-Datei '$PROFILE_FILE' nicht gefunden!"
        exit 1
    fi

    echo "=== PREPARE: Erstelle Daten ==="
    echo "[+] Profil: $PROFILE_FILE"
    echo "[+] Ziel:   $TARGET_DIR"
    mkdir -p "$TARGET_DIR" 2>/dev/null || sudo mkdir -p "$TARGET_DIR"

    # ASLR Workaround
    ORIG_ASLR=$(cat /proc/sys/kernel/randomize_va_space)
    sudo sh -c "echo 0 > /proc/sys/kernel/randomize_va_space"

    # Wir erzeugen ein temporäres WML-Script und führen es non-interaktiv aus.
    PREP_SCRIPT="$(mktemp /tmp/filebench_prepare.XXXXXX.f)"
    register_tmp "$PREP_SCRIPT"
    build_fb_script_from_profile "prepare" "$PROFILE_FILE" "$TARGET_DIR" "$RUNTIME" "$PREP_SCRIPT"
    filebench -f "$PREP_SCRIPT"

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
    TARGET_DIR="${2:-$TEST_DIR}"
    RUNTIME="${3:-$RUNTIME}"

    if [[ ! -f "$PROFILE_FILE" ]]; then
        echo "Fehler: Profil-Datei '$PROFILE_FILE' nicht gefunden!"
        exit 1
    fi

    if ! command -v filebench &> /dev/null; then
        echo "Fehler: Filebench ist nicht installiert."
        exit 1
    fi

    echo "=== RUN: Starte Benchmark (Reuse aktiv) ==="
    echo "[+] Profil: $PROFILE_FILE"
    echo "[+] Ziel:   $TARGET_DIR"
    echo "[+] Dauer:  $RUNTIME Sek."

    # ASLR Workaround
    ORIG_ASLR=$(cat /proc/sys/kernel/randomize_va_space)
    sudo sh -c "echo 0 > /proc/sys/kernel/randomize_va_space"

    # Wir erzeugen ein temporäres WML-Script und führen es non-interaktiv aus.
    # WICHTIG: Im Profil sollte beim fileset 'reuse' stehen, wenn vorhandene Dateien genutzt werden sollen.
    RUN_SCRIPT="$(mktemp /tmp/filebench_run.XXXXXX.f)"
    register_tmp "$RUN_SCRIPT"
    build_fb_script_from_profile "run" "$PROFILE_FILE" "$TARGET_DIR" "$RUNTIME" "$RUN_SCRIPT"
    filebench -f "$RUN_SCRIPT"

    sudo sh -c "echo $ORIG_ASLR > /proc/sys/kernel/randomize_va_space"
    exit 0
fi

show_help
