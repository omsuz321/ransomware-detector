

#include <stdio.h>
#include <string.h>

// 2. Deine Bibliotheken
#include "../include/common.h"
#include "../include/dfp.h"
#include "../include/entropy.h"

#include "print_human_readable.h"



// ============================================================
// MAIN TEST RUNNER
// ============================================================

int main(void)
{
    struct fixed_point a, b, res;
    struct freq_table table;
    struct fixed_point entropy;
    
    printf("==========================================\n");
    printf("    BPF ENTROPY TEST (BYTE LEVEL)         \n");
    printf("==========================================\n");

    // ---------------------------------------------------------
    // 1. BASIS ARITHMETIK (Kurzer Check)
    // ---------------------------------------------------------
    run_test_header("1. BASIC CHECKS");

    // Q-Faktor Mix Check (wichtig für die interne Mathe)
    a = to_fixed_point(2, 8);  
    b = to_fixed_point(3, 16); 
    res = add(&a, &b);
    assert_fixed("Mix Q8 + Q16", res, "5.000");

    // ---------------------------------------------------------
    // 2. ENTROPIE AUF BYTE-EBENE (0..255)
    // ---------------------------------------------------------
    run_test_header("2. BYTE-LEVEL ENTROPY (Max 8.0 Bit)");

    // --- CASE A: Minimale Entropie (0 Bit) ---
    // Szenario: Datei besteht nur aus Nullen (oder nur 'A's).
    // Informationsgehalt ist 0, da das nächste Byte zu 100% vorhersagbar ist.
    memset(&table, 0, sizeof(table)); 
    table.counts[0] = 100; // 100x Byte 0x00
    
    calculate_entropy(&table, 100, &entropy, 1);
    assert_fixed("Min Entropy (All Zeros)", entropy, "0.000 bits");
    
    // RESET-CHECK: Ist die Tabelle sauber für den nächsten Test?
    if (table.counts[0] == 0) printf("       [PASS] Auto-Reset confirmed.\n");
    else                      printf("       [FAIL] Table NOT cleared!\n");


    // --- CASE B: Maximale Entropie (8 Bit) ---
    // Szenario: Jedes der 256 möglichen Bytes kommt genau gleich oft vor.
    // Das ist das theoretische Maximum für Byte-Daten.
    // log2(256) = 8.0
    memset(&table, 0, sizeof(table));
    for(int i=0; i<256; i++) {
        table.counts[i] = 1; // Jedes Byte 1x
    }
    
    calculate_entropy(&table, 256, &entropy, 1);
    assert_fixed("Max Entropy (Uniform 256)", entropy, "8.000 bits");


    // --- CASE C: Binäre Daten (2 Werte) ---
    // Szenario: Zufällige Bits, aber als Bytes verpackt (z.B. nur 0x00 und 0xFF).
    // Wenn 50/50 verteilt -> 1 Bit Entropie.
    memset(&table, 0, sizeof(table));
    table.counts[0x00] = 50;
    table.counts[0xFF] = 50;
    
    calculate_entropy(&table, 100, &entropy, 1);
    assert_fixed("Binary (0x00/0xFF)", entropy, "1.000 bits");


    // --- CASE D: ASCII Text Simulation (Low Entropy) ---
    // Szenario: Typischer Text nutzt oft nur Buchstaben (a-z, A-Z, 0-9).
    // Wir simulieren hier 4 gleichverteilte Buchstaben.
    // log2(4) = 2.0
    memset(&table, 0, sizeof(table));
    table.counts['a'] = 25; table.counts['b'] = 25;
    table.counts['c'] = 25; table.counts['d'] = 25;
    
    calculate_entropy(&table, 100, &entropy, 1);
    assert_fixed("ASCII Subset (4 chars)", entropy, "2.000 bits");


    // --- CASE E: Realistischer "Skewed" Test ---
    // Szenario: Ein Byte dominiert extrem (z.B. Padding in einem Struct).
    // 99x 0x00, 1x 0x01.
    // Entropie sollte > 0, aber sehr klein sein.
    memset(&table, 0, sizeof(table));
    table.counts[0] = 99;
    table.counts[1] = 1;
    
    calculate_entropy(&table, 100, &entropy, 1);
    assert_fixed("Skewed (Padding)", entropy, "0.081 bits");


    // --- CASE F: Leere Daten ---
    // Edge Case: write() mit Länge 0.
    memset(&table, 0, sizeof(table));
    calculate_entropy(&table, 0, &entropy,1);
    assert_fixed("Empty Input (Len 0)", entropy, "0.000 bits");

    struct fixed_point threshold =  { .number = 15, .q = 1 };
    assert_fixed("trying number representaiton: 7.5", threshold, "7.500 bits");
    printf("\nTests abgeschlossen.\n");
    return 0;
}