// =============================================================================
// DYNAMIC FIXED POINT LIBRARY (DFP) - eBPF Safe
// =============================================================================
// High-precision arithmetic for eBPF without floating point
// Supports: Addition, Subtraction, Multiplication, Division, Logarithm, Entropy
// =============================================================================

#ifndef __BPF_DFP_H__
#define __BPF_DFP_H__

#ifndef __FLAG_H__
#include "flag.h"
#endif


#if STANDALONE
    #ifndef __COMPAT_H__
    #include "compat.h"
    #endif

    #ifndef __COMMON_H__ 
    #include "common.h"
    #endif
#else
    #ifndef __VMLINUX_H__
    #include "vmlinux.h"
    #endif

    #ifndef __BPF_HELPERS_
    #include <bpf/bpf_helpers.h>
    #endif
    
    #ifndef __COMMON_H__ 
    #include "common.h"
    #endif

#endif


// ============================================================================
// Configuration & Macros
// ============================================================================

#define S32_MAX  2147483647
#define S32_MIN (-2147483647 - 1)

#define A_IS_GRATHER_B(a, b) (fp_compare(a, b) == 1)
#define A_IS_LESS_B(a, b) (fp_compare(a, b) == -1)
#define A_IS_GREATER_OR_EQUAL_B(a, b) (fp_compare(a, b) != -1)
#define A_IS_LESS_OR_EQUAL_B(a, b) (fp_compare(a, b) != 1)



// ============================================================================
// Helper Functions - Bit Operations
// ============================================================================

static int count_zero_64(__u64 x)
{
    if (x == 0) return 64;
    int count = 0;
    #pragma unroll
    for (int i = 63; i >= 0; i--) {
        if ((x >> i) & 1) break;
        count++;
    }
    return count;
}

static int count_zero_32(__u32 x)
{
    if (x == 0) return 32;
    int count = 0;
    #pragma unroll
    for (int i = 31; i >= 0; i--) {
        if ((x >> i) & 1) break;
        count++;
    }
    return count;
}

static __u64 mag_u64_from_s64(__s64 v)
{
    __u64 u = (__u64)v;
    if (v >= 0) return u;
    return (~u) + 1;
}

// ============================================================================
// Helper Functions - Arithmetic Shifts
// ============================================================================

static __s64 arshift_s64(__s64 v, int sh)
{
    if (sh <= 0) return v;
    if (sh >= 63) return (v < 0) ? (__s64)-1 : (__s64)0;
    
    __u64 u = (__u64)v;
    __u64 shifted = u >> sh;
    if (v >= 0) return (__s64)shifted;
    
    __u64 mask = ~( (~(__u64)0) >> sh );
    return (__s64)(shifted | mask);
}

static __s32 arshift_s32(__s32 v, int sh)
{
    if (sh <= 0) return v;
    if (sh >= 31) return (v < 0) ? (__s32)-1 : (__s32)0;
    
    __u32 u = (__u32)v;
    __u32 shifted = u >> sh;
    if (v >= 0) return (__s32)shifted;
    
    __u32 mask = ~( (~(__u32)0) >> sh );
    return (__s32)(shifted | mask);
}

// ============================================================================
// Core Normalization & Conversion
// ============================================================================

static void normalize_i64_to_fp(__s64 *raw_ptr, __s32 *q_ptr)
{
    __s64 raw = *raw_ptr;
    __s32 q = *q_ptr;

    if (raw == 0) {
        *raw_ptr = 0;
        return;
    }

    __u64 mag = mag_u64_from_s64(raw);
    int bits = 64 - count_zero_64(mag);
    int need = (bits > 31) ? (bits - 31) : 0;

    if (need > 0) {
        if (need > q) need = q;
        raw = arshift_s64(raw, need);
        q -= need;
    }

    if (raw > (__s64)S32_MAX) raw = (__s64)S32_MAX;
    if (raw < (__s64)S32_MIN) raw = (__s64)S32_MIN;

    *raw_ptr = raw;
    *q_ptr = q;
}

static int can_scale_left_to_i32(__s32 v, int sh)
{
    if (sh <= 0) return 1;
    if (sh >= 31) return 0;
    __s32 limit_pos = S32_MAX >> sh;
    __s32 limit_neg = S32_MIN >> sh;
    return (v <= limit_pos && v >= limit_neg);
}

static struct fixed_point to_fixed_point(__s32 value, __s32 q)
{
    if (q < 0)  q = 0;
    if (q > 31) q = 31;
    
    __s64 raw = (__s64)value * ((__s64)1 << q);
    __s32 final_q = q;
    normalize_i64_to_fp(&raw, &final_q);
    
    struct fixed_point r = { .number = (__s32)raw, .q = final_q };
    return r;
}

// ============================================================================
// Quantum Alignment
// ============================================================================

