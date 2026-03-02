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


static struct fixed_point calculate_read_write_ratio(__s32 total_written, __s32 total_read)
{
    if (total_written == 0 && total_read == 0)
        return (struct fixed_point){ .number = 0, .q = 0 };
    struct fixed_point written_fp = to_fixed_point(total_written, 0);
    struct fixed_point read_fp = to_fixed_point(total_read, 0);
    return divide(&written_fp, &read_fp);
}

//this fun will clacule the symmetiry index
//assuing the numbes are positiv
static __always_inline struct fixed_point symmetry_index(__s32 total_written, __s32 total_read)
{
    if(total_read + total_written == 0)
        return (struct fixed_point){ .number = 0, .q = 0 };

    // abs value of (total_written - total_read) / (total_written + total_read)
    __s32 __dividend = total_written > total_read ? total_written - total_read : total_read - total_written;
    __s32 __divisor = total_read + total_written;
    // Use headroom in Q to preserve fractions in division result
    struct fixed_point dividend = to_fixed_point(__dividend, 17);
    struct fixed_point divisor  = to_fixed_point(__divisor, 17);
    return divide(&dividend, &divisor);
}

#endif /* __READ_WRITE_RATIO_H */