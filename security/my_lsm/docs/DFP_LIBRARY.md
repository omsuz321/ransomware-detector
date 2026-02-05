# Dynamic Fixed Point Library (DFP) Documentation

## Overview

The Dynamic Fixed Point Library provides **high-precision arithmetic for eBPF** without hardware floating-point support. It uses fixed-point representation where:

```
value = mantissa × 2^(-q)
```

Where:
- `mantissa`: 32-bit signed integer (-2,147,483,648 to 2,147,483,647)
- `q`: Quantum (fractional bits, 0-31)

Example: `mantissa=256, q=8` → `256 × 2^(-8) = 1.0`

## Core Data Structure

```c
struct fixed_point {
    s32 number;  // Mantissa
    s32 q;       // Quantum (fractional bits)
};
```

## Supported Operations

### Basic Arithmetic
```c
struct fixed_point a = to_fixed_point(10, 8);   // 10.0
struct fixed_point b = to_fixed_point(3, 8);    // 3.0

struct fixed_point sum = add(&a, &b);           // 13.0
struct fixed_point diff = subtract(&a, &b);     // 7.0
struct fixed_point prod = multiply(&a, &b);     // 30.0
struct fixed_point quot = divide(&a, &b);       // 3.333...
```

### Advanced Functions
```c
// Logarithm (natural log, Q8 output)
struct fixed_point log_a = calc_log(&a);

// Absolute value
struct fixed_point abs_a = abs_val(&a);
```

## Key Features

### ✅ Verifier-Safe
- No loops over unknown ranges
- All shifts and casts explicitly bounded
- All operations return consistent s32 values

### ✅ Precision Control
- Quantum `q` determines fractional bits
- Automatic normalization prevents overflow
- Graceful degradation when precision insufficient

### ✅ Cross-Kernel Compatible
- Uses CO-RE (Compile Once, Run Everywhere) principles
- No kernel-version specific code

## Implementation Details

### Quantum Alignment (`check_bit`)

Before operations, both operands are aligned to the same quantum:

```c
struct fixed_point a = to_fixed_point(1, 16);  // Q16
struct fixed_point b = to_fixed_point(2, 8);   // Q8

// check_bit normalizes to Q16
struct fixed_point result = add(&a, &b);
```

### Normalization (`normalize_i64_to_fp`)

After operations, results are normalized to fit in s32:

```c
s64 raw = ...;  // Could be > S32_MAX
s32 q = 16;
normalize_i64_to_fp(&raw, &q);  // Reduces q if needed
```

### Overflow Protection

Hard saturation prevents wraparound:

```c
if (raw > S32_MAX) raw = S32_MAX;
if (raw < S32_MIN) raw = S32_MIN;
```

## Example Usage in BPF Program

```c
#include "../include/bpf/dfp.h"

SEC("kprobe/example")
int example(struct pt_regs *ctx)
{
    // Create fixed-point numbers (Q8 = 256 = 1.0 in decimal)
    struct fixed_point rate = to_fixed_point(256, 8);     // 1.0
    struct fixed_point scale = to_fixed_point(512, 8);    // 2.0
    
    // Scale operation
    struct fixed_point result = multiply(&rate, &scale);  // 2.0
    
    // Extract integer part
    int integer_part = result.number >> result.q;
    
    bpf_printk("Result (mantissa=%d, q=%d) = %d", 
               result.number, result.q, integer_part);
    
    return 0;
}
```

## Precision Guidelines

| Use Case | Quantum (q) | Range | Precision |
|----------|-------------|-------|-----------|
| Percentage (0-100%) | 8 | 0-2^23 | 1/256 |
| Ratio (0-10x) | 16 | 0-2^15 | 1/65536 |
| Small values (<1) | 24 | 0-2^7 | 1/16M |
| Large values (>1000) | 4 | 0-2^27 | 1/16 |

## Performance Notes

- **Addition/Subtraction**: O(1)
- **Multiplication**: O(1) with normalization
- **Division**: O(1) with normalization
- **Logarithm**: O(1) with table lookup
- **Memory**: ~32 bytes per value in register

## Limitations

⚠️ **No floating-point output** - Only fixed-point results
⚠️ **Division by zero** - Returns 0 (graceful)
⚠️ **Precision loss** - Large numbers lose fractional precision
⚠️ **Logarithm input** - Must be > 0 (returns 0 otherwise)

## Comparison with Floating-Point

| Aspect | Fixed-Point (DFP) | Float | Double |
|--------|------------------|-------|--------|
| eBPF Support | ✅ Yes | ❌ No | ❌ No |
| Precision | 32-bit | 32-bit | 64-bit |
| Speed | Fast | N/A | N/A |
| Range | Limited | Huge | Huge |

## Debugging

Print fixed-point values:

```c
bpf_printk("FP(m=%d,q=%d) = %d.%d", fp.number, fp.q,
           fp.number >> fp.q, 
           (fp.number & ((1 << fp.q) - 1)) * 10 / (1 << fp.q));
```

## Integration

Include in any BPF program:

```c
#include "../include/bpf/dfp.h"

// Now you have access to all DFP functions
```
