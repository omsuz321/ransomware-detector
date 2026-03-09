#!/bin/bash
# Simple fixed version of the pidstat functions

cat > /tmp/pidstat_functions.sh << 'EOF'
# Simple pidstat start function
start_cpu_monitoring_simple() {
    local mode="$1"
    local run_num="$2"
    local server_ip="$3"
    local server_pass="$4"
    
    local pidstat_log="/tmp/pidstat_nfsd_${mode}_run${run_num}.log"
    
    # Use printf to safely pass password via stdin
    echo "[*] Starting pidstat for nfsd..."
    
    # Run on remote server - single line approach
    sshpass -p "$server_pass" ssh -o StrictHostKeyChecking=no "server@$server_ip" \
        "printf '%s\n' '$server_pass' | sudo -S -p '' pkill -9 pidstat || true; sleep 0.5; \
         printf '%s\n' '$server_pass' | sudo -S -p '' nohup pidstat -u -t -h -l -C nfsd 1 > $pidstat_log 2>&1 & \
         sleep 1 && echo 'OK'" && echo "[+] Pidstat started" || echo "[-] Failed"
}

stop_cpu_monitoring_simple() {
    local server_ip="$1"
    local server_pass="$2"
    
    echo "[*] Stopping pidstat..."
    sshpass -p "$server_pass" ssh -o StrictHostKeyChecking=no "server@$server_ip" \
        "printf '%s\n' '$server_pass' | sudo -S -p '' pkill -9 pidstat || true" && echo "[+] Pidstat stopped"
}

EOF

cat /tmp/pidstat_functions.sh
