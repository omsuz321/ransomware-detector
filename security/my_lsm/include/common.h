#ifndef __COMMON_H
#define __COMMON_H


#ifndef __FLAG_H__
#include "flag.h"
#endif

#if STANDALONE
    #include "compat.h"
#else
    #ifndef __VMLINUX_H__
    #include "vmlinux.h"
    #endif
    
    #ifndef __BPF_HELPERS_H__
    #include <bpf/bpf_helpers.h>
    #endif
#endif


// Die logische Obergrenze für Daten, die wir erfassen wollen (4KB)
#define MAX_DATA_SIZE 4096U
#define MAX_BYTE_VALUES 256U
#define MAX_USER_COUNT 1024U

// Define file permission constants

#define MAY_READ 0x00000004
#define MAY_WRITE 0x00000002

#define COMM_SIZE 16
// ungefähr entpsicht 0.302260
#define RW_SYMMERTY_TOLLERANCE ((struct fixed_point ) { .number = 316942, .q = 20 })
#define ENTROPY_THRESHOLD ((struct fixed_point ) { .number = 15, .q = 1 })// 7.5 in decinal, equelas 111.1 in binary, this means afteer the shit we have 1111.0, ,wthile the number before is 8 and bumber of shifts is 1

#define EPERM   1  /* Operation not permitted (Fehlende Rechte/Root) */
#define ENOENT  2  /* No such file or directory (Datei existiert nicht) */
#define EACCES  13 /* Permission denied (Zugriff vom LSM verweigert) */
#define EINVAL  22 /* Invalid argument (Falsche Parameter) */





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



#ifndef SCRATCH_MAP_SIZE
#define SCRATCH_MAP_SIZE (sizeof(struct write_event_hdr) + AIRBAG_SIZE)
#endif


// Stage 1: Screening (Rasterfahndung)
//#define STAGE_SCREENING   0  
// Stage 2: Investigation (Beweissicherung)
#define STAGE_INVESTIGATION     1  
// Stage 3: Verdict (Urteilsfindung)
#define STAGE_VERDICT 2  
#define BLOCK_ACTION 3

//#define SCREENING_INTERVAL_MS 1000ULL
#define INVESTIGATION_INTERVAL_MS 2500ULL
#define VERDICT_INTERVAL_MS 2500ULL

// Consecutive hit thresholds per stage
#ifndef INVESTIGATION_STREAK_K
#define INVESTIGATION_STREAK_K 2
#endif

#ifndef VERDICT_STREAK_K
#define VERDICT_STREAK_K 3
#endif



#ifndef is_signed_type
#define is_signed_type(type) (((type)(-1)) < (type)1)
#endif

#define NFSD_MAGIC (__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__ ? 0x6473666E : 0x6E667364)

#define BPF_KTIME_GET_MS() (bpf_ktime_get_ns() / 1000000ULL)



/* DEBUG_LOG is controlled via build flag (default: off). */
#ifndef DEBUG_LOG
#define DEBUG_LOG 0
#endif

#if DEBUG_LOG
#define BPF_LOG(fmt, ...) bpf_printk(fmt, ##__VA_ARGS__)
#define PRINT_FIXED_POINT(prefix, fp) print_fixed_point(prefix, fp)
#else
#define BPF_LOG(fmt, ...) ((void)0)
#define PRINT_FIXED_POINT(prefix, fp) ((void)0)
#endif

/**
 * Selects the optimal bit-width for atomic operations to prevent LLVM backend crashes.
 * 
 * BPF ISA versions below v3 do not natively support 32-bit atomic compare-and-swap (CAS).
 * Using a 64-bit type (u64) on 64-bit architectures ensures the compiler can map 
 * lock acquisitions to supported 'atomic64_cmpxchg' instructions, avoiding the 
 * "unsupported atomic operation" error during compilation.
 */
#if __SIZEOF_POINTER__ == 8
    typedef __u64 lock_type;
#else
    typedef __u32 lock_type;
#endif

struct fixed_point {
    __s32 number;
    __s32 q;
};



#define __IS_NEG(v) (is_signed_type(__typeof__(v)) && (v) < 0)

#ifndef min
#define min(x, y) ({ \
    __typeof__(x) _x = (x); \
    __typeof__(y) _y = (y); \
    __typeof__(_x + _y) _res; \
    if (__IS_NEG(_x))      _res = _x; \
    else if (__IS_NEG(_y)) _res = _y; \
    else                   _res = (_x < _y) ? _x : _y; \
    _res; \
})
#endif

struct freq_table {
    __u16 counts[MAX_BYTE_VALUES];
};


struct entropy_ctx {
    struct fixed_point sum_result;
    struct freq_table *table;
};

struct entropy_data{
    struct fixed_point entropy_sum;
    __u32 count;
    __u8 k_streak;
    struct bpf_spin_lock lock;
};


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

#define GET_USER_UID() (__u32)bpf_get_current_uid_gid()

struct io_stats {
    __s32 read_count;
    __s32 write_count;
    __s32 open_count;
    __u8  k_streak;
};

struct user_stats_t {
    struct entropy_data entropy_data;
    __u64 last_access_ms;
    __u64 created_ms;
    volatile lock_type stats_lock;  // Protects thread_level and last_access_ms
    struct io_stats io_stats;
    __s32 used_bucket_capacity;
    __s8 thread_level;
};

static void print_stats(struct user_stats_t *stats, __u32 uid)
{
    BPF_LOG("UID %u | open count: %d, bucket: %d, tl: %d", 
        uid, stats->io_stats.open_count, stats->used_bucket_capacity, stats->thread_level);
    BPF_LOG("UID %u | read count: %d, write count: %d", 
        uid, stats->io_stats.read_count, stats->io_stats.write_count);
    BPF_LOG("last access: %llu lock: %d", stats->last_access_ms, stats->stats_lock);
}

#if !STANDALONE
static int is_nfsd(void) {

    char comm[COMM_SIZE];
    
    __builtin_memset(comm, 0, COMM_SIZE);
    if (bpf_get_current_comm(&comm, COMM_SIZE) < 0) 
        return 0; 
    
    return (*(unsigned int *)comm == NFSD_MAGIC);
}
#endif





#endif /* __COMMON_H */
