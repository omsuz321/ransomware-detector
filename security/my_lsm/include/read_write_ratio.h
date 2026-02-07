#ifndef __READ_WRITE_RATIO_H
#define __READ_WRITE_RATIO_H

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
#ifndef __COMMON_H
#include "common.h"
#endif

#ifndef __BPF_DFP_H__
#include "dfp.h"
#endif


static __always_inline struct fixed_point calculate_read_write_ratio(__s32 total_written, __s32 total_read)
{
    if (total_written == 0 && total_read == 0)
        return (struct fixed_point){ .number = 0, .q = 0 };
    struct fixed_point written_fp = to_fixed_point(total_written, 0);
    struct fixed_point read_fp = to_fixed_point(total_read, 0);

    return divide(&written_fp, &read_fp);
}

#endif // __READ_WRITE_RATIO_H