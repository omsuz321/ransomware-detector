# DFP Test Suite Documentation

## Overview

This directory contains comprehensive tests and examples for the Dynamic Fixed Point (DFP) library used in eBPF programs. The test suite validates all 7 core operations and demonstrates practical usage patterns.

## Directory Structure

```
tests/dfp/
├── dfp_tests.bpf.c          # 10 core operation tests
├── dfp_examples.bpf.c       # 5 practical usage examples
├── Makefile                 # Build and test management
└── README.md                # This file
```

## Test Programs

### 1. dfp_tests.bpf.c
**Purpose**: Core validation of DFP library operations

**Tests Included**:

#### TEST_1: Basic Conversion
- **Operation**: `to_fixed_point(256, 8)` → Q8 representation
- **Expected**: Correctly converts integer to fixed-point format
- **Validation**: mantissa = 256, quantum = 8

#### TEST_2: Addition
- **Operation**: `1.0 + 2.0`
- **Expected**: Result = 3.0 (Q16)
- **Validation**: Verifies `add()` correctness

#### TEST_3: Subtraction
- **Operation**: `5.0 - 3.0`
- **Expected**: Result = 2.0 (Q16)
- **Validation**: Verifies `subtract()` correctness

#### TEST_4: Multiplication
- **Operation**: `2.0 × 3.0`
- **Expected**: Result = 6.0 (Q16)
- **Validation**: Verifies `multiply()` correctness and Q-tracking

#### TEST_5: Division
- **Operation**: `6.0 ÷ 2.0`
- **Expected**: Result = 3.0 (Q16)
- **Validation**: Verifies `divide()` correctness

#### TEST_6: Division by Zero
- **Operation**: `5.0 ÷ 0.0`
- **Expected**: Result = 0 (graceful handling)
- **Validation**: No crash, returns safe value

#### TEST_7: Absolute Value
- **Operation**: `abs(-1.0)`
- **Expected**: Result = 1.0 (Q16)
- **Validation**: Verifies `abs_val()` correctness

#### TEST_8: Quantum Alignment
- **Operation**: Combine Q8 and Q9 fixed-point numbers
- **Expected**: Automatic quantum normalization
- **Validation**: Operations maintain precision across quantum levels

#### TEST_9: Logarithm
- **Operation**: `ln(e)` ≈ 1.0
- **Expected**: Result ≈ 1.0
- **Validation**: Table-based log calculation accuracy

#### TEST_10: Overflow Handling
- **Operation**: Extreme values without wraparound
- **Expected**: Saturates to max/min values
- **Validation**: No silent overflow, explicit saturation

**Results**: All tests output via ringbuffer `test_results` map

### 2. dfp_examples.bpf.c
**Purpose**: Practical usage scenarios in eBPF context

**Examples Included**:

#### Example 1: File I/O Performance Monitoring
**Use Case**: Monitor write operation efficiency
- Calculates efficiency ratio: `bytes_written / bytes_requested`
- Calculates throughput: `bytes / duration`
- **Output**: Metrics logged with `bpf_printk`

#### Example 2: Anomaly Detection
**Use Case**: Compare current metrics against baseline
- Baseline: 100 bytes/ms, 50% efficiency
- Current: 10 bytes/ms, 25% efficiency (anomaly!)
- **Detection**: Deviation analysis with thresholds
- **Output**: Anomaly alerts when thresholds exceeded

#### Example 3: Composite Scoring
**Use Case**: Calculate weighted score from multiple metrics
- Weights: Reliability 50%, Throughput 37.5%, Latency 12.5%
- **Calculation**: `score = reliability×0.5 + throughput×0.375 - latency×0.125`
- **Categorization**: EXCELLENT (80+), GOOD (60+), FAIR (40+), POOR (<40)
- **Output**: Overall performance classification

#### Example 4: Dynamic Rate Control
**Use Case**: Adjust rate limits based on system load
- Base limit: 1000 bytes/ms
- Dynamic factor: `1.0 - (load × 0.5)`
- **Adjustment**: `adjusted_limit = base_limit × dynamic_factor`
- **Output**: Dynamically adjusted rate limit values

#### Example 5: Logarithmic Scale Analysis
**Use Case**: Handle wide-range metrics with logarithms
- Input range: 1x to 10000x
- **Calculation**: `ln(value)` for logarithmic compression
- **Categorization**: LINEAR, LOGARITHMIC, or EXPONENTIAL
- **Output**: Log values and category classification

## Building Tests

