// SPDX-License-Identifier: GPL-2.0
#include <bpf/libbpf.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

struct fixed_point {
    int32_t number;
    int32_t q;
};

#include "ransomware_event.h"
#include "vfs_write.skel.h"

static volatile sig_atomic_t exiting = 0;

struct logger_ctx {
    FILE *out;
    __u64 rt0_ns;
    __u64 mono0_ns;
    char run_id[64];
    char label[32];
    char attack_start_time[64];
    int alarm_triggered;
    int csv_written;  // Flag ob CSV-Zeile bereits geschrieben wurde
    char first_alarm_time[64];
    int user_created;
    char user_created_time[64];
};

static void on_sig(int signo)
{
    (void)signo;
    exiting = 1;
}

static int bump_memlock(void)
{
    struct rlimit rl = {RLIM_INFINITY, RLIM_INFINITY};
    return setrlimit(RLIMIT_MEMLOCK, &rl);
}

static __u64 ts_to_ns(const struct timespec *ts)
{
    return (__u64)ts->tv_sec * 1000000000ULL + (__u64)ts->tv_nsec;
}

static const char *event_type_str(__u8 event_type)
{
    switch (event_type) {
    case RANSOMWARE_EVT_USER_CREATED:
        return "USER_CREATED";
    case RANSOMWARE_EVT_DETECTED:
        return "RANSOMWARE_DETECTED";
    default:
        return "UNKNOWN";
    }
}

static int handle_event(void *ctx_ptr, void *data, size_t len)
{
    (void)len;
    struct logger_ctx *ctx = (struct logger_ctx *)ctx_ptr;
    const struct ransomware_event *event = (const struct ransomware_event *)data;

    __u64 rt_ns = ctx->rt0_ns + (event->ts_ns - ctx->mono0_ns);
    time_t sec = (time_t)(rt_ns / 1000000000ULL);
    long nsec = (long)(rt_ns % 1000000000ULL);

    struct tm tm;
    gmtime_r(&sec, &tm);

    char tbuf[64];
    strftime(tbuf, sizeof(tbuf), "%Y-%m-%dT%H:%M:%S", &tm);

    // Track first user creation = attack start
    if (event->event_type == RANSOMWARE_EVT_USER_CREATED && !ctx->user_created) {
        ctx->user_created = 1;
        snprintf(ctx->user_created_time, sizeof(ctx->user_created_time),
                 "%s.%09ldZ", tbuf, nsec);
        // Attack starts when user is created
        snprintf(ctx->attack_start_time, sizeof(ctx->attack_start_time),
                 "%s.%09ldZ", tbuf, nsec);
    }

    // Track first alarm
    if (event->event_type == RANSOMWARE_EVT_DETECTED && !ctx->alarm_triggered) {
        ctx->alarm_triggered = 1;
        snprintf(ctx->first_alarm_time, sizeof(ctx->first_alarm_time),
                 "%s.%09ldZ", tbuf, nsec);
        
        // WICHTIG: Schreibe sofort die CSV-Zeile bei Erkennung!
        fprintf(ctx->out, "%s,%s,%s,%s,%d,%s\n",
                strlen(ctx->run_id) > 0 ? ctx->run_id : "-",
                strlen(ctx->label) > 0 ? ctx->label : "-",
                strlen(ctx->attack_start_time) > 0 ? ctx->attack_start_time : "-",
                ctx->user_created ? ctx->user_created_time : "-",
                1,  // detection_status = 1 (detected)
                ctx->first_alarm_time);
        fflush(ctx->out);  // Sofort auf Disk schreiben!
        ctx->csv_written = 1;  // Markiere als geschrieben
    }

    return 0;
}

static void usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s [-o FILE] [--ring-mb N] [--run-id ID] [--label LABEL]\n"
            "  -o FILE        CSV output (default: /tmp/ransomware_events.csv)\n"
            "  --ring-mb N    Ringbuffer size in MiB (default: 8)\n"
            "  --run-id ID    Run identifier for this test\n"
            "  --label LABEL  Run label (e.g., benign, ransomware)\n"
            "\n"
            "Note: attack_start_time is automatically tracked when user is created.\n",
            prog);
}

