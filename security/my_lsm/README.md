# BPF VFS Write Monitor

eBPF-basierter Monitor für VFS-Schreiboperationen im Linux Kernel.

## 🚀 Quick Start

```bash
# 1. Kompilieren
sudo ./bpf build

# 2. System prüfen
sudo ./bpf check

# 3. Monitor starten
sudo ./bpf start

# 4. Test ausführen (in neuem Terminal)
./bpf test

# 5. Logs beobachten
sudo ./bpf logs

# 6. Stoppen
sudo ./bpf stop
```

## 📋 Verfügbare Befehle

### Build & Compile
```bash
./bpf build              # Alles kompilieren
./bpf compile-bpf        # Nur BPF-Code kompilieren
./bpf gen-skeleton       # Skeleton-Header generieren
./bpf compile-user       # Nur Userspace-Programm kompilieren
./bpf clean              # Build-Artefakte löschen
```

### Runtime Management
```bash
sudo ./bpf start         # Monitor im Hintergrund starten
sudo ./bpf stop          # Monitor stoppen
sudo ./bpf restart       # Monitor neu starten
sudo ./bpf watch         # Monitor im Vordergrund (für Debugging)
sudo ./bpf status        # Status & Informationen anzeigen
sudo ./bpf logs          # Live-Logs anzeigen
```

### Development & Debug
```bash
sudo ./bpf trace         # Kernel Trace Pipe (Live Events)
sudo ./bpf debug         # Detaillierte Debug-Informationen
sudo ./bpf list-progs    # Alle BPF Programme auflisten
sudo ./bpf list-maps     # Alle BPF Maps auflisten
./bpf test               # Test-Script ausführen
./bpf check              # System-Voraussetzungen prüfen
```

## 📁 Projekt-Struktur

```
my_lsm/
├── bpf                      # ⭐ Zentrales Management-Script
├── Makefile                 # Build-System
├── src/
│   ├── vfs_write.bpf.c     # BPF Kernel-Programm
│   └── loader.c            # Userspace Loader
├── include/
│   ├── common.h            # Gemeinsame Definitionen
│   ├── vmlinux.h           # Kernel Type Definitions (BTF)
│   └── vfs_write.skel.h    # Generiertes Skeleton (nach build)
└── scripts/
    ├── monitor.sh          # Alternative: Monitor-Management
    ├── test_monitor.sh     # Test-Script
    └── debug.sh            # Debug-Helper

Generierte Dateien:
├── vfs_write.bpf.o         # Kompilierter BPF-Code
└── monitor                 # Ausführbares Userspace-Programm
```

## 🔧 Voraussetzungen

```bash
# Prüfen
sudo ./bpf check

# Ubuntu/Debian Installation
apt install -y clang llvm libelf-dev linux-headers-$(uname -r) \
               libbpf-dev bpftool build-essential
```

**Erforderlich:**
- clang (LLVM Compiler)
- bpftool (BPF Tool)
- libbpf (BPF Library)
- BTF Support im Kernel
- Root-Rechte (für BPF Programme)

## 📊 Was macht das Programm?

Monitort **VFS-Schreiboperationen** auf Kernel-Ebene:
- Hakt sich in `vfs_iter_write()` ein (Kernel-Funktion)
- Erfasst PID, Bytes und Dateinamen
- Sendet Events über Ringbuffer an Userspace
- Keine Overhead bei normalen Operationen

**Anwendungsfälle:**
- Monitoring von NFS-Server Schreibvorgängen
- File-System Activity Tracking
- Performance-Analyse
- Security Auditing

## 🔍 Beispiel-Output

```
EVENT: PID 1234 hat 4096 Bytes in Datei 'test.txt' geschrieben.
EVENT: PID 5678 hat 1048576 Bytes in Datei 'data.bin' geschrieben.
EVENT: PID 1234 hat 512 Bytes in Datei 'config.json' geschrieben.
```

## 🐛 Troubleshooting

### Monitor startet nicht
```bash
# Logs prüfen
cat /var/log/bpf_monitor.log

# Debug-Informationen
sudo ./bpf debug

# Kernel Messages
dmesg | grep -i bpf
```

### Keine Events sichtbar
```bash
# BPF Programme prüfen
sudo ./bpf list-progs

# Kernel Trace aktivieren
sudo ./bpf trace

# Test-Script ausführen
./bpf test
```

### Build-Fehler
```bash
# System-Voraussetzungen prüfen
sudo ./bpf check

# Clean & Rebuild
./bpf clean
./bpf build
```

## 📖 Entwicklung

### Workflow
```bash
# 1. Code ändern in src/vfs_write.bpf.c

# 2. Neu kompilieren und testen
sudo ./bpf restart

# 3. Live-Logs beobachten
sudo ./bpf logs

# 4. Debug bei Problemen
sudo ./bpf debug
sudo ./bpf trace
```

### Debugging
```bash
# Vordergrund-Modus (sieht alle Ausgaben)
sudo ./bpf watch

# Kernel Events live
sudo ./bpf trace

# Verbose libbpf Logging
export LIBBPF_LOG_LEVEL=debug
sudo ./bpf watch
```

## 📚 Weitere Dokumentation

- [scripts/README.md](scripts/README.md) - Detaillierte Script-Dokumentation
- [src/vfs_write.bpf.c](src/vfs_write.bpf.c) - BPF Code mit Kommentaren
- [src/loader.c](src/loader.c) - Userspace Loader Code

## 📝 Logs & Dateien

| Datei | Beschreibung |
|-------|--------------|
| `/var/log/bpf_monitor.log` | Monitor Ausgabe-Logs |
| `/tmp/bpf_monitor.pid` | PID des laufenden Monitors |
| `/sys/kernel/debug/tracing/trace_pipe` | Kernel BPF Trace |
| `include/vfs_write.skel.h` | Generiertes Skeleton (3MB) |
| `vfs_write.bpf.o` | Kompiliertes BPF Object |
| `monitor` | Ausführbares Binary |

## 🎯 Tipps

- **Live-Monitoring**: `sudo ./bpf logs`
- **Performance**: Status zeigt CPU/Memory Usage
- **Development**: Verwende `./bpf watch` für schnelles Debugging
- **Production**: Verwende `./bpf start` für Hintergrund-Betrieb
