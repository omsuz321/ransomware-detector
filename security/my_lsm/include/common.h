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


// ------------------------------------------------------------
// DAS SMARTE MIN() MAKRO (Mit goto-Optimierung)
// ------------------------------------------------------------

#ifndef is_signed_type
#define is_signed_type(type) (((type)(-1)) < (type)1)
#endif

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



struct fixed_point {
    __s32 number;
    __s32 q;
};

struct freq_table {
    __u16 counts[MAX_BYTE_VALUES];
};


struct entropy_ctx {
    struct fixed_point sum_result;
    struct freq_table *table;
};

struct user_stats_t {
    struct fixed_point read_write_ratio;
    struct fixed_point entropy_sum;
    __u64 read_count;
    __u64 write_count;
    __u8 thread_level;
};

#endif /* __COMMON_H */