int main(int argc, char **argv)
{
    const char *out_path = "/tmp/ransomware_events.csv";
    int ring_mb = 8;
    const char *run_id = "";
    const char *label = "";

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-o") && i + 1 < argc) {
            out_path = argv[++i];
        } else if (!strcmp(argv[i], "--ring-mb") && i + 1 < argc) {
            ring_mb = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "--run-id") && i + 1 < argc) {
            run_id = argv[++i];
        } else if (!strcmp(argv[i], "--label") && i + 1 < argc) {
            label = argv[++i];
        } else {
            usage(argv[0]);
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

    setvbuf(out, NULL, _IOLBF, 0);

    fseek(out, 0, SEEK_END);
    long sz = ftell(out);
    if (sz == 0) {
        fprintf(out, "run_id,label,attack_start_time,user_created_time,detection_status,detection_time\n");
        fflush(out);
    }

    struct timespec rt0;
    struct timespec mono0;
    clock_gettime(CLOCK_REALTIME, &rt0);
    clock_gettime(CLOCK_MONOTONIC, &mono0);

    struct logger_ctx ctx = {
        .out = out,
        .rt0_ns = ts_to_ns(&rt0),
        .mono0_ns = ts_to_ns(&mono0),
        .alarm_triggered = 0,
        .csv_written = 0,
        .user_created = 0,
    };
    snprintf(ctx.run_id, sizeof(ctx.run_id), "%s", run_id);
    snprintf(ctx.label, sizeof(ctx.label), "%s", label);
    ctx.attack_start_time[0] = '\0';  // Will be set when user is created
    ctx.first_alarm_time[0] = '\0';
    ctx.user_created_time[0] = '\0';

    struct vfs_write_bpf *skel = vfs_write_bpf__open();
    if (!skel) {
        fprintf(stderr, "failed to open vfs_write skeleton\n");
        fclose(out);
        return 1;
    }

    if (ring_mb > 0) {
        size_t bytes = (size_t)ring_mb * 1024 * 1024;
        bpf_map__set_max_entries(skel->maps.events, bytes);
    }

    if (vfs_write_bpf__load(skel)) {
        fprintf(stderr, "failed to load BPF program\n");
        goto cleanup;
    }

    if (vfs_write_bpf__attach(skel)) {
        fprintf(stderr, "failed to attach BPF program\n");
        goto cleanup;
    }

    struct ring_buffer *rb = ring_buffer__new(
        bpf_map__fd(skel->maps.events), handle_event, &ctx, NULL);
    if (!rb) {
        fprintf(stderr, "failed to create ring buffer\n");
        goto cleanup;
    }

    fprintf(stderr, "Logging ransomware CSV to %s (Ctrl+C to stop)\n", out_path);

    while (!exiting) {
        int err = ring_buffer__poll(rb, 200);
        if (err < 0 && err != -EINTR) {
            fprintf(stderr, "ring_buffer__poll: %d\n", err);
            break;
        }
    }

    ring_buffer__free(rb);

cleanup:
    vfs_write_bpf__destroy(skel);

    // Write single summary line (detection_status: 1=detected, 0=not detected)
    // Nur schreiben, wenn noch nicht bei Erkennung geschrieben wurde
    if (!ctx.csv_written) {
        int detection_status = ctx.alarm_triggered ? 1 : 0;
        const char *detection_time = ctx.alarm_triggered ? ctx.first_alarm_time : "-";
        
        fprintf(out, "%s,%s,%s,%s,%d,%s\n",
                strlen(ctx.run_id) > 0 ? ctx.run_id : "-",
                strlen(ctx.label) > 0 ? ctx.label : "-",
                strlen(ctx.attack_start_time) > 0 ? ctx.attack_start_time : "-",
                ctx.user_created ? ctx.user_created_time : "-",
                detection_status,
                detection_time);
        fflush(out);
    }

    fclose(out);
    return 0;
}