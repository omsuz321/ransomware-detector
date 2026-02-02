#!/bin/bash

# ==========================================
# NFS SERVER SETUP (Auto-Install & Config)
# ==========================================

# --- KONFIGURATION ---
SHARE_DIR="/srv/nfs/thesis_data"
TEST_MOUNT_DIR="/mnt/test_self"
# Export-Optionen: Alle IPs (*), Lesen/Schreiben (rw), Sofort speichern (sync)
EXPORT_OPTS="*(rw,sync,no_subtree_check)"

# --- FARBEN ---
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

function log_info()   { echo -e " ℹ️  $1"; }
function log_success(){ echo -e " ✅ ${GREEN}$1${NC}"; }
function log_error()  { echo -e " ❌ ${RED}$1${NC}"; }

# 0. Root-Check
if [ "$EUID" -ne 0 ]; then
  log_error "Bitte mit sudo starten: sudo ./setup_server_auto.sh"
  exit 1
fi

echo -e "${BLUE}=== Starte Server Setup ===${NC}"

# ------------------------------------------
# SCHRITT 1: Pakete prüfen & installieren
# ------------------------------------------
echo -e "\n${BLUE}### Schritt 1: Software-Check ###${NC}"

# Wir prüfen, ob das Hauptpaket 'nfs-kernel-server' installiert ist
PACKAGE="nfs-kernel-server"

if dpkg -s "$PACKAGE" >/dev/null 2>&1; then
    log_success "Paket '$PACKAGE' ist bereits installiert."
else
    log_info "Paket '$PACKAGE' fehlt. Installation wird gestartet..."
    
    # Update der Paketlisten (wichtig, damit er das Paket findet)
    apt-get update -qq
    
    # Installation
    apt-get install -y "$PACKAGE" > /dev/null
    
    # Erneute Prüfung nach Installation
    if dpkg -s "$PACKAGE" >/dev/null 2>&1; then
        log_success "Installation von '$PACKAGE' erfolgreich abgeschlossen."
    else
        log_error "Kritischer Fehler: Konnte '$PACKAGE' nicht installieren."
        exit 1
    fi
fi

# ------------------------------------------
# SCHRITT 2: Ordner erstellen & Rechte
# ------------------------------------------
echo -e "\n${BLUE}### Schritt 2: Ordner vorbereiten ###${NC}"

if [ ! -d "$SHARE_DIR" ]; then
    mkdir -p "$SHARE_DIR"
    log_success "Ordner erstellt: $SHARE_DIR"
else
    log_info "Ordner existiert bereits."
fi

# Rechte setzen (777 für Testzwecke)
chmod 777 "$SHARE_DIR"
log_success "Rechte auf 777 gesetzt."

# ------------------------------------------
# SCHRITT 3: Export konfigurieren (/etc/exports)
# ------------------------------------------
echo -e "\n${BLUE}### Schritt 3: Export-Datei bearbeiten ###${NC}"

EXPORT_FILE="/etc/exports"
ENTRY="$SHARE_DIR $EXPORT_OPTS"

# Backup erstellen
cp "$EXPORT_FILE" "${EXPORT_FILE}.bak_$(date +%s)"

# Wir prüfen mit grep, ob der Pfad schon in der Datei steht
if grep -qF "$SHARE_DIR" "$EXPORT_FILE"; then
    log_info "Eintrag existiert bereits in $EXPORT_FILE. Überspringe."
else
    echo "$ENTRY" >> "$EXPORT_FILE"
    log_success "Eintrag hinzugefügt: $ENTRY"
fi

# ------------------------------------------
# SCHRITT 4: Dienst neu starten
# ------------------------------------------
echo -e "\n${BLUE}### Schritt 4: Server neu starten ###${NC}"

log_info "Lese Exports neu ein..."
exportfs -ra

log_info "Starte Dienst neu..."
systemctl restart nfs-kernel-server

if systemctl is-active --quiet nfs-kernel-server; then
    log_success "Server läuft aktiv!"
else
    log_error "Server läuft NICHT. Bitte 'systemctl status nfs-kernel-server' prüfen."
    exit 1
fi

# ------------------------------------------
# SCHRITT 5: Selbsttest
# ------------------------------------------
echo -e "\n${BLUE}### Schritt 5: Selbsttest (Server mountet sich selbst) ###${NC}"

# Alten Test-Ordner aufräumen
umount "$TEST_MOUNT_DIR" 2>/dev/null
mkdir -p "$TEST_MOUNT_DIR"

# Versuch zu mounten
mount -t nfs localhost:"$SHARE_DIR" "$TEST_MOUNT_DIR"

if mountpoint -q "$TEST_MOUNT_DIR"; then
    log_success "TEST OK: Server funktioniert einwandfrei."
    echo "   (Habe den Test-Ordner wieder ausgehängt, um sauber zu bleiben)"
    umount "$TEST_MOUNT_DIR"
    rmdir "$TEST_MOUNT_DIR"
else
    log_error "TEST FEHLGESCHLAGEN: Konnte lokalen Mount nicht durchführen."
fi

echo -e "\n${BLUE}=== Fertig ===${NC}"