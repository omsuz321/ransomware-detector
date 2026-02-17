
#ifndef LEAKY_BUCKET_H
#define LEAKY_BUCKET_H

#include "common.h"
#ifndef __FLAG_H__
#include "flag.h"
#endif
#if STANDALONE
    #ifndef __COMPAT_H__
    #include "compat.h"
    #endif
#else
    #ifndef __VMLINUX_H__
    #include <vmlinux.h>
    #endif
    
    #ifndef __BPF_HELPERS_
    #include <bpf/bpf_helpers.h>
    #endif
#endif

#define BUCKET_CAPACITY 200
#define LEAK_RATE 5 // open()/s

//funktioniert wie erwartet
static __always_inline void run_leaky_bucket(struct user_stats_t *stats)
{
    stats->used_bucket_capacity += stats->open_count;
    bpf_printk("Leaky bucket: used_bucket_capacity=%u, open_count=%u", stats->used_bucket_capacity, stats->open_count);
    stats->open_count = 0;
    stats->used_bucket_capacity = stats->used_bucket_capacity - LEAK_RATE < 0 
        ? 0 
        : stats->used_bucket_capacity - LEAK_RATE;
}
#endif