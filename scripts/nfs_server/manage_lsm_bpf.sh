#!/bin/bash
set -euo pipefail

# Toggle bpf in the kernel LSM list inside /etc/default/grub.
# Usage:
#   sudo ./manage_lsm_bpf.sh --enable   # set lsm=lockdown,...,bpf
#   sudo ./manage_lsm_bpf.sh --disable  # remove bpf from existing lsm list
# The script offers to run update-grub and to reboot (both require confirmation).

GRUB_FILE="/etc/default/grub"
CMDLINE_VAR="GRUB_CMDLINE_LINUX_DEFAULT"
DESIRED_LSM="lockdown,capability,landlock,yama,apparmor,ima,evm,bpf"

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
err()  { echo "[ERROR] $*" >&2; }

usage() {
    cat <<EOF
Usage: $0 --enable|--disable
  --enable   set lsm=${DESIRED_LSM}
  --disable  remove bpf from the current lsm list
EOF
}

if [[ ${EUID:-0} -ne 0 ]]; then
    err "Run as root (sudo)."
    exit 1
fi

if [[ ! -f "$GRUB_FILE" ]]; then
    err "Cannot find $GRUB_FILE. Adjust GRUB_FILE in the script if your distro stores it elsewhere."
    exit 1
fi

if [[ $# -ne 1 ]]; then
    usage
    exit 1
fi

MODE="$1"
if [[ "$MODE" != "--enable" && "$MODE" != "--disable" ]]; then
    usage
    exit 1
fi

read_cmdline() {
    local line cmd
    line=$(grep -E "^${CMDLINE_VAR}=" "$GRUB_FILE" || true)
    if [[ -z "$line" ]]; then
        echo ""
        return
    fi
    cmd=${line#${CMDLINE_VAR}=}
    cmd=${cmd#\"}
    cmd=${cmd%\"}
    echo "$cmd"
}

write_cmdline() {
    local new_cmdline="$1" tmp
    tmp=$(mktemp)
    awk -v var="$CMDLINE_VAR" -v new="$new_cmdline" \
        'BEGIN{found=0} {if ($0 ~ "^"var"=") {printf "%s=\"%s\"\n", var, new; found=1; next} print} END{if(!found) printf "%s=\"%s\"\n", var, new}' \
        "$GRUB_FILE" > "$tmp"
    mv "$tmp" "$GRUB_FILE"
}

backup_file() {
    local stamp
    stamp=$(date +%Y%m%d-%H%M%S)
    cp "$GRUB_FILE" "${GRUB_FILE}.bak_${stamp}"
    log "Backup created: ${GRUB_FILE}.bak_${stamp}"
}

trim_spaces() {
    echo "$1" | sed -e 's/^ *//' -e 's/  */ /g' -e 's/ *$//'
}

cmdline=$(read_cmdline)
lsm_token=""
if echo "$cmdline" | grep -q 'lsm='; then
    lsm_token=$(echo "$cmdline" | grep -o 'lsm=[^ ]*' | head -n1)
fi

if [[ "$MODE" == "--enable" ]]; then
    if [[ -n "$lsm_token" ]]; then
        new_cmdline=${cmdline/$lsm_token/lsm=$DESIRED_LSM}
    else
        new_cmdline="$cmdline lsm=$DESIRED_LSM"
    fi
    new_cmdline=$(trim_spaces "$new_cmdline")
    action_msg="Set lsm to $DESIRED_LSM"
else
    if [[ -z "$lsm_token" ]]; then
        warn "No lsm= entry found; nothing to remove."
        exit 0
    fi
    current_list=${lsm_token#lsm=}
    IFS=',' read -ra parts <<< "$current_list"
    keep=()
    for p in "${parts[@]}"; do
        if [[ "${p,,}" == "bpf" ]]; then
            continue
        fi
        keep+=("$p")
    done
    if [[ ${#keep[@]} -eq 0 ]]; then
        new_cmdline=${cmdline/$lsm_token/}
    else
        new_lsm=$(printf "%s," "${keep[@]}")
        new_lsm=${new_lsm%,}
        new_cmdline=${cmdline/$lsm_token/lsm=$new_lsm}
    fi
    new_cmdline=$(trim_spaces "$new_cmdline")
    action_msg="Removed bpf from lsm list"
fi

log "Current cmdline: ${cmdline:-"<empty>"}"
log "New cmdline:     ${new_cmdline:-"<empty>"}"

backup_file
write_cmdline "$new_cmdline"
log "$action_msg and wrote $GRUB_FILE"

read -r -p "Run update-grub now? [y/N]: " answer
if [[ "$answer" =~ ^[Yy]$ ]]; then
    if command -v update-grub >/dev/null 2>&1; then
        log "Running update-grub..."
        update-grub
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        log "Running grub-mkconfig..."
        grub-mkconfig -o /boot/grub/grub.cfg
    else
        warn "No update-grub or grub-mkconfig found; please update bootloader manually."
    fi
else
    log "Skipped bootloader update. Changes take effect after you update bootloader and reboot."
fi

read -r -p "Reboot now to apply? [y/N]: " answer
if [[ "$answer" =~ ^[Yy]$ ]]; then
    log "Rebooting..."
    reboot
else
    log "Reboot skipped. Remember to reboot for changes to take effect."
fi
