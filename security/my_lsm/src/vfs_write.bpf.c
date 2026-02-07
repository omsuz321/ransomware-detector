// Definieren wir selbst, da wir linux/uio.h nicht inkludieren können
#ifndef UIO_MAXIOV
#define UIO_MAXIOV 1024 
#endif

// Define file permission constants
#ifndef MAY_READ
#define MAY_READ 0x00000004
#endif

#ifndef MAY_WRITE
#define MAY_WRITE 0x00000002
#endif

/* * NFSD_MAGIC repräsentiert den String "nfsd" als 4-Byte Integer.
 * * Erklärung:
 * Auf Little-Endian Systemen (wie Intel x86) werden Bytes "rückwärts" gespeichert.
 * Der String "nfsd" liegt im Speicher also als 'd', 's', 'f', 'n'.
 * * - Little Endian: 0x64('d') 73('s') 66('f') 6E('n') -> 0x6473666E
 * - Big Endian:    0x6E('n') 66('f') 73('s') 64('d') -> 0x6E667364
 * * Der Compiler wertet dies zur Build-Zeit aus (keine Kosten zur Laufzeit).
 */
#define NFSD_MAGIC (__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__ ? 0x6473666E : 0x6E667364)

#ifndef __VMLINUX_H__
#include <vmlinux.h>
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

#ifndef __IO_HELPERS_H__
#include "../include/io_helpers.h"
#endif

#ifndef __ENTROPY_H__
#include "../include/entropy.h"
#endif

#define SHOULD_SKIP(mask) !((mask & (MAY_READ | MAY_WRITE)) && is_nfsd())


char LICENSE[] SEC("license") = "GPL";

// ============================================================
// SPEICHER-LAYOUT
// ============================================================

// AIRBAG_SIZE, SCRATCH_MAP_SIZE, write_event, scratch_t now live in io_helpers.h

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

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __uint(key_size, sizeof(__u32));
    __uint(value_size, sizeof(__u64));
} lsm_hits SEC(".maps");


struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, MAX_USER_COUNT); 
    __uint(key_size, sizeof(__u32));
    __uint(value_size, sizeof(struct user_stats_t));
} user_tracker SEC(".maps");

static __always_inline int is_nfsd(void) {
    #define COMM_SIZE 16
    char comm[COMM_SIZE];
    
    //clean initilize with 0
    __builtin_memset(comm, 0, COMM_SIZE);

    if (bpf_get_current_comm(&comm, COMM_SIZE) < 0) {
        return 0; // Fehler beim Lesen -> sicherheitshalber ignorieren
    }

    // Wenn Magic stimmt -> 1, sonst 0
    return (*(unsigned int *)comm == NFSD_MAGIC);
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




// WICHTIG: Rückgabetyp ist jetzt ein POINTER (*)
static __always_inline struct user_stats_t *GetOrCreateUserStats(__u32 uid)
{
    static struct user_stats_t empty_stats = {0};
    // 1. Versuch: Existiert der User schon?
    struct user_stats_t *stats = bpf_map_lookup_elem(&user_tracker, &uid);
    if (stats) 
        return stats;
    // 2. Wenn nicht: Neu anlegen
    // Wir nutzen die globale 'empty_stats' um den Stack nicht zu belasten
    bpf_map_update_elem(&user_tracker, &uid, &empty_stats, BPF_NOEXIST);
    
    // 3. WICHTIG: Nach dem Update müssen wir den Pointer NEU holen!
    // bpf_map_update_elem gibt nur einen Fehlercode (int) zurück, keinen Pointer.
    return bpf_map_lookup_elem(&user_tracker, &uid);
}

static __always_inline int CalcEntropy(struct file *file, struct iov_iter *iter, struct fixed_point *entropy_out)
{
    int key = 0;
    struct scratch_t *s = bpf_map_lookup_elem(&scratch_map, &key);
    if (!s) 
        return 0;

    //füllt die scratch map und gibt die tatsächliche Länge zurück
    u64 bytes_to_send = fill_write_event(s, file, iter);
    if(bytes_to_send < 0)
        return 0;

    // Zählung & Ausgabe
    struct freq_table *table = bpf_map_lookup_elem(&byte_counts, &key);

    //TODO überprufen, ob das jemals passieren kann, da wir ja immer einen Eintrag anlegen, bevor wir hier 
    __u32 header_len = s->header.len;
    if (table && header_len< 0) 
        return 0;

    struct count_ctx ctx = {
        .table = table,
        .data_buffer = s->data_buffer
    };

    __u32 loop_limit = header_len > MAX_DATA_SIZE ? MAX_DATA_SIZE : header_len;

    // 1. Zählen
    bpf_loop(loop_limit, count_bytes_fast, &ctx, 0);

    //TODO entfernen 
    print_human_readable(table);

    //TODO entfernen
    bpf_printk("LOG: pid=%u len=%u", s->header.pid, s->header.len);
    if (header_len > 0) {
        print_preview(s->data_buffer, header_len);
    }
    // Entropie berechnen und ausgeben
    calculate_entropy(table, header_len, entropy_out, 1);

    return 1;
}
// ============================================================
// HAUPTPROGRAMM
// ============================================================

SEC("kprobe/vfs_iter_write")
int BPF_KPROBE(vfs_iter_write_enter, struct file *file, struct iov_iter *iter)
{
    if (!is_nfsd())
        return 0;

    struct fixed_point entropy;
    // Fehler bei der Berechnung -> nicht weiterverarbeiten
    if(!CalcEntropy(file, iter, &entropy))
        return 0; 
    print_fixed_point("entropy", &entropy);
    return 0;
}


// LSM hook: log uid for read/write permission checks (e.g., ls, write)
SEC("lsm/file_permission")
int BPF_PROG(log_file_permission, struct file *file, int mask)
{
    if (SHOULD_SKIP(mask)) 
        return 0;


    __u32 uid = (__u32)bpf_get_current_uid_gid();

    struct user_stats_t *stats = GetOrCreateUserStats(uid);

    __u32 key = 0;
    __u64 *hits = bpf_map_lookup_elem(&lsm_hits, &key);
    if (hits)
        __sync_fetch_and_add(hits, 1);
    //funktionert, weil nfsd ein credential overwrite durchführt und somit dann von nfs cleint die uid nimmt

    bpf_printk("lsm file_permission uid=%u mask=0x%x", uid, mask);
    return 0;
}