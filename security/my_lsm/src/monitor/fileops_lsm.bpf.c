// SPDX-License-Identifier: GPL-2.0
#include "../include/vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_tracing.h>
#include "common.h"
#include "fileops_common.h"

char LICENSE[] SEC("license") = "GPL";


// Ringbuffer (override size in userspace if you want)
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024 * 1024); // 256 MiB default
} events SEC(".maps");



static __always_inline int submit_evt(__u8 op, __u64 bytes)
{
    // Check if it's an nfsd thread
    if (!is_nfsd()) {
        // Uncomment for debugging filter:
        // bpf_printk("[DEBUG] Not nfsd, skipping event");
        return 0;
    }

    bpf_printk("[EVENT] op=%u bytes=%llu", op, bytes);

    struct fileops_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e) {
        bpf_printk("[ERROR] Failed to reserve ringbuf space");
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

    bpf_printk("[SUBMIT] uid=%u tgid=%u", e->uid, e->tgid);
    bpf_printk("[SUBMIT] pid=%u op=%u", e->pid, e->op);
    bpf_printk("[SUBMIT] bytes=%llu", e->bytes);

    bpf_ringbuf_submit(e, 0);

    return 1;
}
// OPEN via LSM
SEC("lsm/file_open")
int BPF_PROG(on_open, struct file *file)
{
    if (!is_nfsd())
        return 0;
    
    bpf_printk("[HOOK] lsm/file_open triggered");
    if (!submit_evt(FILEOPS_OP_OPEN, 0)) {
        bpf_printk("[ERROR] Failed to submit open event");
    }
    return 0;
}

// READ bytes via fentry/vfs_iter_read
SEC("fentry/vfs_iter_read")
int BPF_PROG(on_vfs_iter_read, struct file *file, struct iov_iter *iter,
             loff_t *ppos, rwf_t flags)
{
    if (!is_nfsd())
        return 0;
    
    __u64 cnt = BPF_CORE_READ(iter, count);
    bpf_printk("[HOOK] fentry/vfs_iter_read count=%llu", cnt);
    if (!submit_evt(FILEOPS_OP_READ, cnt)) {    
        bpf_printk("[ERROR] Failed to submit read event");
    }
    return 0;
}

SEC("fentry/vfs_splice_read")
int BPF_PROG(on_vfs_splice_read, struct file *in, loff_t *ppos,
             struct pipe_inode_info *pipe, size_t len, unsigned int flags)
{
    if (!is_nfsd())
        return 0;
    
    bpf_printk("[HOOK] fentry/vfs_splice_read len=%zu", len);
    if (!submit_evt(FILEOPS_OP_READ, (__u64)len)) {
        bpf_printk("[ERROR] Failed to submit splice read event");
    }
    return 0;
}


// WRITE bytes via fentry/vfs_iter_write
SEC("fentry/vfs_iter_write")
int BPF_PROG(on_vfs_iter_write, struct file *file, struct iov_iter *iter)
{
    if (!is_nfsd())
        return 0;
    
    __u64 cnt = BPF_CORE_READ(iter, count);
    bpf_printk("[HOOK] fentry/vfs_iter_write count=%llu", cnt);
    if (!submit_evt(FILEOPS_OP_WRITE, cnt)) {
        bpf_printk("[ERROR] Failed to submit write event");
    }
    return 0;
}

SEC("lsm/file_permission")
int BPF_PROG(log_file_permission, struct file *file, int mask)
{
    if (!is_nfsd())
        return 0;
    
    bpf_printk("[HOOK] lsm/file_permission triggered with mask=%d", mask);
    if (!submit_evt(mask == MAY_READ ? FILEOPS_OP_READ : FILEOPS_OP_WRITE, 0)) {
        bpf_printk("[ERROR] Failed to submit file_permission event");
    }
    return 0;
}
