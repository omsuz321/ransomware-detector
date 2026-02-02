// BEISPIEL: Daten aus Write-Buffer lesen
// WARNUNG: Nur für kleine Datenmengen! Große Buffers können Performance killen.

#define MAX_DATA_SAMPLE 64  // Nur erste 64 Bytes lesen

struct write_event {
    u64 pid;
    ssize_t bytes;
    char fname[64];
    char data_sample[MAX_DATA_SAMPLE];  // NEU: Erste Bytes der Daten
    u32 data_len;                       // Tatsächliche Länge
};

// In der ENTRY Probe (wichtig: ENTRY, nicht EXIT!)
SEC("kprobe/vfs_iter_write")
int BPF_KPROBE(vfs_iter_write_enter, struct file *file, struct iov_iter *iter, loff_t *ppos, int flags)
{
    u64 pid = bpf_get_current_pid_tgid();
    struct write_ctx wctx = {};
    
    wctx.pid = pid;
    wctx.file = file;
    
    // NEU: iov_iter speichern für späteren Zugriff
    wctx.iter = iter;  // Pointer speichern
    
    bpf_map_update_elem(&writes, &pid, &wctx, BPF_ANY);
    return 0;
}

// In der EXIT Probe: Daten extrahieren
SEC("kretprobe/vfs_iter_write")
int BPF_KRETPROBE(vfs_iter_write_exit, ssize_t ret)
{
    // ... (bestehender Code)
    
    // Daten aus iov_iter lesen (KOMPLEX!)
    struct iov_iter *iter = wctx->iter;
    
    // iov_iter ist eine komplexe Struktur mit verschiedenen Typen:
    // - ITER_KVEC: Kernel Virtual Memory
    // - ITER_UBUF: User Buffer (häufigster Fall)
    
    // Für ITER_UBUF (Userspace-Daten):
    const struct iovec *iov;
    void __user *ubuf;
    size_t count;
    
    // Typ prüfen (iter->iter_type)
    u8 iter_type = BPF_CORE_READ(iter, iter_type);
    
    if (iter_type == ITER_UBUF) {
        // Userspace-Buffer
        ubuf = BPF_CORE_READ(iter, ubuf);
        count = BPF_CORE_READ(iter, count);
        
        // WICHTIG: bpf_probe_read_user() für Userspace!
        size_t to_read = count < MAX_DATA_SAMPLE ? count : MAX_DATA_SAMPLE;
        bpf_probe_read_user(e->data_sample, to_read, ubuf);
        e->data_len = count;
    }
    
    // ... Submit event
}
