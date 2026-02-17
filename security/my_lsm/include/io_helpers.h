#ifndef __IO_HELPERS_H__
#define __IO_HELPERS_H__

#ifndef __COMMON_H
#include "common.h"
#endif

#ifndef __VMLINUX_H__
#include <vmlinux.h>
#endif

#ifndef __BPF_HELPERS_
#include <bpf/bpf_helpers.h>
#endif

#ifndef __BPF_CORE_READ_H__
#include <bpf/bpf_core_read.h>
#endif

#ifndef AIRBAG_SIZE
#define AIRBAG_SIZE (MAX_DATA_SIZE * 2)
#endif

#ifndef UIO_MAXIOV
#define UIO_MAXIOV 1024
#endif

/* * Struct definitions 
 * Split header and payload to satisfy BPF verifier constraints regarding
 * variable-sized access and map value sizes.
 */

struct write_event_hdr {
    __u32 pid;
    __u32 uid;
    __u32 len;          
    __u64 requested;    
    char  fname[256];
};

struct write_event {
    struct write_event_hdr hdr;
    __u8  data[]; 
};

#ifndef SCRATCH_MAP_SIZE
#define SCRATCH_MAP_SIZE (sizeof(struct write_event_hdr) + AIRBAG_SIZE)
#endif

struct scratch_t {
    struct write_event_hdr header;
    __u8 data_buffer[AIRBAG_SIZE];
};

struct count_ctx {
    struct freq_table *table;
    __u8 *data_buffer;
};

struct copy_ctx {
    struct scratch_t *scratch;
    struct iov_iter *iter;
    size_t current_seg_offset;
    size_t total_requested;
    __u32 bytes_copied;
};

/* Helper functions */

static  void get_filename(struct file *file, char *out, __u32 out_size)
{
    struct dentry *dentry = BPF_CORE_READ(file, f_path.dentry);
    const unsigned char *name = BPF_CORE_READ(dentry, d_name.name);
    bpf_probe_read_kernel_str(out, out_size, name);
}

/* * Copies a single kvec segment to the scratch buffer.
 * Returns 1 if buffer is full, 0 otherwise.
 */
static  long copy_single_segment(__u32 seg_idx, struct copy_ctx *ctx)
{
    if (ctx->bytes_copied >= MAX_DATA_SIZE) 
        return 1;

    struct iov_iter *iter = ctx->iter; 
    const struct kvec *kvec = BPF_CORE_READ(iter, kvec);
    
    void *base = NULL;
    size_t len = 0;
    
    BPF_CORE_READ_INTO(&base, &kvec[seg_idx], iov_base);
    BPF_CORE_READ_INTO(&len,  &kvec[seg_idx], iov_len);

    size_t offset = ctx->current_seg_offset; 
    
    if (!base || len == 0 || offset >= len) return 0;

    size_t data_in_seg = len - offset;
    __u32 space_left = MAX_DATA_SIZE - ctx->bytes_copied;
    size_t remaining_request = ctx->total_requested - ctx->bytes_copied;
    
    __u32 to_copy = (__u32)(min(data_in_seg, space_left));
    to_copy = (__u32)(min(to_copy, remaining_request));

    bpf_probe_read_kernel(
        &ctx->scratch->data_buffer[ctx->bytes_copied],
        to_copy,
        (char*)base + offset
    );

    ctx->bytes_copied += to_copy;

    return (ctx->bytes_copied >= MAX_DATA_SIZE) ? 1 : 0;
}

/* bpf_loop callback for segments 1..N */
static long loop_callback_rest(__u32 i, struct copy_ctx *ctx)
{
    return copy_single_segment(i + 1, ctx);
}

static long count_bytes_fast(__u32 i, struct count_ctx *ctx)
{   
    if (i >= MAX_DATA_SIZE) return 0;
    __u8 byte_val = ctx->data_buffer[i];
    ctx->table->counts[byte_val]++;
    return 0;
}

/* Main logic */

static u64 fill_write_event(struct scratch_t *s, struct file *file, struct iov_iter *iter)
{
    if (BPF_CORE_READ(iter, iter_type) != ITER_KVEC) 
        return 0;

    s->header.pid = bpf_get_current_pid_tgid() >> 32;
    s->header.uid = (__u32)bpf_get_current_uid_gid();
    u64 requested = BPF_CORE_READ(iter, count);
    s->header.requested = requested;
    s->header.len = 0; 
    s->header.fname[0] = '\0';
    
    get_filename(file, s->header.fname, sizeof(s->header.fname));
    unsigned long nr_segs = BPF_CORE_READ(iter, nr_segs);
    if (nr_segs > UIO_MAXIOV) nr_segs = UIO_MAXIOV;

    struct copy_ctx ctx = {
        .scratch = s,
        .iter = iter,
        .current_seg_offset = BPF_CORE_READ(iter, iov_offset),
        .total_requested = requested,
        .bytes_copied = 0
    };

    /* Process first segment (taking offset into account) */
    long buffer_full = copy_single_segment(0, &ctx);
    
    /* Process remaining segments if buffer space allows */
    if (!buffer_full && nr_segs > 1) {
        ctx.current_seg_offset = 0;
        bpf_loop((__u32)(nr_segs - 1), (void*) loop_callback_rest, &ctx, 0);
    }
    
    s->header.len = ctx.bytes_copied;
    

    u64 bytes_to_send = sizeof(struct write_event_hdr) + s->header.len;
    if (bytes_to_send > SCRATCH_MAP_SIZE) bytes_to_send = SCRATCH_MAP_SIZE;

    return bytes_to_send;
}

static void print_preview(void *data_ptr, u32 len)
{
    char msg[12]; 
    __builtin_memset(msg, 0, sizeof(msg));
    if (len > 10) len = 10;
    bpf_probe_read_kernel(msg, len, data_ptr);
    msg[len] = '\0';  // Ensure null-termination
    bpf_printk("CONTENT: |%s|", msg);
}

#endif /* __IO_HELPERS_H__ */