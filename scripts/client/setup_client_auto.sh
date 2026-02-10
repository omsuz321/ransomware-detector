#!/bin/bash

# ==========================================
# NFS CLIENT SETUP (Optimiert für Thesis-Umgebung)
# ==========================================

# --- KONFIGURATION ---
REMOTE_EXPORT_DIR="/srv/nfs/thesis_data"
LOCAL_MOUNT_POINT="/mnt/thesis_data_client"

# --- FARBEN ---
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

function log_info()   { echo -e " ℹ️  $1"; }
function log_success(){ echo -e " ✅ ${GREEN}$1${NC}"; }
function log_warn()   { echo -e " ⚠️  ${YELLOW}$1${NC}"; }
function log_error()  { echo -e " ❌ ${RED}$1${NC}"; }

# 0. Root-Check
if [ "$EUID" -ne 0 ]; then
  log_error "Bitte mit sudo starten: sudo $0"
  exit 1
fi

echo -e "${BLUE}=== Starte Client Setup ===${NC}"

# ------------------------------------------
# SCHRITT 1: Software installieren
# ------------------------------------------
echo -e "\n${BLUE}### Schritt 1: NFS-Client Software prüfen ###${NC}"
PACKAGE="nfs-common"

if dpkg -s "$PACKAGE" >/dev/null 2>&1; then
    log_success "Paket '$PACKAGE' ist bereits installiert."
else
    log_info "Paket '$PACKAGE' fehlt. Installation wird gestartet..."
    apt-get update -qq && apt-get install -y "$PACKAGE" > /dev/null
    log_success "Installation abgeschlossen."
fi

# ------------------------------------------
# SCHRITT 2: Server IP abfragen
# ------------------------------------------
echo -e "\n${BLUE}### Schritt 2: Server Verbindung ###${NC}"
echo -n "👉 Bitte gib die IP-Adresse des NFS-Servers ein: "
read SERVER_IP

if [ -z "$SERVER_IP" ]; then
    log_error "Keine IP eingegeben. Abbruch."
    exit 1
fi

# Verbindungstest
if ping -c 1 -W 2 "$SERVER_IP" > /dev/null; then
    log_success "Server $SERVER_IP erreichbar."
else
    log_error "Server $SERVER_IP antwortet nicht."
    exit 1
fi

# ------------------------------------------
# SCHRITT 3: Mount-Punkt bereinigen (ROBUST)
# ------------------------------------------
echo -e "\n${BLUE}### Schritt 3: Ordner vorbereiten & aufräumen ###${NC}"

if [ ! -d "$LOCAL_MOUNT_POINT" ]; then
    mkdir -p "$LOCAL_MOUNT_POINT"
    log_info "Lokaler Ordner erstellt: $LOCAL_MOUNT_POINT"
fi

# Falls gemountet, erzwinge das Aushängen
if mountpoint -q "$LOCAL_MOUNT_POINT"; then
    log_warn "Mount-Punkt ist beschäftigt/aktiv. Versuche Bereinigung..."
    
    # 1. Versuch: Normal (falls sauber möglich)
    umount "$LOCAL_MOUNT_POINT" 2>/dev/null
    
    # 2. Versuch: Force & Lazy (löst hängende Kernel-Handles)
    if mountpoint -q "$LOCAL_MOUNT_POINT"; then
        log_warn "Einfaches Umount fehlgeschlagen. Nutze Lazy Umount (-l)..."
        umount -f -l "$LOCAL_MOUNT_POINT"
        sleep 1 # Kurze Pause für den Kernel
    fi
    log_success "Alte Mount-Referenzen entfernt."
fi

# ------------------------------------------
# SCHRITT 4: Mounten
# ------------------------------------------
echo -e "\n${BLUE}### Schritt 4: Neu mounten ###${NC}"

log_info "Mounte $SERVER_IP:$REMOTE_EXPORT_DIR ..."
mount -t nfs -o soft,intr "$SERVER_IP:$REMOTE_EXPORT_DIR" "$LOCAL_MOUNT_POINT"

if [ $? -eq 0 ]; then
    log_success "Mount erfolgreich!"
else
    log_error "Mount fehlgeschlagen. Prüfe Server-Exports."
    exit 1
fi

# ------------------------------------------
# SCHRITT 5: Schreibtest
# ------------------------------------------
echo -e "\n${BLUE}### Schritt 5: Schreibtest ###${NC}"
TESTFILE="$LOCAL_MOUNT_POINT/client_test_$(date +%s).txt"

if echo "Test vom $(hostname)" > "$TESTFILE"; then
    log_success "Schreibzugriff OK: $TESTFILE"
    rm "$TESTFILE"
else
    log_error "Schreibzugriff FEHLGESCHLAGEN. Prüfe Server-Rechte (chmod 777)."
fi

echo -e "\n${BLUE}=== Fertig! ===${NC}"