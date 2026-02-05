// =============================================================================
// ENTROPY CALCULATION EXTENSION (AUTO-RESET VERSION)
// =============================================================================



#ifndef __ENTROPY_H__
#define __ENTROPY_H__

#ifndef __FLAG_H__
#include "flag.h"
#endif

    #ifndef __COMMON_H
    #include "common.h"
    #endif 

    #ifndef __BPF_DFP_H__
    #include "dfp.h"
    #endif

#if STANDALONE
    #ifndef __COMPAT_H__
    #include "compat.h"
    #endif
#else

    #ifndef __BPF_HELPERS_
    #include <bpf/bpf_helpers.h>
    #endif

#endif



/**
 * entropy_sum_callback_reset - Berechnet UND LÖSCHT DEN EINTRAG
 */
static long entropy_sum_callback(__u32 i, struct entropy_ctx *ctx)
{
    if (i >= MAX_BYTE_VALUES) return 0;
    
    __u32 count = (__u32)ctx->table->counts[i];
    
    // ====================================================
    // RESET ZU 0 (Clear-on-Read)
    // ====================================================
    ctx->table->counts[i] = 0;

    if (count == 0) return 0;

    // Fixed-Point Berechnungen
    struct fixed_point c_fp = to_fixed_point((__s32)count, 0);
    struct fixed_point log_c = calc_log(&c_fp);
    struct fixed_point term = multiply(&c_fp, &log_c);

    ctx->sum_result = add(&ctx->sum_result, &term);
    return 0;
}

/**
 * calculate_entropy - Berechnet Shannon-Entropie, speichert sie und setzt Tabelle zurück
 */
static __always_inline void calculate_entropy(struct freq_table *table, __u32 total_len, struct fixed_point *out_result)
{
    if (total_len == 0) {
        out_result->number = 0;
        out_result->q = 0;
        return;
    }

    struct entropy_ctx ctx = {
        .table = table,
        .sum_result = {0, 0}
    };
    
    // Loop führt jetzt Berechnung UND Reset durch
    bpf_loop(MAX_BYTE_VALUES, (void* )entropy_sum_callback, &ctx, 0);

    // Formel anwendens
    struct fixed_point N_fp = to_fixed_point((__s32)total_len, 0);
    struct fixed_point log_N = calc_log(&N_fp);
    struct fixed_point term2 = divide(&ctx.sum_result, &N_fp);
    
    *out_result = subtract(&log_N, &term2);
}

#endif /*  */