static void check_bit(struct fixed_point *first, struct fixed_point *second)
{
    if (first->q > second->q) {
        int diff = first->q - second->q;
        if (diff <= 0) return;
        if (diff > 31) diff = 31;

        if (can_scale_left_to_i32(second->number, diff)) {
            __s64 scaled = (__s64)second->number * ((__s64)1 << diff);
            second->number = (__s32)scaled;
            second->q = first->q;
        } else {
            first->number = arshift_s32(first->number, diff);
            first->q = second->q;
        }
    } else if (second->q > first->q) {
        int diff = second->q - first->q;
        if (diff <= 0) return;
        if (diff > 31) diff = 31;

        if (can_scale_left_to_i32(first->number, diff)) {
            __s64 scaled = (__s64)first->number * ((__s64)1 << diff);
            first->number = (__s32)scaled;
            first->q = second->q;
        } else {
            second->number = arshift_s32(second->number, diff);
            second->q = first->q;
        }
    }
}

// ============================================================================
// Arithmetic Operations
// ============================================================================

static struct fixed_point add(struct fixed_point *first, struct fixed_point *second)
{
    struct fixed_point f = *first;
    struct fixed_point s = *second;
    check_bit(&f, &s);
    
    __s64 sum = (__s64)f.number + (__s64)s.number;
    normalize_i64_to_fp(&sum, &f.q);
    
    struct fixed_point result = { .number = (__s32)sum, .q = f.q };
    return result;
}

static  struct fixed_point subtract(struct fixed_point *first, struct fixed_point *second)
{
    struct fixed_point f = *first;
    struct fixed_point s = *second;
    check_bit(&f, &s);
    
    __s64 diff = (__s64)f.number - (__s64)s.number;
    normalize_i64_to_fp(&diff, &f.q);
    
    struct fixed_point result = { .number = (__s32)diff, .q = f.q };
    return result;
}

static  struct fixed_point multiply(struct fixed_point *first, struct fixed_point *second)
{
    struct fixed_point f = *first;
    struct fixed_point s = *second;
    check_bit(&f, &s);
    
    __s32 q = f.q;
    __s64 prod = (__s64)f.number * (__s64)s.number;
    
    __s64 raw = arshift_s64(prod, q);
    normalize_i64_to_fp(&raw, &q);
    
    struct fixed_point result = { .number = (__s32)raw, .q = q };
    return result;
}

static struct fixed_point divide(struct fixed_point *first, struct fixed_point *second)
{
    struct fixed_point f = *first;
    struct fixed_point s = *second;
    check_bit(&f, &s);
    
    if (s.number == 0) {
        struct fixed_point err = { .number = 0, .q = f.q };
        return err;
    }
    
    __s64 num = (__s64)f.number * ((__s64)1 << f.q);

    /* BPF disallows signed div; perform unsigned div on magnitudes and restore sign. */
    __u64 abs_num = mag_u64_from_s64(num);
    __u64 abs_den = mag_u64_from_s64((__s64)s.number);
    __u64 unsigned_raw = abs_num / abs_den;

    __s64 raw = (__s64)unsigned_raw;
    if ((f.number < 0) ^ (s.number < 0)) raw = -raw;
    
    __s32 final_q = f.q;
    normalize_i64_to_fp(&raw, &final_q);
    
    struct fixed_point result = { .number = (__s32)raw, .q = final_q };
    return result;
}

// ============================================================================
// Advanced Functions - Logarithm
// ============================================================================

