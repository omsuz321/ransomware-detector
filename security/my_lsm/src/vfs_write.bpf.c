// Definieren wir selbst, da wir linux/uio.h nicht inkludieren können
#ifndef UIO_MAXIOV
#define UIO_MAXIOV 1024 // Standard Kernel Wert (oder setze es auf 10 für Tests)
#endif

#ifndef __VMLINUX_H__
#include "../include/vmlinux.h"
#endif

#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>
// ENTFERNT: #include <linux/uio.h>  <-- Verursachte den Fehler
#include "../include/common.h"

char LICENSE[] SEC("license") = "GPL";

// ============================================================
// SPEICHER-LAYOUT & MAKROS
// ============================================================

// Airbag: Doppelte Größe (8KB) für Verifier-Mathe (Offset + Len)
#define AIRBAG_SIZE (MAX_DATA_SIZE * 2)

// Gesamtgröße des Scratch-Eintrags für Map-Definition
#define SCRATCH_MAP_SIZE (sizeof(struct write_event) + AIRBAG_SIZE)

// Interne Struktur für den Scratch-Buffer (nur im Kernel sichtbar)
struct scratch_t {
    struct write_event header;      // Der Kopf (wie in common.h)
    __u8 data_buffer[AIRBAG_SIZE];  // Der riesige Puffer (Airbag)
};

// ============================================================
// MAPS
// ============================================================

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 26); // 64 MB
} events SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __uint(key_size, sizeof(__u32));
    __uint(value_size, SCRATCH_MAP_SIZE); 
} scratch_map SEC(".maps");

// ============================================================
// LOGIK & CALLBACK
// ============================================================

struct loop_ctx {
    struct scratch_t *scratch;
    struct iov_iter *iter;
    size_t iov_offset;
    size_t total_requested;
    __u32 current_copied;
};

static __always_inline void get_filename(struct file *file, char *out, __u32 out_size)
{
    struct dentry *dentry = BPF_CORE_READ(file, f_path.dentry);
    const unsigned char *name = BPF_CORE_READ(dentry, d_name.name);
    bpf_probe_read_kernel_str(out, out_size, name);
}

// Callback für bpf_loop
static long loop_callback(__u32 i, struct loop_ctx *ctx)
{
    if (ctx->current_copied >= MAX_DATA_SIZE) return 1;

    struct iov_iter *iter = ctx->iter; 
    const struct kvec *kvec = BPF_CORE_READ(iter, kvec);
    
    void *base = BPF_CORE_READ(&kvec[i], iov_base);
    size_t len = BPF_CORE_READ(&kvec[i], iov_len);
    
    size_t seg_offset = (i == 0) ? ctx->iov_offset : 0;

    if (!base || len == 0 || seg_offset >= len) return 0;

    size_t data_in_seg = len - seg_offset;
    size_t space_left = MAX_DATA_SIZE - ctx->current_copied;
    size_t to_copy = data_in_seg;

    if (to_copy > space_left) to_copy = space_left;
    
    size_t remaining_request = ctx->total_requested - ctx->current_copied;
    if (to_copy > remaining_request) to_copy = remaining_request;

    // Kopieren in den Scratch-Buffer (mit Maskierung für Sicherheit)
    bpf_probe_read_kernel(
        &ctx->scratch->data_buffer[ctx->current_copied & (MAX_DATA_SIZE - 1)], 
        to_copy & (MAX_DATA_SIZE - 1), 
        (char*)base + seg_offset
    );

    ctx->current_copied += to_copy;
    return 0;
}

