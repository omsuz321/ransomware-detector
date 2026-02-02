#!/bin/bash

# ==========================================
# NFS CLIENT SETUP (Connect & Mount)
# ==========================================

# --- KONFIGURATION ---
# Das muss exakt dem Pfad auf dem Server entsprechen!
REMOTE_EXPORT_DIR="/srv/nfs/thesis_data"

# Wo soll der Ordner auf DIESEM PC (Client) erscheinen?
LOCAL_MOUNT_POINT="/mnt/thesis_data_client"

# --- FARBEN ---
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function log_info()   { echo -e " ℹ️  $1"; }
function log_success(){ echo -e " ✅ ${GREEN}$1${NC}"; }
function log_warn()   { echo -e " ⚠️  ${YELLOW}$1${NC}"; }
function log_error()  { echo -e " ❌ ${RED}$1${NC}"; }

# 0. Root-Check
if [ "$EUID" -ne 0 ]; then
  log_error "Bitte mit sudo starten: sudo ./setup_client.sh"
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
    apt-get update -qq
    apt-get install -y "$PACKAGE" > /dev/null
    
    if dpkg -s "$PACKAGE" >/dev/null 2>&1; then
        log_success "Installation erfolgreich."
    else
        log_error "Kritischer Fehler: Konnte '$PACKAGE' nicht installieren."
        exit 1
    fi
fi

# ------------------------------------------
# SCHRITT 2: Server IP abfragen
# ------------------------------------------
echo -e "\n${BLUE}### Schritt 2: Server Verbindung ###${NC}"

# Wir fragen den User nach der IP, da diese variabel ist
echo -n "👉 Bitte gib die IP-Adresse des NFS-Servers ein: "
read SERVER_IP

if [ -z "$SERVER_IP" ]; then
    log_error "Keine IP eingegeben. Abbruch."
    exit 1
fi

log_info "Prüfe Verbindung zu $SERVER_IP ..."

# Kurzer Ping-Check
if ping -c 1 -W 2 "$SERVER_IP" > /dev/null; then
    log_success "Server ist erreichbar (Ping OK)."
else
    log_error "Server unter $SERVER_IP antwortet nicht. Ist die IP richtig oder die Firewall an?"
    exit 1
fi

# Optional: Prüfen, ob der Server den Export überhaupt anbietet
log_info "Frage Export-Liste vom Server ab..."
if showmount -e "$SERVER_IP" | grep -q "$REMOTE_EXPORT_DIR"; then
    log_success "Server bietet den Ordner '$REMOTE_EXPORT_DIR' an."
else
    log_error "Server bietet den Ordner NICHT an. Prüfe 'cat /etc/exports' auf dem Server."
    exit 1
fi

# ------------------------------------------
# SCHRITT 3: Mounten
# ------------------------------------------
echo -e "\n${BLUE}### Schritt 3: Ordner mounten ###${NC}"

# Verzeichnis erstellen, falls nicht da
if [ ! -d "$LOCAL_MOUNT_POINT" ]; then
    mkdir -p "$LOCAL_MOUNT_POINT"
    log_info "Lokaler Ordner erstellt: $LOCAL_MOUNT_POINT"
fi

# Prüfen, ob schon was gemountet ist, um doppeltes Mounten zu verhindern
if mountpoint -q "$LOCAL_MOUNT_POINT"; then
    log_warn "Es ist bereits etwas auf $LOCAL_MOUNT_POINT gemountet. Versuche Remount..."
    umount "$LOCAL_MOUNT_POINT"
fi

# Der eigentliche Mount-Befehl
log_info "Mounte $SERVER_IP:$REMOTE_EXPORT_DIR nach $LOCAL_MOUNT_POINT ..."

mount -t nfs "$SERVER_IP:$REMOTE_EXPORT_DIR" "$LOCAL_MOUNT_POINT"

if [ $? -eq 0 ]; then
    log_success "Mount erfolgreich!"
else
    log_error "Mount fehlgeschlagen."
    exit 1
fi

# ------------------------------------------
# SCHRITT 4: Schreibtest (Write Check)
# ------------------------------------------
echo -e "\n${BLUE}### Schritt 4: Schreibtest ###${NC}"

TESTFILE="$LOCAL_MOUNT_POINT/client_test_$(date +%s).txt"

# Wir versuchen eine Datei zu schreiben
if echo "Hallo vom Client" > "$TESTFILE"; then
    log_success "Schreibzugriff OK: Datei '$TESTFILE' wurde erstellt."
    
    # Aufräumen (optional, wir lassen sie mal da, damit du sie am Server siehst)
    # rm "$TESTFILE"
else
    log_error "Schreibzugriff FEHLGESCHLAGEN. Prüfe Berechtigungen auf dem Server (chmod 777?)."
fi

echo -e "\n${BLUE}=== Fertig! Deine Daten sind unter $LOCAL_MOUNT_POINT ===${NC}"