### Quick Build
```bash
cd /work/security/my_lsm/tests/dfp
make build
```

### Clean Build
```bash
make clean
make
```

### Verify Build
```bash
make verify
```

### View Test List
```bash
make list
```

### Show Configuration
```bash
make info
```

## Test Results

Each test outputs results to the `test_results` BPF ringbuffer map:

### Result Structure
```c
struct test_result {
    u32 test_id;           // TEST_1, TEST_2, etc.
    s32 result_value;      // Calculated result
    s32 result_q;          // Quantum of result
    u64 timestamp;         // When test ran
    u8 passed;             // 1=passed, 0=failed
    char message[64];      // Status message
};
```

### Ringbuffer Polling
Results are logged in order to the `test_results` ringbuffer. External userspace program can read:

```bash
bpftool map dump name test_results
```

## Running Tests

### 1. Load Test Program
```bash
bpftool prog load dfp_tests.bpf.o type kprobe \
  name dfp_test \
  maps name test_results
```

### 2. Attach to Kprobe
```bash
echo "p:test_kprobe vfs_write" > /sys/kernel/debug/tracepoints/kprobes/test_kprobe
bpftool prog attach id <PROG_ID> kprobe /sys/kernel/debug/kprobes/test_kprobe
```

### 3. Monitor Results
```bash
# In separate terminal
cat /sys/kernel/debug/tracing/trace_pipe | grep "test"
```

### 4. Retrieve Ringbuffer Data
```bash
# Using custom userspace reader
./read_test_results  # (userspace program to implement)
```

## Expected Results

### dfp_tests.bpf.c Expected Output
```
[TEST_1] Conversion OK: mantissa=256 Q=8
[TEST_2] Addition OK: 1.0 + 2.0 = 3.0
[TEST_3] Subtraction OK: 5.0 - 3.0 = 2.0
[TEST_4] Multiplication OK: 2.0 × 3.0 = 6.0
[TEST_5] Division OK: 6.0 ÷ 2.0 = 3.0
[TEST_6] Division by Zero OK: returned 0
[TEST_7] Absolute Value OK: |-1.0| = 1.0
[TEST_8] Quantum Alignment OK: Q8+Q9 combined
[TEST_9] Logarithm OK: ln(e) ≈ 1.0
[TEST_10] Overflow OK: saturated correctly
```

### dfp_examples.bpf.c Expected Output
```
[IO_MONITOR] Efficiency: 50%
[IO_MONITOR] Throughput: 4096 bytes/ms
[ANOMALY] Low throughput detected
[ANOMALY] Low efficiency detected
[SCORING] Overall Score: 75/100
[SCORING] Status: EXCELLENT
[RATE_CONTROL] Dynamic factor: 0.75
[LOG_ANALYSIS] log(1) = 0
[LOG_ANALYSIS] log(100) ≈ 5
[LOG_ANALYSIS] log(10000) ≈ 9
```

## Troubleshooting

### Build Fails: "vmlinux.h not found"
**Solution**: Ensure `/work/linux-6.8.0/vmlinux` exists or update VMLINUX_BTF path in Makefile

### Ringbuffer Map Not Found
**Solution**: Ensure test programs compiled with ringbuffer map definition
```c
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 262144);
} test_results SEC(".maps");
```

### Results Not Appearing
**Solution**: 
1. Verify kprobe is attached: `bpftool prog list`
2. Trigger the kprobe: Run file I/O operation
3. Check BPF verifier logs: `dmesg | grep BPF`

## Integration with CI/CD

The test suite can be integrated into automated testing:

```bash
# In CI/CD pipeline
cd /work/security/my_lsm/tests/dfp
make clean build verify

# Run tests (requires running kernel)
if [ "$(uname -s)" = "Linux" ]; then
    ./run_tests.sh  # (to implement)
else
    echo "Skipping runtime tests on non-Linux"
fi
```

## Next Steps

1. **Implement Userspace Reader**: Create program to read and validate ringbuffer results
2. **Add More Tests**: Edge cases, negative numbers, extreme values
3. **Performance Benchmarks**: Measure DFP operation latency
4. **Integration Tests**: Test DFP with actual file operations
5. **Kernel Version Matrix**: Test across multiple kernel versions (5.8, 6.0, 6.8, etc.)

## References

- [DFP Library Documentation](../../docs/DFP_LIBRARY.md)
- [DFP Quick Start Guide](../../docs/DFP_QUICKSTART.md)
- [Main vfs_write Program](../../src/vfs_write.bpf.c)