static const __u32 log_table[256] = {
    0, 94364, 188362, 281996, 375269, 468184, 560744, 652952, 744809, 836319, 927485, 1018308, 1108792, 1198939, 1288751, 1378232,
    1467382, 1556206, 1644705, 1732881, 1820738, 1908276, 1995500, 2082410, 2169009, 2255299, 2341283, 2426962, 2512339, 2597416,
    2682195, 2766679, 2850868, 2934765, 3018373, 3101693, 3184727, 3267477, 3349946, 3432134, 3514044, 3595678, 3677037, 3758124,
    3838940, 3919487, 3999767, 4079782, 4159533, 4239022, 4318251, 4397221, 4475935, 4554393, 4632598, 4710551, 4788254, 4865708,
    4942915, 5019877, 5096595, 5173070, 5249304, 5325299, 5401057, 5476578, 5551863, 5626916, 5701736, 5776326, 5850687, 5924820,
    5998727, 6072408, 6145866, 6219102, 6292117, 6364912, 6437489, 6509849, 6581994, 6653924, 6725640, 6797145, 6850401, 6939525,
    7010401, 7081071, 7151535, 7221795, 7291851, 7361705, 7431358, 7500811, 7570066, 7639123, 7707983, 7776648, 7845119, 7913396,
    7981482, 8049377, 8117081, 8184597, 8251925, 8319066, 8386022, 8452793, 8519380, 8585784, 8652007, 8718049, 8783912, 8849595,
    8915101, 8980430, 9045583, 9110562, 9175366, 9239997, 9304456, 9368744, 9432862, 9496810, 9560590, 9624202, 9687648, 9750927,
    9814042, 9876992, 9939779, 10002404, 10064867, 10127169, 10189311, 10251295, 10313119, 10374787, 10436297, 10497652, 10558851,
    10619897, 10680788, 10741527, 10802114, 10862549, 10922834, 10982970, 11042956, 11102794, 11162484, 11222027, 11281425, 11340677,
    11399784, 11458747, 11517567, 11576245, 11634780, 11693174, 11751428, 11809542, 11867516, 11925353, 11983051, 12040612, 12098036,
    12155325, 12212478, 12269497, 12326381, 12383133, 12439751, 12496238, 12552593, 12608817, 12664910, 12720874, 12776709, 12832415,
    12887994, 12943445, 12998769, 13053968, 13109040, 13163988, 13218811, 13273510, 13328086, 13382539, 13436870, 13491079, 13545167,
    13599135, 13652982, 13706710, 13760319, 13813810, 13867182, 13920437, 13973575, 14026597, 14079503, 14132293, 14184969, 14237530,
    14289977, 14342311, 14394532, 14446641, 14498637, 14550522, 14602296, 14653960, 14705514, 14756958, 14808293, 14859519, 14910637,
    14961647, 15012550, 15063347, 15114037, 15164620, 15215099, 15265472, 15315741, 15365906, 15415967, 15465924, 15515779, 15565531,
    15615181, 15664729, 15714177, 15763523, 15812769, 15861915, 15910961, 15959909, 16008757, 16057507, 16106159, 16154714, 16203171,
    16251532, 16299796, 16347964, 16396036, 16444013, 16491895, 16539683, 16587376, 16634976, 16682482, 16729895
};

//calcualte log2(x)
static __always_inline struct fixed_point calc_log(struct fixed_point *number)
{
    struct fixed_point r = { .number = 0, .q = 8 };
    if (number->number <= 0) return r;

    __s32 q_in = number->q;
    if (q_in < 0)  q_in = 0;
    if (q_in > 24) q_in = 24;

    __u32 x = (__u32)number->number;
    int lz = count_zero_32(x);
    if (lz < 0 || lz > 31) return r;

    __u32 idx;
    if (lz >= 31) idx = 0;
    else          idx = (__u32)((x << (lz + 1)) >> 24);

    __s32 exp = (__s32)(31 - q_in - lz);
    
    __s64 exp_term_q24 = (__s64)exp * ((__s64)1 << 24);
    __u32 frac_q24 = log_table[idx];
    __s64 raw_q24 = exp_term_q24 + (__s64)frac_q24;

    __s64 raw_q8 = arshift_s64(raw_q24, 16);
    
    if (raw_q8 > (__s64)S32_MAX) raw_q8 = (__s64)S32_MAX;
    if (raw_q8 < (__s64)S32_MIN) raw_q8 = (__s64)S32_MIN;

    r.number = (__s32)raw_q8;
    return r;
}

static struct fixed_point abs_val(struct fixed_point *number)
{
    struct fixed_point res = *number;
    if (res.number == (__s32)S32_MIN) res.number = S32_MAX;
    else if (res.number < 0)        res.number = -res.number;
    return res;
}

// ============================================================================
// Comparison Operations
// ============================================================================

/* * fp_compare: Compares two fixed point numbers safely.
 * Returns:
 * 1 if a > b
 * -1 if a < b
 * 0 if a == b
 */
static int fp_compare(struct fixed_point *a, struct fixed_point *b)
{
    // 1. Make local copies so we don't modify the originals
    struct fixed_point ta = *a;
    struct fixed_point tb = *b;

    // 2. Align them to the same Q-Factor using library's helper
    check_bit(&ta, &tb);

    // 3. Compare the raw integer values
    if (ta.number > tb.number) return 1;
    if (ta.number < tb.number) return -1;
    return 0;
}

/**
 * print_fixed_point - Hilfsfunktion: Gibt Fixed-Point als "X.YYY" im Log aus
 */
static void print_fixed_point(const char* prefix, struct fixed_point *fp)
{
    __s32 integer_part = arshift_s32(fp->number, fp->q);
    __u32 mask = (fp->q >= 31) ? 0x7fffffffU : ((1U << fp->q) - 1U);
    __u64 mag = mag_u64_from_s64((__s64)fp->number);
    __u32 fractional_bits = (__u32)mag & mask;

    // Umrechnung auf 3 Dezimalstellen
    __u64 frac_calc = (__u64)fractional_bits * 1000ULL;
    __u32 decimal_part = (fp->q == 0) ? 0U : (__u32)(frac_calc >> fp->q);

    bpf_printk("%s: %d.%03u", prefix, integer_part, decimal_part);
}

#endif // __BPF_DFP_H__