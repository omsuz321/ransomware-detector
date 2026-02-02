# BPF Monitor auf VM ausführen

## Voraussetzungen in der VM prüfen

### 1. Kernel-Version & BPF-Support
```bash
uname -r
# Sollte 6.8.0-37-generic oder ähnlich sein

# BPF Syscall Support prüfen
grep CONFIG_BPF_SYSCALL /boot/config-$(uname -r)
# Sollte: CONFIG_BPF_SYSCALL=y
```

### 2. BTF (BPF Type Format) verfügbar?
```bash
ls -lh /sys/kernel/btf/vmlinux
# Muss existieren!
```

### 3. Benötigte Pakete installieren
```bash
sudo apt update
sudo apt install -y \
    clang \
    llvm \
    libbpf-dev \
    bpftool \
    linux-headers-$(uname -r) \
    build-essential \
    libelf-dev
```

### 4. debugfs mounten (für trace)
```bash
sudo mount -t debugfs none /sys/kernel/debug
```

## Dateien in VM kopieren

```bash
# Von Host zu VM (SCP oder shared folder)
scp -r ./my_lsm user@vm-ip:/home/user/

# In der VM
cd /home/user/my_lsm
```

## In der VM kompilieren und ausführen

```bash
# Kompilieren
make clean
make all

# Als ROOT ausführen (wichtig!)
sudo ./monitor

# Oder mit Script
sudo ./bpf build
sudo ./bpf watch    # Vordergrund
# oder
sudo ./bpf start    # Hintergrund
```

## Test durchführen

In neuem Terminal:
```bash
# Testdaten schreiben
echo "test" > /tmp/test.txt
dd if=/dev/zero of=/tmp/bigfile bs=1M count=10
```

Monitor sollte nun Events anzeigen:
```
EVENT: PID 1234 hat 5 Bytes in Datei 'test.txt' geschrieben.
EVENT: PID 1235 hat 10485760 Bytes in Datei 'bigfile' geschrieben.
```

## Häufige Probleme in der VM

### Problem: "Operation not permitted"
**Lösung:** Als root ausführen:
```bash
sudo ./monitor
```

### Problem: "vfs_iter_write not found"
**Lösung:** Funktion prüfen:
```bash
grep vfs_iter_write /proc/kallsyms
```
Falls nicht vorhanden: Kernel zu alt oder Funktion heißt anders.

### Problem: BTF fehlt
```bash
# BTF manuell generieren
sudo bpftool btf dump file /sys/kernel/btf/vmlinux format c > include/vmlinux.h
```

### Problem: Keine Events sichtbar
```bash
# BPF Programme prüfen
sudo bpftool prog show

# Kernel Trace prüfen
sudo cat /sys/kernel/debug/tracing/trace_pipe

# Test-Script
./bpf test
```

## Debug-Modus

```bash
# Mit vollem Debug-Output
export LIBBPF_LOG_LEVEL=debug
sudo ./monitor
```

## Berechtigungen

Der Monitor braucht ROOT-Rechte für:
- BPF Programme laden
- Kprobes attachen
- Ringbuffer Maps erstellen

**Immer mit `sudo` ausführen!**
