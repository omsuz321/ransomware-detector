#ifndef __COMMON_H
#define __COMMON_H

#ifndef __VMLINUX_H__
#include "vmlinux.h"
#endif

// Die logische Obergrenze für Daten, die wir erfassen wollen (4KB)
#define MAX_DATA_SIZE 4096U

struct write_event {
    __u32 pid;
    __u32 uid;
    __u32 len;          // Wie viele Bytes haben wir wirklich kopiert?
    __u64 requested;    // Wie viele Bytes wollte der User schreiben?
    char  fname[256];
    
    // FLEXIBLES ARRAY:
    // In der Strukturdefinition ist es 0 Bytes groß.
    // Im Ringbuffer nimmt es variabel viel Platz ein.
    __u8  data[];       
};

#endif /* __COMMON_H */