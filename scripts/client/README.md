# Filebench NFS Client Scripts

Komplette Scripts zum Bauen, Setuppen und Ausführen von Filebench-Benchmarks gegen einen NFS-Server.

## 📁 Verzeichnisstruktur

```
/work/scripts/client/
├── nfs_setup/         ← NFS-Setup und Vorbereitung
│   ├── build.sh       → Baut Filebench
│   ├── setup.sh       → Setupet NFS-Client
│   └── run.sh         → Führt einzelne Workload aus
├── benchmark/         ← Benchmark-Durchführung
│   └── run_benchmark.sh → Steuert mehrere Benchmark-Runs
└── README.md          ← Diese Datei
```

---

## 🚀 Quick Start

### 1️⃣ Build (einmalig)
```bash
/work/scripts/client/nfs_setup/build.sh
```

### 2️⃣ Setup (vor jedem Benchmark-Durchlauf)
```bash
/work/scripts/client/nfs_setup/setup.sh 192.168.1.100
```

### 3️⃣ Benchmark ausführen
```bash
/work/scripts/client/benchmark/run_benchmark.sh --threads 4 --files 50000
```

---

## 📋 Detallierte Dokumentation

### NFS Setup (`/work/scripts/client/nfs_setup/`)

#### `build.sh` - Baut Filebench
```bash
/work/scripts/client/nfs_setup/build.sh
```

**Was macht es:**
- Installiert fehlende Tools (libtool, automake, bison, flex)
- Generiert Autotool-Scripts
- Konfiguriert und kompiliert Filebench
- Installiert Filebench system-wide

**Dauer:** ~5-10 Minuten beim ersten Mal
**Muss nur einmal gemacht werden**

#### `setup.sh` - Setup für NFS-Client Tests
```bash
/work/scripts/client/nfs_setup/setup.sh <SERVER_IP> [NFS_EXPORT]
```

**Parameter:**
- `<SERVER_IP>` - IP-Adresse des NFS-Servers (erforderlich)
- `[NFS_EXPORT]` - NFS-Export-Pfad, standardmäßig `/export/nfs`

**Beispiele:**
```bash
# Standard
/work/scripts/client/nfs_setup/setup.sh 192.168.1.100

# Mit custom NFS-Export
/work/scripts/client/nfs_setup/setup.sh 192.168.1.100 /share/nfs
```

**Was macht es:**
- ✅ Erstellt NFS Mount-Punkt (`/mnt/nfs`)
- ✅ Mounted das NFS-Dateisystem vom Server
- ✅ Kopiert `netsfs.f` Workload-Template
- ✅ Ändert Pfad von `/tmp` zu `/mnt/nfs`
- ✅ Zeigt Konfiguration an

**Dauer:** ~1-2 Sekunden
**Muss vor jedem Benchmark-Durchlauf einmal ausgeführt werden**

#### `run.sh` - Führt einzelne Workload aus
```bash
/work/scripts/client/nfs_setup/run.sh
```

**Was macht es:**
- ✅ Validiert Setup
- ✅ Zeigt Workload-Parameter
- ✅ Startet Filebench (60 Sekunden Laufzeit)
- ✅ Gibt Ergebnisse aus

**Dauer:** ~60 Sekunden
**Kann beliebig oft wiederholt werden**

---

### Benchmark (`/work/scripts/client/benchmark/`)

#### `run_benchmark.sh` - Benchmark Controller
```bash
/work/scripts/client/benchmark/run_benchmark.sh [OPTIONS]
```

**Options:**
```
-t, --threads THREADS      Thread counts (comma-separated, default: 1,2,4,8)
-f, --files FILES          File counts (comma-separated, default: 10000,50000,100000)
-d, --duration SECONDS     Duration per run (default: 60)
-v, --verbose              Verbose output
-h, --help                 Show help message
```

