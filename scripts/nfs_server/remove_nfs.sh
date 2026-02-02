#!/bin/bash

# ==========================================
# NFS ENTFERNEN (Mit Flag-Steuerung)
# ==========================================
# Benutzung:
#   sudo ./remove_nfs_flag.sh       -> Entfernt Konfig, behält Pakete.
#   sudo ./remove_nfs_flag.sh -p    -> Entfernt Konfig UND deinstalliert Pakete.

# --- KONFIGURATION ---
SHARE_DIR="/srv/nfs/thesis_data"
PACKAGE="nfs-kernel-server"

# Variable für Paket-Löschung (Standard: Nein)
REMOVE_PACKAGES=false

# --- ARGUMENTE PRÜFEN ---
# Wir schauen, ob "-p" übergeben wurde
if [[ "$1" == "-p" ]]; then
    REMOVE_PACKAGES=true
fi

# --- FARBEN ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info()    { echo -e " ℹ️  $1"; }
log_success() { echo -e " ✅ ${GREEN}$1${NC}"; }
log_warn()    { echo -e " ⚠️  ${YELLOW}$1${NC}"; }

# 0. Root-Check
if [ "$EUID" -ne 0 ]; then
  echo "Bitte als root ausführen: sudo ./remove_nfs_flag.sh [-p]"
  exit 1
fi

echo -e "${BLUE}=== Starte Deinstallation ===${NC}"
if [ "$REMOVE_PACKAGES" = true ]; then
    echo -e "${RED}-> Modus: ALLES LÖSCHEN (Konfig + Pakete)${NC}"
else
    echo -e "${GREEN}-> Modus: SOFT REMOVE (Nur Konfig, Pakete bleiben)${NC}"
fi

# ------------------------------------------
# SCHRITT 1: Dienste stoppen
# ------------------------------------------
echo -e "\n${BLUE}### 1. Stoppe Dienste ###${NC}"

if systemctl is-active --quiet "$PACKAGE"; then
    systemctl stop "$PACKAGE"
    # Wir disablen den Service nur, wenn wir die Pakete auch löschen wollen.
    # Wenn die Pakete bleiben, soll der User den Dienst vielleicht später wieder starten können.
    # Aber um sicher zu gehen, dass der Export weg ist, stoppen wir ihn hier immer.
    if [ "$REMOVE_PACKAGES" = true ]; then
        systemctl disable "$PACKAGE"
        log_success "Dienst gestoppt und deaktiviert."
    else
        log_success "Dienst vorübergehend gestoppt."
    fi
else
    log_info "Dienst läuft bereits nicht mehr."
fi

# ------------------------------------------
# SCHRITT 2: Konfiguration bereinigen
# ------------------------------------------
echo -e "\n${BLUE}### 2. Bereinige /etc/exports ###${NC}"
EXPORT_FILE="/etc/exports"

if [ -f "$EXPORT_FILE" ]; then
    # Backup
    cp "$EXPORT_FILE" "${EXPORT_FILE}.bak_$(date +%s)"
    
    if grep -qF "$SHARE_DIR" "$EXPORT_FILE"; then
        sed -i "\#$SHARE_DIR#d" "$EXPORT_FILE"
        log_success "Eintrag für $SHARE_DIR entfernt."
        
        # Falls Pakete bleiben, müssen wir exportfs aktualisieren, damit die Änderung greift
        if [ "$REMOVE_PACKAGES" = false ]; then
            exportfs -ra
            log_info "Export-Liste aktualisiert (exportfs -ra)."
        fi
    else
        log_info "Kein Eintrag gefunden."
    fi
fi

# ------------------------------------------
# SCHRITT 3: Software entfernen (NUR WENN FLAG GESETZT)
# ------------------------------------------
echo -e "\n${BLUE}### 3. Software-Status ###${NC}"

if [ "$REMOVE_PACKAGES" = true ]; then
    log_warn "Flag -p gesetzt: Entferne Pakete..."
    
    if dpkg -s "$PACKAGE" >/dev/null 2>&1; then
        apt-get purge -y "$PACKAGE"
        apt-get autoremove -y > /dev/null
        log_success "Pakete vollständig entfernt."
    else
        log_info "Pakete waren gar nicht installiert."
    fi
else
    log_info "Flag -p NICHT gesetzt. Die Software ($PACKAGE) bleibt installiert."
    log_info "Um sie zu löschen, nutze: sudo ./remove_nfs_flag.sh -p"
fi

# ------------------------------------------
# SCHRITT 4: Daten löschen (Immer fragen)
# ------------------------------------------
echo -e "\n${BLUE}### 4. Daten-Ordner ($SHARE_DIR) ###${NC}"

if [ -d "$SHARE_DIR" ]; then
    # Hier fragen wir trotzdem sicherheitshalber nach, da Daten wertvoll sein können.
    echo -e "${RED}ACHTUNG: Soll der Ordner '$SHARE_DIR' gelöscht werden?${NC}"
    read -p "Löschen? (j/n): " confirm
    
    if [[ "$confirm" == "j" || "$confirm" == "J" ]]; then
        rm -rf "$SHARE_DIR"
        rmdir /srv/nfs 2>/dev/null
        log_success "Ordner gelöscht."
    else
        log_info "Ordner behalten."
    fi
else
    log_info "Ordner existiert nicht mehr."
fi

echo -e "\n${BLUE}=== Fertig ===${NC}"