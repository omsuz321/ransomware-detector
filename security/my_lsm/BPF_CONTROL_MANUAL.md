# eBPF Manual Control – Raw Terminal Commands

Dieses Dokument beschreibt, wie man das `vfs_write.bpf.o` Programm **ohne das Shell-Script** baut, lädt, entlädt und den Status überprüft.

---

## 0. Dependencies installieren (falls notwendig)

```bash
sudo apt update
sudo apt install -y   clang llvm libbpf-dev bpftool make   linux-tools-$(uname -r) linux-headers-$(uname -r)
```

---

## 1. Build – eBPF Objektdatei erzeugen

Im Projektordner ausführen:

```bash
make clean-bpf
make bpf
```

Überprüfen, ob das Objekt erzeugt wurde:

```bash
ls vfs_write.bpf.o
```

---

## 2. Load – Programm in den Kernel laden & pinnen

```bash
sudo mkdir -p /sys/fs/bpf/vfs_write_logger

sudo bpftool prog load vfs_write.bpf.o   /sys/fs/bpf/vfs_write_logger/vfs_write autoattach
```

Nach erfolgreichem Laden läuft das Programm im Kernel.

---

## 3. Status – prüfen, ob das Programm aktiv ist

Einfacher Check:

```bash
if [ -d /sys/fs/bpf/vfs_write_logger ]; then
  echo "Status: GELADEN (Pinned)"
else
  echo "Status: NICHT GELADEN"
fi
```

Details anzeigen:

```bash
sudo bpftool prog show pinned /sys/fs/bpf/vfs_write_logger/vfs_write
```

---

## 4. Unload – Programm entladen

```bash
sudo rm -rf /sys/fs/bpf/vfs_write_logger
```

Optionale Restprüfung:

```bash
sudo bpftool prog show | grep vfs_write || echo "kein vfs_write Eintrag mehr"
```

---

## Hinweis

Wenn `bpftool` fehlt, können Status-Infos nicht angezeigt werden, das Laden selbst funktioniert aber nicht ohne `bpftool`.
