# Overhead Evaluation - Reproducibility Guide

This guide explains how to reproduce the overhead evaluation results using saved raw data.

## Files Overview

- `run_overhead_evaluation.sh` - Main benchmark script
- `analyze_overhead_results.py` - Python analysis script for reproducible analysis
- `results/overhead_evaluation_YYYYMMDD_HHMMSS.csv` - Aggregated results
- `results/raw_data_overhead_evaluation_YYYYMMDD_HHMMSS/` - Raw data directory
  - `fio_baseline_run*.json` - FIO benchmark JSON outputs (baseline)
  - `fio_detector_run*.json` - FIO benchmark JSON outputs (detector mode)
  - `pidstat_nfsd_baseline_run*.log` - nfsd CPU monitoring logs (baseline)
  - `pidstat_nfsd_detector_run*.log` - nfsd CPU monitoring logs (detector mode)
  - `pidstat_detector_run*.log` - detector CPU monitoring logs

## Running the Benchmark

```bash
# Basic run with 5 iterations per mode
./run_overhead_evaluation.sh \
    192.168.2.209 \          # Server IP
    /mnt/nfs \               # NFS mount point
    5 \                      # Number of runs per mode
    1234 \                   # Server password
    /path/to/scripts \       # Path to ransomware_monitor.sh
    5G \                     # FIO test size
    randrw                   # FIO mode (randrw, write, read, etc.)
```

## Analyzing Results

### Option 1: Quick Analysis (using CSV)

```bash
python3 analyze_overhead_results.py results/overhead_evaluation_20260303_204930.csv
```

This reads the CSV file created by the benchmark script and shows:
- Runtime comparison (baseline vs. detector)
- Bandwidth comparison
- CPU usage breakdown
- Overhead percentages

### Option 2: Full Re-parsing (reproducible from raw data)

```bash
python3 analyze_overhead_results.py results/overhead_evaluation_20260303_204930.csv --reparse
```

This **completely re-parses** all raw data files (FIO JSON + pidstat logs) independent of the original script's parsing logic. This ensures:
- Full reproducibility of results
- Verification of parsing correctness
- Ability to change analysis methods later

### Option 3: Detailed Per-Run Analysis

```bash
python3 analyze_overhead_results.py results/overhead_evaluation_20260303_204930.csv --detailed
```

Shows individual results for each run, useful for identifying outliers.

### Option 4: Generate Plots

```bash
python3 analyze_overhead_results.py results/overhead_evaluation_20260303_204930.csv --export-plots
```

Generates PNG plots in `results/plots/`:
- `runtime_comparison.png` - Box plot of runtime distribution
- `cpu_comparison.png` - Bar chart of CPU usage

**Requires matplotlib**: `pip install matplotlib`

## Manual Verification of Raw Data

You can manually inspect the raw data to verify results:

### Inspect FIO JSON Output

```bash
cat results/raw_data_overhead_evaluation_20260303_204930/fio_baseline_run1.json | jq '.jobs[0] | {runtime: .job_runtime, bw: .write.bw, iops: .write.iops}'
```

### Inspect pidstat Logs

```bash
# View nfsd CPU usage over time
tail -20 results/raw_data_overhead_evaluation_20260303_204930/pidstat_nfsd_baseline_run1.log

# Calculate average manually
awk 'NF>6 {cpu=$(NF-2); if(cpu ~ /^[0-9]+(\.[0-9]+)?$/) {sum+=cpu; count++}} END{print "Average CPU:", sum/count "%"}' \
    results/raw_data_overhead_evaluation_20260303_204930/pidstat_nfsd_baseline_run1.log
```

## Reproducing Paper Results

For publication-quality results, run with at least 10 iterations:

```bash
./run_overhead_evaluation.sh 192.168.2.209 /mnt/nfs 10 1234 /path/to/scripts 5G randrw
```

Then analyze with:

```bash
python3 analyze_overhead_results.py results/overhead_evaluation_*.csv --reparse --detailed --export-plots
```

## Statistical Significance

The analysis script calculates:
- **Median** - Robust central tendency (not affected by outliers)
- **Standard deviation** - Measure of variability
- **Min/Max/Percentiles** - Range of observed values

For statistical significance testing (t-test, Mann-Whitney), use:

```python
import csv
import scipy.stats

# Load data
with open('results/overhead_evaluation_20260303_204930.csv') as f:
    data = list(csv.DictReader(f))

baseline = [float(r['fio_runtime_sec']) for r in data if r['mode'] == 'baseline']
detector = [float(r['fio_runtime_sec']) for r in data if r['mode'] == 'detector']

# Mann-Whitney U test (non-parametric)
statistic, p_value = scipy.stats.mannwhitneyu(baseline, detector)
print(f"p-value: {p_value}")
print(f"Significant at α=0.05: {p_value < 0.05}")
```

## Troubleshooting

### Missing Raw Data Files

If raw data directory is missing, ensure:
1. Script completed successfully (check last log messages)
2. SCP is working (`scp` command available, SSH keys or password auth working)
3. Server has sufficient permissions (`/tmp` is writable)

### Inconsistent Results

If results vary significantly between runs:
1. Check system load during benchmarking: `uptime`, `top`
2. Ensure no other I/O intensive processes are running
3. Verify caches are being cleared properly
4. Increase number of iterations to reduce variance

### Re-parse Shows Different Results

Small differences (< 1%) are expected due to:
- Rounding differences in calculations
- Different AWK versions
- Timing of when pidstat samples were collected

Large differences indicate a parsing bug - please file an issue!

## Example Output

```
======================================================================
 OVERHEAD EVALUATION ANALYSIS
======================================================================

Dataset: 5 baseline runs, 5 detector runs

--- RUNTIME PERFORMANCE ---
Baseline:  12.540s (median), 0.051s (std), [12.488-12.612]
Detector:  12.495s (median), 0.162s (std), [12.332-12.657]
Overhead:  -0.36%

--- BANDWIDTH ---
Baseline:  5523 KB/s (median), 23 KB/s (std)
Detector:  5548 KB/s (median), 72 KB/s (std)
Reduction: -0.45%

--- CPU USAGE ---
Baseline nfsd:    5.65% (median), 0.07% (std)
Detector nfsd:    6.10% (median), 1.32% (std)
Detector monitor: 0.05% (median), 0.05% (std)
nfsd overhead:    +0.45%
Total CPU added:  0.05%

======================================================================

SUMMARY:
  Time overhead:  -0.36%
  CPU overhead:   +0.45% (nfsd) + 0.05% (detector)
  BW reduction:   -0.45%
======================================================================
```

## Citation

If you use this evaluation methodology in your research, please cite:

```bibtex
@misc{ransomware-detector-overhead,
  title={Overhead Evaluation Methodology for NFS Ransomware Detector},
  author={Your Name},
  year={2026},
  note={Reproducible benchmark using FIO and pidstat}
}
```
