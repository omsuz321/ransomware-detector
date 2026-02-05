#ifndef __COMMON_H
#define __COMMON_H

#ifndef __FLAG_H__
#include "flag.h"
#endif

#if STANDALONE
    #ifndef __COMPAT_H__
    #include "compat.h"
    #endif
#else
    #ifndef __VMLINUX_H__
    #include "vmlinux.h"
    #endif
#endif

// Die logische Obergrenze für Daten, die wir erfassen wollen (4KB)
#define MAX_DATA_SIZE 4096U
#define MAX_BYTE_VALUES 256U

struct fixed_point {
    __s32 number;
    __s32 q;
};

struct entropy_ctx {
    struct freq_table *table;
    struct fixed_point sum_result;
};

struct freq_table {
    __u16 counts[MAX_BYTE_VALUES];
};

#endif /* __COMMON_H */

