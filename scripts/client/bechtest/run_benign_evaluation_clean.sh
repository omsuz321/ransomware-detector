#!/bin/bash

# ============================================================
# BENIGN EVALUATION HARNESS (Clean Version)
# Runs benign workloads (copy/compress/fio) with monitoring
# ============================================================

set -euo pipefail

# --- COLORS ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- LOGGING ---
log_info()    { echo -e " [INFO] $1"; }
log_success() { echo -e " ${GREEN}[OK]${NC}   $1"; }
log_error()   { echo -e " ${RED}[ERR]${NC}  $1"; }

# --- PARAMETERS ---
SERVER_IP="${1:-}"
CLIENT_MOUNT="${2:-/mnt/nfs}"
DURATION="${3:-60}"
SERVER_PASS="${4:-}"
WORKLOAD_TYPE="${5:-}"
WORKLOAD_ARG="${6:-all}"
REPEAT_COUNT="${7:-1}"

# --- PATHS ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/../results"

# --- RESOLVE CLIENT PATHS ---
if [[ "${CLIENT_MOUNT}" == */tmp* ]]; then
    CLIENT_TMP="${CLIENT_MOUNT%%/tmp*}/tmp"
elif [ "$(basename "${CLIENT_MOUNT%/}")" = "target" ]; then
    CLIENT_TMP="$(dirname "${CLIENT_MOUNT%/}")/tmp"
else
    CLIENT_TMP="${CLIENT_MOUNT%/}/tmp"
fi

if [[ "${CLIENT_MOUNT}" == */target* ]]; then
    CLIENT_TARGET="${CLIENT_MOUNT%/}"
