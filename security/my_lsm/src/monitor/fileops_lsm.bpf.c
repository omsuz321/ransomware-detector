// SPDX-License-Identifier: GPL-2.0
#ifndef __VMLINUX_H__
#include "../../include/vmlinux.h"
#endif

#ifndef __BPF_TRACING_H__
#include <bpf/bpf_tracing.h>
#endif
#ifndef __COMMON_H
#include "../../include/common.h"
#endif
#ifndef __FILEOPS_COMMON_H
#include "../../include/fileops_common.h"
#endif

#ifndef __IO_HELPERS_H__
#include "../../include/io_helpers.h"
#endif

#ifndef ___ENTROPY_H__
#include "../../include/entropy.h"
#endif

#ifndef __BPF_DFP_H__
#include "../../dfp.h"
#endif

#ifndef ENABLE_VFS_ITER_WRITE_HOOK
#define ENABLE_VFS_ITER_WRITE_HOOK 1
#endif

#ifndef ENABLE_ENTROPY
#define ENABLE_ENTROPY 1
#endif


char LICENSE[] SEC("license") = "GPL";


// Ringbuffer (override size in userspace if you want)
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024 * 1024); // 256 MiB default
} events SEC(".maps");

#if ENABLE_ENTROPY
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
#endif

static __always_inline int submit_evt(__u8 op, __u64 bytes, __u32 entropy_len, const struct fixed_point *entropy)
{
    // Check if it's an nfsd thread
    if (!is_nfsd()) {
        // Uncomment for debugging filter:
        // bpf_printk("[DEBUG] Not nfsd, skipping event");
        return 0;
    }

    BPF_LOG("[EVENT] op=%u bytes=%llu", op, bytes);

    struct fileops_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) {
        BPF_LOG("[ERROR] Failed to reserve ringbuf space");
        return 0;
    }

    __builtin_memset(e, 0, sizeof(*e));

    e->ts_ns = bpf_ktime_get_ns();
    e->uid   = (__u32)bpf_get_current_uid_gid();

    __u64 pt = bpf_get_current_pid_tgid();
    e->pid   = (__u32)pt;
    e->tgid  = (__u32)(pt >> 32);

    e->op    = op;
    e->bytes = bytes;
    if (entropy) {
        __s32 q = entropy->q;
        if (q < 0)
            q = 0;
        if (q > 31)
            q = 31;

        e->entropy_len = entropy_len;
        e->entropy_valid = 1;
        e->entropy.number = entropy->number;
        e->entropy.q = (__u8)q;
    }

    BPF_LOG("[SUBMIT] uid=%u tgid=%u", e->uid, e->tgid);
    BPF_LOG("[SUBMIT] pid=%u op=%u", e->pid, e->op);
    BPF_LOG("[SUBMIT] bytes=%llu", e->bytes);

    bpf_ringbuf_submit(e, 0);

    return 1;
}

#if ENABLE_ENTROPY
static __u32 calc_entropy(
    struct file *file,
    struct iov_iter *iter,  
    struct fixed_point *entropy_out)
{

    int key = 0;
    struct scratch_t *s = bpf_map_lookup_elem(&scratch_map, &key);
    if (!s)
        return 0;

    u64 bytes_to_send = fill_write_event(s, file, iter);
    if (bytes_to_send == 0)
        return 0;

    struct freq_table *table = bpf_map_lookup_elem(&byte_counts, &key);
    
    if(!CalcEntropy(s, table, entropy_out))
    {
        BPF_LOG("faild entropy calc");
        return 0;
    }
    return (__u32)s->header.len;
}
#endif

#if ENABLE_VFS_ITER_WRITE_HOOK
SEC("fentry/vfs_iter_write")
int BPF_PROG(vfs_iter_write_enter, struct file *file, struct iov_iter *iter)
{
    // Zum lokalen Testen erstmal auskommentieren!
    BPF_LOG("Type von iov_iter%d", BPF_CORE_READ(iter, iter_type) );
    BPF_LOG("--> ENTER vfs_iter_write");
     if (!is_nfsd())
         return 0;


    struct user_stats_t *stats;
    u32 uid = GET_USER_UID();

#if ENABLE_ENTROPY
    // Richtig initialisiertes Struct
    struct fixed_point entropy_in = {}; 
    
    // Adresse übergeben
    __u32 entropy_len = calc_entropy(file, iter, &entropy_in);
    if (entropy_len == 0)
        return 0;

    submit_evt(FILEOPS_OP_WRITE, entropy_len, entropy_len, &entropy_in);
    print_fixed_point("X.YYY", &entropy_in);
    BPF_LOG("--> ENTROPY DONE");
#else
    BPF_LOG("--> ENTROPY DISABLED");
#endif
    return 0;
}
#endif



// OPEN via LSM
SEC("lsm/file_open")
int BPF_PROG(on_open, struct file *file)
{
    if (!is_nfsd())
        return 0;
    BPF_LOG("[HOOK] lsm/file_open triggered");
    if (!submit_evt(FILEOPS_OP_OPEN, 0, 0, 0)) 
        BPF_LOG("[ERROR] Failed to submit open event");
    
    return 0;
}


SEC("lsm/file_permission")
int BPF_PROG(log_file_permission, struct file *file, int mask)
{
    if (!is_nfsd())
        return 0;

#if ENABLE_ENTROPY && ENABLE_VFS_ITER_WRITE_HOOK
    // WRITE wird über vfs_iter_write mit Entropy geliefert.
    if (mask != MAY_READ)
        return 0;
#endif

    BPF_LOG("[HOOK] lsm/file_permission triggered with mask=%d", mask);
    if (!submit_evt(mask == MAY_READ ? FILEOPS_OP_READ : FILEOPS_OP_WRITE, 0, 0, 0))
        BPF_LOG("[ERROR] Failed to submit file_permission event");
    
    return 0;
}
