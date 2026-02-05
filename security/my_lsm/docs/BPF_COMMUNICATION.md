# BPF Program Communication - kprobe ↔ LSM Hook

## Architektur-Übersicht

```
┌─────────────────────────────────────────────────────────────┐
│                    Kernel Space                              │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌──────────────────────┐        ┌──────────────────────┐  │
│  │ vfs_write.bpf.c      │        │ my_lsm.bpf.c         │  │
│  │ (kprobe)             │        │ (LSM Hook)           │  │
│  ├──────────────────────┤        ├──────────────────────┤  │
│  │ • Sammelt Daten      │        │ • Liest State        │  │
│  │ • Schreibt in Maps   │◄──────►│ • Trifft Entscheid.  │  │
│  │ • Sendet an User     │        │ • Block/Allow        │  │
│  └──────────────────────┘        └──────────────────────┘  │
│            │                               ▲                 │
│            │ (schreibt)     (liest)        │                 │
│            ▼                               │                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │          BPF Maps (Shared State)                    │   │
│  ├─────────────────────────────────────────────────────┤   │
│  │ • process_write_state (PID → write_state)           │   │
│  │ • file_access_state   (inode → file_state)          │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                               │
└───────────────────────────────┬───────────────────────────────┘
                                │ (ringbuffer)
                                ▼
                        ┌───────────────┐
                        │  Userspace    │
                        │  (monitoring) │
                        └───────────────┘
```

## Wie funktioniert die Kommunikation?

### 1. **Shared Maps** (definiert in `shared_state.h`)

```c
// Per-Process Write State
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, __u32);              // PID
    __type(value, struct write_state);
} process_write_state SEC(".maps");
```

**Wichtig:** Maps sind **global** für alle BPF-Programme im selben Kontext!

### 2. **kprobe schreibt Daten** (vfs_write.bpf.c)

```c
// Nach dem Daten sammeln:
update_write_state(pid, bytes, data_preview, len);
update_file_state(inode);
```

### 3. **LSM Hook liest Daten** (my_lsm.bpf.c)

```c
SEC("lsm/file_open")
int BPF_PROG(file_open, struct file *file) {
    struct write_state *ws = get_write_state(pid);
    
    if (ws->write_count > 1000) {
        return -1;  // BLOCKIERT!
    }
    
    return 0;  // ERLAUBT
}
```

## Use Cases

### 🛡️ Ransomware Detection

**kprobe:** Trackt wie viele Bytes ein Prozess schreibt
**LSM:** Blockiert wenn >100MB in <1 Sekunde geschrieben werden

### 🔍 Anomaly Detection

**kprobe:** Analysiert Daten-Entropie (verschlüsselt vs. normal)
**LSM:** Blockiert Zugriff wenn verdächtige Pattern erkannt werden

### 📊 Rate Limiting

**kprobe:** Zählt Datei-Zugriffe pro Inode
**LSM:** Blockiert wenn eine Datei zu oft zugegriffen wird

## Kompilierung

### Option 1: Beide Programme zusammen laden

```bash
# Kompilieren
make

# Laden (beide Programme nutzen dieselben Maps)
bpftool prog load vfs_write.bpf.o /sys/fs/bpf/vfs_write
bpftool prog load my_lsm.bpf.o /sys/fs/bpf/my_lsm
```

### Option 2: Maps pinnen (empfohlen)

```bash
# Maps pinnen für Sharing
bpftool map create /sys/fs/bpf/process_state \
    type hash key 4 value 112 entries 10240 name process_write_state

# Programme mit gepinnten Maps laden
bpftool prog load vfs_write.bpf.o /sys/fs/bpf/vfs_write \
    map name process_write_state pinned /sys/fs/bpf/process_state
```

## Wichtige Punkte

### ✅ Vorteile

1. **Verschiedene Hooks können Daten teilen**
2. **LSM kann auf historischen Kontext zugreifen**
3. **Modulare Architektur** - kprobe sammelt, LSM entscheidet
4. **Performance** - Per-CPU Maps für Lock-free Access

### ⚠️ Limitierungen

1. **Maps müssen richtig dimensioniert sein** (max_entries)
2. **Cleanup nötig** - Alte Einträge müssen entfernt werden
3. **Race Conditions** - Bei Parallel-Zugriff beachten
4. **Verifier-Komplexität** - Mehr Maps = komplexere Verification

## Debugging

```bash
# Maps anzeigen
bpftool map dump name process_write_state

# LSM Logs anzeigen
cat /sys/kernel/debug/tracing/trace_pipe | grep LSM
```

## Beispiel-Output

```
kprobe: PID 1234 schrieb 4096 Bytes nach /etc/shadow
LSM: Blocked file_open by PID 1234 (too many writes: 1001)
```

## Erweiterungen

### Multi-Program Coordination

Weitere Programme könnten hinzugefügt werden:

- **Tracepoint** für syscall monitoring
- **XDP** für Network-Policy basierend auf File-Zugriff
- **Perf Event** für CPU-Nutzungs-Korrelation

Alle können auf die **gleichen shared maps** zugreifen!
