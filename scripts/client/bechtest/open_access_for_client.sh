#!/bin/bash
TARGET=$1 # Pfad auf dem Server, z.B. /srv/nfs/thesis_data/tmp
PASS=$2

# Das übergeordnete Verzeichnis ermitteln (wichtig für Löschrechte)
PARENT_DIR=$(dirname "$TARGET")

echo "--- Starte NFS-Rechte-Fix für $TARGET ---"

# 1. Rechte auf das Basis-Verzeichnis setzen
echo "[*] Setze Rechte auf Basis-Verzeichnis: $PARENT_DIR"
echo "$PASS" | sudo -S chown 1001:1001 "$PARENT_DIR"
echo "$PASS" | sudo -S chmod 777 "$PARENT_DIR"

# 2. Rechte auf den eigentlichen tmp-Ordner setzen
echo "[*] Setze Rechte auf Arbeits-Verzeichnis: $TARGET"
echo "$PASS" | sudo -S chown -R 1001:1001 "$TARGET"
echo "$PASS" | sudo -S chmod -R 777 "$TARGET"

# 3. Test-Datei anlegen (Prüfung)
echo "[*] Teste Schreibzugriff..."
if touch "$TARGET/test_write_perm.tmp" 2>/dev/null; then
    echo "   ✅ ERFOLG: Schreibrechte sind nun aktiv."
    rm "$TARGET/test_write_perm.tmp"
else
    echo "   ❌ FEHLER: Zugriff weiterhin verweigert."
fi