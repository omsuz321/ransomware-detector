# BPF Monitor Scripts

Diese Scripts helfen bei der Verwaltung und dem Testen des BPF Monitors.

## Verfügbare Scripts

### 1. `monitor.sh` - Haupt-Management Script

Verwaltet den BPF Monitor als Hintergrund-Service.

**Verwendung:**
```bash
sudo ./scripts/monitor.sh {build|start|stop|restart|status|clean|logs}
```

**Befehle:**
- `build` - Kompiliert das BPF-Programm
- `start` - Startet den Monitor im Hintergrund
- `stop` - Stoppt den laufenden Monitor
- `restart` - Neustart des Monitors
- `status` - Zeigt Status und BPF-Informationen
- `clean` - Löscht Build-Artefakte und Logs
- `logs` - Zeigt Live-Logs (Ctrl+C zum Beenden)

**Beispiele:**
```bash
# Kompilieren und starten
sudo ./scripts/monitor.sh build
sudo ./scripts/monitor.sh start

# Status prüfen
sudo ./scripts/monitor.sh status

# Logs anschauen
sudo ./scripts/monitor.sh logs

# Stoppen
sudo ./scripts/monitor.sh stop
```

**Log-Datei:** `/var/log/bpf_monitor.log`

---

### 2. `test_monitor.sh` - Test-Script

Generiert Testdaten, um den Monitor zu testen.

**Verwendung:**
```bash
./scripts/test_monitor.sh
```

Erstellt verschiedene Schreiboperationen:
- Mehrere kleine Text-Dateien
- Binäre Dateien mit `dd`
- Kontinuierliche Schreibvorgänge

**Nach dem Test:**
```bash
# Logs prüfen
sudo tail -30 /var/log/bpf_monitor.log

# Testdaten löschen
rm -rf /tmp/bpf_test
```

---

### 3. `debug.sh` - Debug-Informationen

Zeigt detaillierte BPF Debug-Informationen.

**Verwendung:**
```bash
sudo ./scripts/debug.sh
```

**Zeigt:**
- Geladene BPF Programme
- BPF Maps (events, writes)
- Aktive Kprobes
- Kernel Trace Pipe
- Verfügbare VFS Funktionen
- BTF Informationen

---

## Typischer Workflow

### Erste Inbetriebnahme
```bash
# 1. Kompilieren
sudo ./scripts/monitor.sh build

# 2. Starten
sudo ./scripts/monitor.sh start

# 3. Status prüfen
sudo ./scripts/monitor.sh status

# 4. In neuem Terminal: Test ausführen
./scripts/test_monitor.sh

# 5. Logs prüfen
sudo ./scripts/monitor.sh logs
```

### Entwicklung & Debugging
```bash
# Code ändern, neu kompilieren und starten
sudo ./scripts/monitor.sh restart

# Debug-Informationen abrufen
sudo ./scripts/debug.sh

# Live Kernel Traces
sudo cat /sys/kernel/debug/tracing/trace_pipe
```

### Cleanup
```bash
# Monitor stoppen und aufräumen
sudo ./scripts/monitor.sh stop
sudo ./scripts/monitor.sh clean
```

---

## Troubleshooting

### Monitor startet nicht
```bash
# Logs prüfen
cat /var/log/bpf_monitor.log

# Debug-Infos
sudo ./scripts/debug.sh

# Kernel Logs
dmesg | grep -i bpf
```

### Keine Events sichtbar
```bash
# Prüfen ob BPF Programme geladen sind
sudo bpftool prog show

# Prüfen ob Kprobes aktiv sind
cat /sys/kernel/debug/tracing/kprobe_events

# Test-Script ausführen
./scripts/test_monitor.sh
```

### Permission Denied
```bash
# Alle Scripts benötigen Root-Rechte (außer test_monitor.sh)
sudo ./scripts/monitor.sh status
```

---

## Dateien & Logs

| Datei/Pfad | Beschreibung |
|------------|--------------|
| `/var/log/bpf_monitor.log` | Monitor Ausgabe |
| `/tmp/bpf_monitor.pid` | PID-Datei des laufenden Monitors |
| `/sys/kernel/debug/tracing/trace_pipe` | Kernel BPF Trace |
| `/sys/kernel/btf/vmlinux` | BTF Type Information |

---

## Tipps

- **Live-Monitoring:** `sudo ./scripts/monitor.sh logs`
- **Automatischer Start:** Füge zu systemd oder cron hinzu
- **Performance:** Status zeigt CPU/Memory Nutzung
- **Debug:** Setze `LIBBPF_LOG_LEVEL=debug` für verbose Output
