#ifndef __COMMON_H
#define __COMMON_H


#ifndef __FLAG_H__
#include "flag.h"
#endif

#if STANDALONE
#include "compat.h"
#else
#include <vmlinux.h>
#endif


// Die logische Obergrenze für Daten, die wir erfassen wollen (4KB)
#define MAX_DATA_SIZE 4096U
#define MAX_BYTE_VALUES 256U
#define MAX_USER_COUNT 1024U

#define ENTROPY_THRESHOLD ((struct fixed_point ) { .number = 15, .q = 1 })// 7.5 in decinal, equelas 111.1 in binary, this means afteer the shit we have 1111.0, ,wthile the number before is 8 and bumber of shifts is 1
#define RW_RATIO_LOWER_THRESHOLD ((struct fixed_point ) { .number = 10, .q = 0 }) // Threshold for read/write ratio (e.g., 10:1)
#define RW_RATIO_UPPER_THRESHOLD ((struct fixed_point ) { .number = 10, .q = 0 }) // Threshold for read/write ratio (e.g., 10:1)

// ------------------------------------------------------------
// DAS SMARTE MIN() MAKRO (Mit goto-Optimierung)
// ------------------------------------------------------------

#ifndef is_signed_type
#define is_signed_type(type) (((type)(-1)) < (type)1)
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
    struct bpf_spin_lock lock;
};


struct user_stats_t {
    struct fixed_point read_write_ratio;
    struct entropy_data entropy_data;
    __u64 last_access_ms;
    lock_type stats_lock;  // Protects thread_level and last_access_ms
    __s32 read_count;
    __s32 write_count;
    __s32 open_count;
    __s8 thread_level;
};


#endif /* __COMMON_H */

