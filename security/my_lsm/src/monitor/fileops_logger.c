// SPDX-License-Identifier: GPL-2.0
#include <bpf/libbpf.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <string.h>
#include <sys/resource.h>

#include "fileops_common.h"
#include "fileops_lsm.skel.h"

// OPTIMIERUNG: 4 MB Schreibpuffer im RAM sammeln (minimiert Syscalls)
#define WRITE_BUFFER_SIZE (4 * 1024 * 1024)

static volatile sig_atomic_t exiting = 0;

static void on_sig(int signo) {
    (void)signo;
    exiting = 1;
}

static int bump_memlock(void) {
    struct rlimit rl = {RLIM_INFINITY, RLIM_INFINITY};
    return setrlimit(RLIMIT_MEMLOCK, &rl);
}

static const char *op_str(__u32 op) {
    switch (op) {
    case 1: return "OPEN";
    case 2: return "READ";
    case 3: return "WRITE";
    default: return "UNKNOWN";
    }
}

static __u64 ts_to_ns(const struct timespec *ts) {
    return (__u64)ts->tv_sec * 1000000000ULL + (__u64)ts->tv_nsec;
}

struct ctx {
    FILE *out;
    __u64 rt0_ns;
    __u64 mono0_ns;
};

// Callback für jedes Event aus dem Kernel
static int handle_event(void *ctxv, void *data, size_t len) {
    (void)len;
    struct ctx *c = (struct ctx *)ctxv;
    const struct fileops_event *e = (const struct fileops_event *)data;

    // Zeitstempel konvertieren
    __u64 rt_ns = c->rt0_ns + (e->ts_ns - c->mono0_ns);
    time_t sec = (time_t)(rt_ns / 1000000000ULL);
    long nsec  = (long)(rt_ns % 1000000000ULL);

    struct tm tm;
    gmtime_r(&sec, &tm);

    char tbuf[64];
    strftime(tbuf, sizeof(tbuf), "%Y-%m-%dT%H:%M:%S", &tm);

    // Schreibt extrem schnell in den 4MB RAM-Puffer
    fprintf(c->out, "%s.%09ldZ,%u,%u,%u,%s,%llu\n",
            tbuf, nsec,
            e->uid, e->tgid, e->pid,
            op_str(e->op),
            (unsigned long long)e->bytes);

    return 0;
}

static void usage(const char *p) {
    fprintf(stderr,
    "Usage: %s [-o FILE] [--ring-mb N]\n"
    "  -o FILE        Output CSV file (default: /tmp/fileops.csv)\n"
    "  --ring-mb N    Ringbuffer size MiB (default: 256)\n", p);
}

int main(int argc, char **argv) {
    const char *out_path = "/tmp/fileops.csv";
    int ring_mb = 256;
    struct ring_buffer *rb = NULL;
    struct fileops_lsm_bpf *skel = NULL;
    char *write_buf = NULL;

    // Argumente parsen
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-o") && i + 1 < argc) {
            out_path = argv[++i];
        } else if (!strcmp(argv[i], "--ring-mb") && i + 1 < argc) {
            ring_mb = atoi(argv[++i]);
        } else {
            usage(argv[0]); // Fix: Jetzt genutzt, Warnung verschwindet
            return 1;
        }
    }

    if (bump_memlock() != 0) {
        fprintf(stderr, "WARN: RLIMIT_MEMLOCK failed: %s\n", strerror(errno));
    }

    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);

    FILE *out = fopen(out_path, "a");
    if (!out) {
        perror("fopen");
        return 1;
    }

    // 4MB RAM Puffer für Datei-I/O einrichten
    write_buf = malloc(WRITE_BUFFER_SIZE);
    if (write_buf) {
        setvbuf(out, write_buf, _IOFBF, WRITE_BUFFER_SIZE);
    }

    // Header schreiben falls nötig
    fseek(out, 0, SEEK_END);
    if (ftell(out) == 0) {
        fprintf(out, "timestamp,uid,tgid,pid,op,bytes\n");
    }

    // Zeit-Synchronisation
    struct timespec rt0, mono0;
    clock_gettime(CLOCK_REALTIME, &rt0);
    clock_gettime(CLOCK_MONOTONIC, &mono0);

    struct ctx ctx = {
        .out = out,
        .rt0_ns = ts_to_ns(&rt0),
        .mono0_ns = ts_to_ns(&mono0),
    };

    // BPF Skeleton laden
    skel = fileops_lsm_bpf__open();
    if (!skel) {
        fprintf(stderr, "failed to open skeleton\n");
        goto cleanup;
    }

    // Ringbuffer Kapazität einstellen (muss vor load passieren)
    bpf_map__set_max_entries(skel->maps.events, (size_t)ring_mb * 1024 * 1024);

    if (fileops_lsm_bpf__load(skel)) {
        fprintf(stderr, "failed to load BPF\n");
        goto cleanup;
    }

    if (fileops_lsm_bpf__attach(skel)) {
        fprintf(stderr, "failed to attach BPF\n");
        goto cleanup;
    }

    // Ringbuffer Instanz erstellen
    rb = ring_buffer__new(bpf_map__fd(skel->maps.events), handle_event, &ctx, NULL);
    if (!rb) {
        fprintf(stderr, "failed to create ring buffer\n");
        goto cleanup;
    }

    printf("Logger aktiv. Schreibe in: %s (Ring: %dMB, Puffer: 4MB)\n", out_path, ring_mb);
    printf("Beenden mit Strg+C...\n");

    while (!exiting) {
        int err = ring_buffer__poll(rb, 100);
        if (err < 0 && err != -EINTR) {
            fprintf(stderr, "ring_buffer__poll error: %d\n", err);
            break;
        }
    }

cleanup:
    if (out) {
        printf("\nSpeichere restliche Daten (fflush)... ");
        fflush(out);
        fclose(out);
        printf("Erledigt.\n");
    }
    if (rb)
        ring_buffer__free(rb);
    if (skel)
        fileops_lsm_bpf__destroy(skel);
    free(write_buf);
    
    return 0;
}