elif [[ "${CLIENT_MOUNT}" == */tmp/* ]]; then
    CLIENT_TARGET="${CLIENT_MOUNT%%/tmp*}/target"
elif [ "$(basename "${CLIENT_MOUNT%/}")" = "tmp" ]; then
    CLIENT_TARGET="$(dirname "${CLIENT_MOUNT%/}")/target"
else
    CLIENT_TARGET="${CLIENT_MOUNT%/}/target"
fi

# --- VALIDATION ---
usage() {
    log_error "Missing required parameters."
    echo "Usage:"
    echo "  $0 SERVER_IP CLIENT_MOUNT DURATION SERVER_PASS WORKLOAD_TYPE [WORKLOAD_ARG] [REPEAT_COUNT]"
    echo ""
    echo "Examples:"
    echo "  $0 192.168.2.209 /mnt/nfs/target 300 1234 compress all 3"
    echo "  $0 192.168.2.209 /mnt/nfs/target 600 1234 fio target 2"
    echo "  $0 192.168.2.209 /mnt/nfs/target 300 1234 copy /home/user/data 1"
}

if [ -z "$SERVER_IP" ] || [ -z "$WORKLOAD_TYPE" ] || [ -z "$SERVER_PASS" ]; then
    usage
    exit 1
fi

if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [ "$DURATION" -le 0 ]; then
    log_error "DURATION must be a positive integer."
    exit 1
fi

if ! [[ "$REPEAT_COUNT" =~ ^[0-9]+$ ]] || [ "$REPEAT_COUNT" -le 0 ]; then
    log_error "REPEAT_COUNT must be a positive integer."
    exit 1
fi

mkdir -p "$RESULTS_DIR"

# --- WORKLOAD: COMPRESS (Client-side) ---
run_compress_workload() {
    local source_arg="$1"
    local run_id="$2"
    
    # Resolve source path
    local client_source_path
    if [[ "$source_arg" = /* ]]; then
        client_source_path="$source_arg"
    elif [ "$source_arg" = "all" ]; then
        if [ -d "$CLIENT_TARGET/all" ]; then
            client_source_path="$CLIENT_TARGET/all"
        elif [ -d "$CLIENT_TMP/all" ]; then
            client_source_path="$CLIENT_TMP/all"
        else
            log_error "compress source not found: $CLIENT_TARGET/all or $CLIENT_TMP/all"
            return 1
        fi
    else
        if [ -d "$CLIENT_TARGET/$source_arg" ]; then
            client_source_path="$CLIENT_TARGET/$source_arg"
        elif [ -d "$CLIENT_TMP/$source_arg" ]; then
            client_source_path="$CLIENT_TMP/$source_arg"
        else
            log_error "compress source not found: $SOURCE/$source_arg"
            return 1
        fi
    fi
    
    log_info "Source: $client_source_path"
    log_info "Output dir: $CLIENT_TMP"
    
    local iter=0
    local end_time=$((SECONDS + DURATION))
    
    while [ "$SECONDS" -lt "$end_time" ]; do
        local archive_path="$CLIENT_TMP/benign_compress_${run_id}_${iter}.tar"
        
        # Clean old archive
        if [ "$iter" -gt 0 ]; then
            rm -f "$CLIENT_TMP/benign_compress_${run_id}_$((iter - 1)).tar" 2>/dev/null || true
        fi
        
        # Create archive
        tar -cf "$archive_path" -C "$(dirname "$client_source_path")" "$(basename "$client_source_path")" 2>/dev/null
        
        if [ -f "$archive_path" ]; then
            local size=$(du -h "$archive_path" | cut -f1)
            log_info "  [iter $iter] $archive_path ($size)"
        else
            log_error "Failed to create archive"
            return 1
        fi
        
        iter=$((iter + 1))
    done
    
    log_success "Compress finished ($iter archives created)"
    return 0
}

# --- WORKLOAD: FIO ---
run_fio_workload() {
    local target_arg="$1"
    
    # Resolve target path
    local target_path
    if [[ "$target_arg" = /* ]]; then
        target_path="$target_arg"
    elif [ "$target_arg" = "target" ]; then
        target_path="$CLIENT_TARGET"
    elif [ "$target_arg" = "all" ]; then
        target_path="$CLIENT_TARGET/all"
    else
        target_path="$CLIENT_TARGET/$target_arg"
    fi
    
    if [ ! -d "$target_path" ]; then
        log_error "FIO target path not found: $target_path"
        return 1
    fi
    
    log_info "FIO target: $target_path"
    
    local out_file="/tmp/benign_fio_$$.txt"
    
    fio \
        --name=rw67_c33 \
        --directory="$target_path" \
        --rw=randrw \
        --rwmixread=67 \
        --buffer_compress_percentage=33 \
        --bsrange=4k-32k \
        --runtime="$DURATION" \
        --time_based \
        --overwrite=1 \
        --size=10G \
        --output="$out_file" &
    
    wait $! || rc=$?
    
    if [ -f "$out_file" ]; then
        log_success "FIO finished"
        rm -f "$out_file"
    fi
    
    return 0
}

# --- WORKLOAD: COPY ---
run_copy_workload() {
    local source_path="$1"
    local dest_path="$CLIENT_TMP/copy_work"
    
    mkdir -p "$dest_path"
    
    log_info "Source: $source_path"
    log_info "Dest: $dest_path"
    
    timeout "$DURATION" bash -c "
        while true; do
            cp -r '$source_path' '$dest_path/' 2>/dev/null || true
        done
    " || rc=$?
    
    if [ $rc -eq 124 ]; then
        log_success "Copy finished (timeout reached)"
        return 0
    fi
    
    return 0
}

# --- MAIN ---
main() {
    echo -e "\n${BLUE}============================================${NC}"
    echo -e "${BLUE} BENIGN EVALUATION HARNESS${NC}"
    echo -e "${BLUE}============================================${NC}\n"
    
    log_info "WORKLOAD_TYPE=$WORKLOAD_TYPE"
    log_info "WORKLOAD_ARG=$WORKLOAD_ARG"
    log_info "DURATION=${DURATION}s, REPEAT_COUNT=$REPEAT_COUNT"
    log_info "CLIENT_TMP=$CLIENT_TMP"
    log_info "CLIENT_TARGET=$CLIENT_TARGET"
    echo ""
    
    for repeat in $(seq 1 "$REPEAT_COUNT"); do
        echo -e "\n${YELLOW}---- Run $repeat/$REPEAT_COUNT ($WORKLOAD_TYPE) ----${NC}"
        
        case "$WORKLOAD_TYPE" in
            compress)
                run_compress_workload "$WORKLOAD_ARG" "compress_rep$(printf '%03d' $repeat)_$$" || true
                ;;
            fio)
                run_fio_workload "$WORKLOAD_ARG" || true
                ;;
            copy)
                run_copy_workload "$WORKLOAD_ARG" || true
                ;;
            *)
                log_error "Unknown workload type: $WORKLOAD_TYPE"
                exit 1
                ;;
        esac
        
        if [ "$repeat" -lt "$REPEAT_COUNT" ]; then
            sleep 2
        fi
    done
    
    echo -e "\n${GREEN}Done.${NC}"
    log_info "Results saved to: $RESULTS_DIR/"
}

main "$@"
