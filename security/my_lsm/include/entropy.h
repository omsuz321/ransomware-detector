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
    #ifndef __VMLINUX_H__
    #include "vmlinux.h"
    #endif
    
    #ifndef __BPF_HELPERS_H__
    #include <bpf/bpf_helpers.h>
    #endif
#endif

/**
 * entropy_sum_callback - Berechnet den Summanden für Entropie, ohne Reset
 */
static long entropy_sum_callback(__u32 i, struct entropy_ctx *ctx)
{
    if (i >= MAX_BYTE_VALUES) return 0;
    
    __u32 count = (__u32)ctx->table->counts[i];
    if (count == 0) return 0;

    // Fixed-Point Berechnungen
    struct fixed_point c_fp = to_fixed_point((__s32)count, 0);
    struct fixed_point log_c = calc_log(&c_fp);
    struct fixed_point term = multiply(&c_fp, &log_c);

    ctx->sum_result = add(&ctx->sum_result, &term);
    return 0;
}

static long entropy_sum_and_reset_count_callback(__u32 i, struct entropy_ctx *ctx)
{   
    if (i >= MAX_BYTE_VALUES)
        return 0;
    
    entropy_sum_callback(i, ctx);        
    ctx->table->counts[i] = 0;
    return 0;
}

/**
 * calculate_entropy - Berechnet Shannon-Entropie, lässt Tabelle unverändert
 */
static void calculate_entropy(
    struct freq_table *table,
    __u32 total_len, 
    struct fixed_point *out_result,
    int reset)
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

    void* cb = (void*) (reset ? entropy_sum_and_reset_count_callback : entropy_sum_callback);
    bpf_loop(MAX_BYTE_VALUES, cb, &ctx, 0);    

    // Formel anwenden
    struct fixed_point N_fp = to_fixed_point((__s32)total_len, 0);
    struct fixed_point log_N = calc_log(&N_fp);
    struct fixed_point term2 = divide(&ctx.sum_result, &N_fp);
    
    *out_result = subtract(&log_N, &term2);
}

static __always_inline struct fixed_point get_avg_entropy(struct entropy_data *entropy_data)
{
    struct fixed_point divided = { .number = (__s32)entropy_data->count, .q = 0 };
    return divide(&entropy_data->entropy_sum, &divided);
}

static long count_bytes_fast(__u32 i, struct count_ctx *ctx)
{   
    if (i >= MAX_DATA_SIZE) return 0;
    __u8 byte_val = ctx->data_buffer[i];
    ctx->table->counts[byte_val]++;
    return 0;
}

static int CalcEntropy(
    struct scratch_t *s,
    struct freq_table *table,
    struct fixed_point *entropy_out)
{
    __u32 header_len = s->header.len;
    
    if (!table || header_len == 0) 
        return 0;

    struct count_ctx ctx = {
        .table = table,
        .data_buffer = s->data_buffer
    };

    __u32 loop_limit = header_len > MAX_DATA_SIZE ? MAX_DATA_SIZE : header_len;

    bpf_loop(loop_limit, (void *) count_bytes_fast, &ctx, 0);

    //print_human_readable(table);
    //print_preview(s->data_buffer, header_len);
    
    calculate_entropy(table, header_len, entropy_out, 1);
    return 1;
}

#endif /* __ENTROPY_H__ */
