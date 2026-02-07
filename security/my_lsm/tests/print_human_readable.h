
// Include compat FIRST to define STANDALONE types before vmlinux.h
#include "../include/compat.h"

#include <stdio.h>
#include <assert.h>
#include "../include/read_write_ratio.h" // Include the actual implementation of the ratio calculation
#include "../include/common.h"

void assert_fixed(const char* name, struct fixed_point res, const char* expected_desc) {
    __s32 integer_part = res.number >> res.q;
    __s32 mask = (1 << res.q) - 1;
    __s32 fractional_bits = res.number & mask;
    
    // Anzeige auf 3 Dezimalstellen
    __s64 frac_calc = (__s64)fractional_bits * 1000;
    __s32 decimal_part = (__s32)(frac_calc >> res.q);
    if (decimal_part < 0) decimal_part = -decimal_part;

    printf("[TEST] %-28s -> Got: %3d.%03d  | Expected: %s\n", 
           name, integer_part, decimal_part, expected_desc);
}

void run_test_header(const char* title) {
    printf("\n------------------------------------------------\n");
    printf("  %s\n", title);
    printf("------------------------------------------------\n");
}

void double_to_string(double value, char *buffer, size_t size) {
    // "%.4f" bedeutet: Formatire als Float mit exakt 4 Nachkommastellen
    snprintf(buffer, size, "%.4f", value);
}
    
void assertTest(char name[], struct fixed_point actual, double expected) {
    char expected_str[20];
    double_to_string(expected, expected_str, sizeof(expected_str));
    assert_fixed(name, actual, expected_str);
}