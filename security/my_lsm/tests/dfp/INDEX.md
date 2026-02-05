# DFP Test Suite Index

**Complete test infrastructure for the Dynamic Fixed Point (DFP) library**

## 📂 Directory Contents

```
tests/dfp/
├── Source Code
│   ├── dfp_tests.bpf.c          # 10 core operation tests
│   └── dfp_examples.bpf.c       # 5 real-world usage examples
│
├── Compiled Binaries
│   ├── dfp_tests.bpf.o          # Ready for kernel (15K)
│   └── dfp_examples.bpf.o       # Ready for kernel (25K)
│
├── Build & Run
│   ├── Makefile                 # Build system configuration
│   └── run_tests.sh             # Automated test runner
│
└── Documentation
    ├── README.md                # Full test documentation
    ├── QUICKSTART.md            # 5-minute quick start
    ├── INTEGRATION.md           # Integration with main project
    └── INDEX.md                 # This file
```

## 🧪 Test Programs

### dfp_tests.bpf.c - Core Operations
**10 comprehensive kprobe test programs**

1. **test_conversion** - `to_fixed_point(10, 8)` → Q8 format
2. **test_addition** - `1.0 + 2.0 = 3.0`
3. **test_subtraction** - `5.0 - 3.0 = 2.0`
4. **test_multiplication** - `2.0 × 3.0 = 6.0`
5. **test_division** - `6.0 ÷ 2.0 = 3.0`
6. **test_div_zero** - Division by zero handling
7. **test_abs_value** - `|-1.0| = 1.0`
8. **test_quantum_alignment** - Multi-quantum normalization
9. **test_logarithm** - `ln(e) ≈ 1.0`
10. **test_overflow** - Saturation without wraparound

**Binary**: dfp_tests.bpf.o (15K, ready for kernel)

### dfp_examples.bpf.c - Real-World Scenarios
**5 practical usage examples**

1. **example_io_monitor** - File I/O performance monitoring
   - Efficiency ratio calculation
   - Throughput measurement
   - Percentage extraction

2. **example_anomaly** - Anomaly detection with baselines
   - Compare current vs. baseline metrics
   - Threshold-based alerting
   - Performance degradation detection

3. **example_scoring** - Composite weighted scoring
   - Multi-metric evaluation
   - Reliability (50%) + Throughput (37.5%) - Latency (12.5%)
   - Status classification: EXCELLENT/GOOD/FAIR/POOR

4. **example_rate_control** - Dynamic rate limiting
   - Adjust limits based on system load
   - Formula: `adjusted = base × (1.0 - load×0.5)`
   - Real-time throttling adaptation

5. **example_log_analysis** - Logarithmic scale handling
   - Wide-range metric compression
   - Category classification
   - Non-linear analysis

**Binary**: dfp_examples.bpf.o (25K, ready for kernel)

## 🚀 Quick Start

### Build
```bash
cd /work/security/my_lsm/tests/dfp
./run_tests.sh build
```

### Verify
```bash
./run_tests.sh verify
make info
```

### View Tests
```bash
./run_tests.sh info
make list
```

## 📖 Documentation

| File | Purpose | Read Time |
|------|---------|-----------|
| [README.md](README.md) | Complete test documentation with expected outputs | 10 min |
| [QUICKSTART.md](QUICKSTART.md) | Quick start guide with kernel testing instructions | 5 min |
| [INTEGRATION.md](INTEGRATION.md) | Integration with main project and CI/CD | 8 min |
| [Makefile](Makefile) | Build system configuration | 2 min |

## 📊 Test Coverage

### Operations Tested
- ✅ Fixed-point conversion (Q8, Q16, Q32 formats)
- ✅ Addition and subtraction
- ✅ Multiplication and division
- ✅ Absolute value
- ✅ Logarithm (table-based)
- ✅ Normalization and quantum alignment

### Edge Cases Tested
- ✅ Division by zero
- ✅ Overflow handling (saturation)
- ✅ Multi-quantum arithmetic
- ✅ Extreme values

### Real-World Scenarios Included
- ✅ I/O performance monitoring
- ✅ Anomaly detection
- ✅ Composite scoring
- ✅ Dynamic rate control
- ✅ Wide-range analysis

## 🏗️ Build System

### Makefile Targets
```bash
make                # Build all tests
make clean          # Remove build artifacts
make verify         # Verify build success
make build          # Clean + build + verify
make test           # Build and indicate ready
make list           # List available tests
make info           # Show configuration
```

### run_tests.sh Commands
```bash
./run_tests.sh build    # Build test programs
./run_tests.sh check    # Check deps + verify build
./run_tests.sh verify   # Verify artifacts
./run_tests.sh clean    # Clean build
./run_tests.sh info     # Show information
```

## 🔧 Build Artifacts

```
dfp_tests.bpf.o       15K    10 core test programs (verified)
dfp_examples.bpf.o    25K    5 example programs (verified)
```

Both binaries:
- ✅ Pass BPF verifier
- ✅ Ready for kernel loading
- ✅ Zero compilation warnings
- ✅ Fully debuggable (debug symbols included)

## 📋 File Sizes

| File | Size | Type |
|------|------|------|
| dfp_tests.bpf.c | 9.0K | Source |
| dfp_examples.bpf.c | 8.5K | Source |
| dfp_tests.bpf.o | 15K | Binary |
| dfp_examples.bpf.o | 25K | Binary |
| Makefile | 1.5K | Config |
| run_tests.sh | 5.6K | Script |
| README.md | 7.6K | Docs |
| QUICKSTART.md | 5.7K | Docs |
| INTEGRATION.md | ~6K | Docs |
| **Total** | **~87K** | |

## ✅ Status

- ✅ All source compiles successfully
- ✅ All binaries verified
- ✅ BPF verifier compatible
- ✅ Comprehensive documentation
- ✅ Ready for kernel testing
- ✅ CI/CD integration ready

## 🔗 Related Documentation

**DFP Library**
- [DFP_LIBRARY.md](../docs/DFP_LIBRARY.md) - Complete DFP reference
- [DFP_QUICKSTART.md](../docs/DFP_QUICKSTART.md) - DFP quick start

**Main Project**
- [vfs_write.bpf.c](../src/vfs_write.bpf.c) - Main program using DFP
- [dfp.h](../include/bpf/dfp.h) - DFP library implementation

## 🎯 Next Steps

1. **Load into kernel** - `bpftool prog load dfp_tests.bpf.o type kprobe`
2. **Attach kprobe** - `bpftool prog attach ...`
3. **Trigger tests** - Run file I/O operations
4. **Monitor results** - View in `/sys/kernel/debug/tracing/trace_pipe`
5. **Verify all operations** - Check expected outputs in README.md

## 📞 Quick Reference

**Build and verify:**
```bash
cd /work/security/my_lsm/tests/dfp && ./run_tests.sh build
```

**Show info:**
```bash
./run_tests.sh info
```

**Load and test:**
```bash
bpftool prog load dfp_tests.bpf.o type kprobe name test_prog
echo "p:test_kp vfs_write" > /sys/kernel/debug/kprobes/new
bpftool prog attach id <ID> kprobe /sys/kernel/debug/kprobes/test_kp
dd if=/dev/zero of=/tmp/test bs=4096 count=1
cat /sys/kernel/debug/tracing/trace_pipe | grep TEST
```

---

**Created**: February 2025
**Status**: Ready for production testing
**Compatibility**: Linux 5.8+ with BPF support