**Beispiele:**
```bash
# Help anschauen
/work/scripts/client/benchmark/run_benchmark.sh --help

# Default (12 Runs: 4x3 Kombinationen)
/work/scripts/client/benchmark/run_benchmark.sh

# Single Konfiguration
/work/scripts/client/benchmark/run_benchmark.sh --threads 4 --files 50000 -t 4 -f 50000

# Custom Ranges
/work/scripts/client/benchmark/run_benchmark.sh --threads 1,2,4,8,16 --files 10000,100000

# Verbose Output
/work/scripts/client/benchmark/run_benchmark.sh -t 2,4 -f 50000 --verbose

# Mit Custom-Dauer
/work/scripts/client/benchmark/run_benchmark.sh --threads 4 --duration 120
```

**Was macht es:**
- ✅ Führt mehrere Benchmark-Runs durch
- ✅ Testet verschiedene Thread-Counts
- ✅ Testet verschiedene Datei-Anzahlen
- ✅ Speichert Ergebnisse in Log-Datei
- ✅ Zeigt Live-Fortschritt mit Farben

**Dauer:** Abhängig von Konfiguration (n_runs × 60 Sekunden + Overhead)
**Alle Ergebnisse werden in Log-Datei gespeichert:**
```
/tmp/filebench_results/benchmark_run_YYYYMMDD_HHMMSS.log
```

---

## 🔄 Vollständiger Workflow

### Erste Verwendung:
```bash
# 1. Filebench bauen
/work/scripts/client/nfs_setup/build.sh

# 2. NFS-Client Setup
/work/scripts/client/nfs_setup/setup.sh 192.168.1.100

# 3. Benchmark starten
/work/scripts/client/benchmark/run_benchmark.sh
```

### Wiederholte Verwendung:
```bash
# 1. Setup erneuern (optional, wenn Server IP sich ändert)
/work/scripts/client/nfs_setup/setup.sh 192.168.1.100

# 2. Benchmark starten
/work/scripts/client/benchmark/run_benchmark.sh --threads 4 --files 50000
```

---

## 📊 Workload-Parameter

Die Workload-Datei wird unter `/tmp/netsfs_nfs_client.f` erstellt und enthält:

```bash
set $nthreads=1          # Anzahl Worker-Threads
set $nfiles=100000       # Anzahl Test-Dateien
set $eventrate=10        # Event-Rate (0 = freier Durchsatz)
set $sync=false          # Sync-Verhalten
```

Diese können mit Filebench-Optionen überschrieben werden:
```bash
filebench -f /tmp/netsfs_nfs_client.f -v \$nthreads=8 -v \$nfiles=200000
```

---

## 📁 Log-Dateien

### Benchmark-Ergebnisse:
```
/tmp/filebench_results/benchmark_run_*.log
```

### NFS Benchmark-Logs:
```
/tmp/filebench_bench_*.log
```

### Live-Log während Benchmark:
```bash
tail -f /tmp/filebench_results/benchmark_run_*.log
```

---

## 🔧 Troubleshooting

### "Workload file not found"
→ Run `build.sh` first

### "filebench command not found"
→ Run `build.sh` first

### "NFS not mounted"
→ Run `setup.sh` with correct Server IP

### "Failed to mount NFS"
→ Check Server IP und ob NFS-Export aktiv ist

---

## 💡 Tips & Tricks

### Nur Konfiguration testen (kurze Laufzeit):
```bash
/work/scripts/client/benchmark/run_benchmark.sh -t 1 -f 10000 -d 10
```

### Hohe Last erzeugen:
```bash
/work/scripts/client/benchmark/run_benchmark.sh -t 16 -f 200000
```

### Mit Logging starten und Ausgabe beobachten:
```bash
bash -x /work/scripts/client/benchmark/run_benchmark.sh --threads 4
```

### Alte Logs aufräumen:
```bash
rm -f /tmp/filebench_bench_*.log
rm -f /tmp/filebench_results/benchmark_run_*.log
```
