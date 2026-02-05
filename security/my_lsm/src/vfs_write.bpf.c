// Definieren wir selbst, da wir linux/uio.h nicht inkludieren können
#ifndef UIO_MAXIOV
#define UIO_MAXIOV 1024 
#endif

#ifndef __VMLINUX_H__
#include "../include/vmlinux.h"
#endif

#ifndef __BPF_HELPERS_
#include <bpf/bpf_helpers.h>
#endif

#ifndef __BPF_TRACING_H__
#include <bpf/bpf_tracing.h>
#endif

#ifndef __BPF_CORE_READ_H__
#include <bpf/bpf_core_read.h>
#endif

#ifndef __COMMON_H
#include "../include/common.h"
#endif


char LICENSE[] SEC("license") = "GPL";

// ============================================================
// SPEICHER-LAYOUT
// ============================================================

#define AIRBAG_SIZE (MAX_DATA_SIZE * 2)
#define SCRATCH_MAP_SIZE (sizeof(struct write_event) + AIRBAG_SIZE)

struct write_event {
    __u32 pid;
    __u32 uid;
    __u32 len;          // Wie viele Bytes haben wir wirklich kopiert?
    __u64 requested;    // Wie viele Bytes wollte der User schreiben?
    char  fname[256];
    
    // FLEXIBLES ARRAY:
    // In der Strukturdefinition ist es 0 Bytes groß.
    // Im Ringbuffer nimmt es variabel viel Platz ein.
    __u8  data[];       
};

struct scratch_t {
    struct write_event header;
    __u8 data_buffer[AIRBAG_SIZE];
};

// ============================================================
// MAPS
// ============================================================

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 26); 
} events SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __uint(key_size, sizeof(__u32));
    __uint(value_size, SCRATCH_MAP_SIZE); 
} scratch_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __uint(key_size, sizeof(__u32));
    __uint(value_size, sizeof(struct freq_table)); 
} byte_counts SEC(".maps");

// ============================================================
// CALLBACKS
// ============================================================

struct loop_ctx {
    struct scratch_t *scratch;
    struct iov_iter *iter;
    size_t iov_offset;
    size_t total_requested;
    __u32 current_copied;
};

struct count_ctx {
    struct freq_table *table;
    __u8 *data_buffer;
};

static __always_inline void get_filename(struct file *file, char *out, __u32 out_size)
{
    struct dentry *dentry = BPF_CORE_READ(file, f_path.dentry);
    const unsigned char *name = BPF_CORE_READ(dentry, d_name.name);
    bpf_probe_read_kernel_str(out, out_size, name);
}

// Daten kopieren
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

    bpf_probe_read_kernel(
        &ctx->scratch->data_buffer[ctx->current_copied & (MAX_DATA_SIZE - 1)], 
        to_copy & (MAX_DATA_SIZE - 1), 
        (char*)base + seg_offset
    );

    ctx->current_copied += to_copy;
    return 0;
}

// Zählen (Optimiert)
static long count_bytes_fast(__u32 i, struct count_ctx *ctx)
{
    __u32 idx = i & (MAX_DATA_SIZE - 1);
    __u8 byte_val = ctx->data_buffer[idx];
    ctx->table->counts[byte_val]++;
    return 0;
}

// ============================================================
// HILFSFUNKTION: FIX FÜR DIE AUSGABE
// ============================================================
static __always_inline void print_human_readable(struct freq_table *t)
{
    if (!t) return;

    bpf_printk("=== ERGEBNIS ===");

    // Ziffern '0'..'9'
    for (__u32 i = 48; i <= 57; i++) {
        __u16 c = t->counts[i];
        if (c)
            bpf_printk("'%c': %u", (char)i, c);
    }

    // Buchstaben 'A'..'Z'
    for (__u32 i = 65; i <= 90; i++) {
        __u16 c = t->counts[i];
        if (c)
            bpf_printk("'%c': %u", (char)i, c);
    }

    // Buchstaben 'a'..'z'
    for (__u32 i = 97; i <= 122; i++) {
        __u16 c = t->counts[i];
        if (c)
            bpf_printk("'%c': %u", (char)i, c);
    }
    
    bpf_printk("================");
}

// ============================================================
// HILFSFUNKTION: Daten sammeln
// ============================================================
static __always_inline u64 fill_write_event(struct scratch_t *s, struct file *file, struct iov_iter *iter)
{
    s->header.pid = bpf_get_current_pid_tgid() >> 32;
    s->header.uid = (__u32)bpf_get_current_uid_gid();
    u64 requested = BPF_CORE_READ(iter, count);
    s->header.requested = requested;
    s->header.len = 0; 
    s->header.fname[0] = '\0';
    
    get_filename(file, s->header.fname, sizeof(s->header.fname));

    if (BPF_CORE_READ(iter, iter_type) == ITER_KVEC) {
        unsigned long nr_segs = BPF_CORE_READ(iter, nr_segs);
        if (nr_segs > UIO_MAXIOV) nr_segs = UIO_MAXIOV;

        struct loop_ctx ctx = {
            .scratch = s,
            .iter = iter,
            .iov_offset = BPF_CORE_READ(iter, iov_offset),
            .total_requested = requested,
            .current_copied = 0
        };

        bpf_loop((__u32)nr_segs, (void *)loop_callback, &ctx, 0);
        s->header.len = ctx.current_copied;
    }

    u64 bytes_to_send = sizeof(struct write_event) + s->header.len;
    if (bytes_to_send > SCRATCH_MAP_SIZE) bytes_to_send = SCRATCH_MAP_SIZE;

    return bytes_to_send;
}

static __always_inline void print_preview(void *data_ptr, u32 len)
{
    char msg[11]; 
    __builtin_memset(msg, 0, sizeof(msg));
    if (len > 10) len = 10;
    bpf_probe_read_kernel(msg, len, data_ptr);
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

    u64 bytes_to_send = fill_write_event(s, file, iter);

    // Zählung & Ausgabe
    struct freq_table *table = bpf_map_lookup_elem(&byte_counts, &key);

    if (table && s->header.len > 0) {
        // Vor der Zählung: Altes löschen (optional, aber sauberer für Tests)
        // Hier in BPF schwer möglich ohne loop, aber da per-cpu array persistent ist,
        // addieren wir einfach weiter. Für saubere "pro Schreibvorgang" Tests
        // müsste man das Array eigentlich nullen.
        // Wir lassen es akkumulieren, wie besprochen.

        struct count_ctx ctx = {
            .table = table,
            .data_buffer = s->data_buffer
        };

        __u32 loop_limit = s->header.len;
        if (loop_limit > MAX_DATA_SIZE) loop_limit = MAX_DATA_SIZE;

        // 1. Zählen
        bpf_loop(loop_limit, count_bytes_fast, &ctx, 0);


        print_human_readable(table);
    }

    bpf_printk("LOG: pid=%u len=%u", s->header.pid, s->header.len);
    if (s->header.len > 0) {
        print_preview(s->data_buffer, s->header.len);
    }
    

    bpf_ringbuf_output(&events, &s->header, bytes_to_send, 0);

    return 0;
}