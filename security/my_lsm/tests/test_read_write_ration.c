#include <stdio.h>
#include <assert.h>
#include "../include/read_write_ratio.h" // Include the actual implementation of the ratio calculation
#include "../include/common.h"

#include "print_human_readable.h"

// Mock or include the read_write_ratio.c functions
// #include "../read_write_ratio.h"

void test_read_write_ratio_basic(void) {
    // Test basic ratio calculation
    int reads = 10;
    int writes = 5;
    struct fixed_point ratio = calculate_read_write_ratio(reads, writes);
    assertTest("Basic Ratio 10/5", ratio, (double)reads/writes);
}

void test_read_write_ratio_equal(void) {
    // Test when reads equal writes
    int reads = 10;
    int writes = 10;
    struct fixed_point ratio = calculate_read_write_ratio(reads, writes);
    assertTest("Equal Reads/Writes", ratio, 1.0);
}

void test_read_write_ratio_zero_writes(void) {
    // Test division by zero handling
    int reads = 10;
    int writes = 0;
    assertTest("Zero Writes", calculate_read_write_ratio(reads, writes), 0.0);
}

void test_read_write_ratio_zero_reads(void) {
    // Test when reads are zero
    int reads = 0;
    int writes = 5;
    struct fixed_point ratio = calculate_read_write_ratio(reads, writes);
    assertTest("Zero Reads", ratio, 0.0);
}

void test_read_write_ratio_large_values(void) {
    // Test with large values
    long reads = 1000000;
    long writes = 500000;
    struct fixed_point ratio = calculate_read_write_ratio(reads, writes);
    assertTest("Large Values", ratio, (double)reads / writes);
}

void test_symmetry_index_equal(void) {
    int reads = 10;
    int writes = 10;
    struct fixed_point sym = symmetry_index(writes, reads);
    assertTest("Symmetry (Equal)", sym, 0.0);
}

void test_symmetry_index_skewed(void) {
    int reads = 10;
    int writes = 0;
    struct fixed_point sym = symmetry_index(writes, reads);
    assertTest("Symmetry (0/10)", sym, 1.0);
}

void test_malicious_read_write_ratio(void) {
    struct user_stats_t stats = { 0 };

    stats.read_count = 10;
    stats.write_count = 9;
    assert(malicious_read_write_ratio(&stats) == 1);
    printf("[TEST] Malicious Ratio (10/9) -> PASS\n");

    stats.read_count = 100;
    stats.write_count = 1;
    assert(malicious_read_write_ratio(&stats) == -1);
    printf("[TEST] Malicious Ratio (100/1) -> PASS\n");
}

int main(void) {
    test_read_write_ratio_basic();
    test_read_write_ratio_equal();
    test_read_write_ratio_zero_reads();
    test_read_write_ratio_zero_writes();
    test_read_write_ratio_large_values();
    test_symmetry_index_equal();
    test_symmetry_index_skewed();
    test_malicious_read_write_ratio();
    printf("All tests passed!\n");
    return 0;
}