// ============================================================
// HILFSFUNKTION: Daten sammeln
// ============================================================
static __always_inline u64 fill_write_event(struct scratch_t *s, struct file *file, struct iov_iter *iter)
{
    // 1. Header füllen
    s->header.pid = bpf_get_current_pid_tgid() >> 32;
    s->header.uid = (__u32)bpf_get_current_uid_gid();
    u64 requested = BPF_CORE_READ(iter, count);
    s->header.requested = requested;
    s->header.len = 0; 
    s->header.fname[0] = '\0';
    
    get_filename(file, s->header.fname, sizeof(s->header.fname));

    // 2. Daten sammeln (nur KVEC)
    // ITER_KVEC ist im vmlinux.h definiert (meistens als 3 oder 4, je nach Kernel)
    if (BPF_CORE_READ(iter, iter_type) == ITER_KVEC) {
        unsigned long nr_segs = BPF_CORE_READ(iter, nr_segs);
        
        // Safety Cap: Nicht mehr als UIO_MAXIOV Segmente verarbeiten
        if (nr_segs > UIO_MAXIOV) nr_segs = UIO_MAXIOV;

        struct loop_ctx ctx = {
            .scratch = s,
            .iter = iter,
            .iov_offset = BPF_CORE_READ(iter, iov_offset),
            .total_requested = requested,
            .current_copied = 0
        };

        // Casting auf __u32 für bpf_loop
        bpf_loop((__u32)nr_segs, loop_callback, &ctx, 0);
        
        s->header.len = ctx.current_copied;
    }

    // 3. Sendegröße berechnen (Header + echte Daten)
    u64 bytes_to_send = sizeof(struct write_event) + s->header.len;

    if (bytes_to_send > SCRATCH_MAP_SIZE) {
        bytes_to_send = SCRATCH_MAP_SIZE;
    }

    return bytes_to_send;
}

// ============================================================
// HILFSFUNKTION: PREVIEW (Max 10 Zeichen)
// ============================================================
// Muss VOR dem KPROBE definiert sein.
static __always_inline void print_preview(void *data_ptr, u32 len)
{
    // 11 Bytes reservieren (10 Daten + 1 Null-Terminator)
    char msg[11]; 
    
    // WICHTIG: Puffer nullen, damit er sicher terminiert ist!
    __builtin_memset(msg, 0, sizeof(msg));

    // Cap auf 10 Bytes
    if (len > 10) len = 10;

    // Daten sicher in den Stack-Puffer kopieren
    bpf_probe_read_kernel(msg, len, data_ptr);

    // Ausgabe mit | Begrenzung, damit man Leerzeichen sieht
    bpf_printk("CONTENT: |%s|", msg);
}

// ============================================================
// HAUPTPROGRAMM
// ============================================================
SEC("kprobe/vfs_iter_write")
int BPF_KPROBE(vfs_iter_write_enter, struct file *file, struct iov_iter *iter)
{
    int key = 0;
    struct scratch_t *s = bpf_map_lookup_elem(&scratch_map, &key);
    if (!s) return 0;

    // 1. Daten sammeln (nutzt unsere existierende Hilfsfunktion)
    u64 bytes_to_send = fill_write_event(s, file, iter);

    // ============================================================
    // DEBUG OUTPUT
    // ============================================================
    
    // Info 1: Kontext (Wer schreibt wohin?)
    // Hinweis: \n im String ist bei trace_pipe oft unschön, 
    // da bpf_printk automatisch eine neue Zeile für jeden Aufruf macht.
    bpf_printk("LOG: pid=%u uid=%u fname=%s", 
               s->header.pid, 
               s->header.uid, 
               s->header.fname);

    // Info 2: Größen
    bpf_printk("SIZE: req=%llu real=%u", 
               s->header.requested, 
               s->header.len);

    // Info 3: INHALT VORSCHAU (Das Neue!)
    // Zeigt die ersten 10 Bytes des echten Datenpuffers an
    if (s->header.len > 0) {
        print_preview(s->data_buffer, s->header.len);
    } else {
        bpf_printk("CONTENT: (empty)");
    }

    // ============================================================

    // 2. Senden an Userspace
    bpf_ringbuf_output(&events, &s->header, bytes_to_send, 0);

    return 0;
}