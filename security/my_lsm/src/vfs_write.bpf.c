// Definieren wir selbst, da wir linux/uio.h nicht inkludieren können
#include "common.h"
#include "dfp.h"
#include "vmlinux.h"
#ifndef UIO_MAXIOV
#define UIO_MAXIOV 1024 
#endif

// Define file permission constants
#ifndef MAY_READ
#define MAY_READ 0x00000004
#endif

#ifndef MAY_WRITE
#define MAY_WRITE 0x00000002
#endif

#define INTERVAL_MS 500ULL

// Stage 1: Screening (Rasterfahndung)
#define STAGE_SCREENING   0  

// Stage 2: Investigation (Beweissicherung)
#define STAGE_INVESTIGATION     1  

// Stage 3: Verdict (Urteilsfindung)
#define STAGE_VERDICT 2  
#define BLOCK_ACTION 3

#define NFSD_MAGIC (__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__ ? 0x6473666E : 0x6E667364)

#ifndef __VMLINUX_H__
#include <vmlinux.h>
#endif

#ifndef __BPF_HELPERS_
#include <bpf/bpf_helpers.h>
#endif

#ifndef __BPF_TRACING_H__
#include <bpf/bpf_tracing.h>
#endif

#ifndef __BPF_CORE_READ_H__
#include <bpf/bpf_core_read.h>
#endif

#ifndef __COMMON_H
#include "../include/common.h"
#endif

#ifndef __IO_HELPERS_H__
#include "../include/io_helpers.h"
#endif

#ifndef __ENTROPY_H__
#include "../include/entropy.h"
#endif


#define SHOULD_IGNORE_EVENT(mask) (!((mask & (MAY_READ | MAY_WRITE)) && is_nfsd() ))
// the ordr matters, as wthing the region that we lock, we also update hte thread:level, thus ensureing, that we oyuls only 
// do the decision logic for one thread, because only one thread would have updated the thread level, the other ones would see that the thread level is already updated and skip the decision logic, even if they also triggered the time based trigger
#define SHOULD_SKIP_STAGE_OR_WORK(stage, stats) (stats->stats_lock == 1 || stats->thread_level != stage)
#define GET_USER_UID() (__u32)bpf_get_current_uid_gid()
//if true, someone else has the lock
#define TRY_LOCK_USER_T_OR_SKIP(stats) (__sync_val_compare_and_swap(&stats->stats_lock, 0, 1) == 0)
//if ture, user was successfully unlocked
#define UNLOCK_USER_T(stats) (__sync_val_compare_and_swap(&stats->stats_lock, 1, 0) == 1) 

// Spinlock macros for thread-safe access
#define LOCK_STATS(stats) bpf_spin_lock(&(stats)->stats_lock)
#define UNLOCK_STATS(stats) bpf_spin_unlock(&(stats)->stats_lock)

// Mark as static to allow the compiler/verifier to treat it as a sub-program


#define BPF_KTIME_GET_MS() (bpf_ktime_get_ns() / 1000000ULL)

char LICENSE[] SEC("license") = "GPL";


struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __uint(key_size, sizeof(__u32));
    __uint(value_size, SCRATCH_MAP_SIZE); 
} scratch_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __uint(key_size, sizeof(__u32));
    __uint(value_size, sizeof(struct freq_table)); 
} byte_counts SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, MAX_USER_COUNT); 
    __type(key, __u32);
    __type(value, struct user_stats_t);
} user_tracker SEC(".maps");

static int is_nfsd(void) {
    #define COMM_SIZE 16
    char comm[COMM_SIZE];
    
    __builtin_memset(comm, 0, COMM_SIZE);
    if (bpf_get_current_comm(&comm, COMM_SIZE) < 0) 
        return 0; 
    
    return (*(unsigned int *)comm == NFSD_MAGIC);
}

// Simple non-atomic lock (acceptable for BPF + statistics)
// Race condition OK: worst case both threads try decision simultaneously
#define BPF_KTIME_GET_MS() (bpf_ktime_get_ns() / 1000000ULL)

static void CountEvent(int mask, struct user_stats_t *stats, __u32 uid)
{
    if (mask & MAY_WRITE)
        __sync_fetch_and_add(&stats->write_count, 1);
    else if (mask & MAY_READ)
        __sync_fetch_and_add(&stats->read_count, 1);
}
//

// when we do return 1, this means we di the update. this means that only we would be able to do the decision logic, because we are the only one that updated the last_access_ms value. if we return 0, this means that another thread has already updated the last_access_ms value and therefore we should not do the decision logic, because another thread is already doing it
static int trigger_detector(struct user_stats_t *stats)
{
    __u64 now = BPF_KTIME_GET_MS();
    return now - stats->last_access_ms >= INTERVAL_MS; 
}

/** 

static void print_human_readable(struct freq_table *t)
{
    if (!t) return;

    for (__u32 i = 48; i <= 57; i++) {
        __u16 c = t->counts[i];
        if (c) bpf_printk("'%c': %u", (char)i, c);
    }
    for (__u32 i = 65; i <= 90; i++) {
        __u16 c = t->counts[i];
        if (c) bpf_printk("'%c': %u", (char)i, c);
    }
    for (__u32 i = 97; i <= 122; i++) {
        __u16 c = t->counts[i];
        if (c) bpf_printk("'%c': %u", (char)i, c);
    }
}
*/
static struct user_stats_t *GetOrCreateUserStats(__u32 uid)
{
    struct user_stats_t *stats = bpf_map_lookup_elem(&user_tracker, &uid);
    if (stats) 
        return stats;
    
    struct user_stats_t empty = {0};
    empty.last_access_ms = BPF_KTIME_GET_MS();
    bpf_printk("Enter: GetOrCreateUserStats for UID %u", uid);
    bpf_map_update_elem(&user_tracker, &uid, &empty, BPF_NOEXIST);
    return bpf_map_lookup_elem(&user_tracker, &uid);
}

static int CalcEntropy(struct file *file, struct iov_iter *iter, struct fixed_point *entropy_out)
{
    int key = 0;
    struct scratch_t *s = bpf_map_lookup_elem(&scratch_map, &key);
    if (!s) 
        return 0;

    u64 bytes_to_send = fill_write_event(s, file, iter);
    if (bytes_to_send == 0)
        return 0;

    struct freq_table *table = bpf_map_lookup_elem(&byte_counts, &key);
    __u32 header_len = s->header.len;
    
    if (!table || header_len == 0) 
        return 0;

    struct count_ctx ctx = {
        .table = table,
        .data_buffer = s->data_buffer
    };

    __u32 loop_limit = header_len > MAX_DATA_SIZE ? MAX_DATA_SIZE : header_len;

    bpf_loop(loop_limit, count_bytes_fast, &ctx, 0);

    //print_human_readable(table);

 
    print_preview(s->data_buffer, header_len);
    
    
    calculate_entropy(table, header_len, entropy_out, 1);
    return 1;
}

static __always_inline __u8 has_exeeded_normal_open_rate()
{
    return 0;
}

static  __s8 has_malicoud_r_w_ratio(struct user_stats_t *stats)
{
    struct fixed_point read = { .number = stats->read_count, .q = 0 };
    struct fixed_point write = { .number = stats->write_count, .q = 0 };
    struct fixed_point ratio = divide(&read, &write);

    //mach dhier den vergleich mit einem schwellenwert, z.B. wenn mehr als 10 mal so viele writes wie reads, dann return 1, sonst return -1
    return A_IS_GRATHER_B(&ratio, &RW_RATIO_LOWER_THRESHOLD ) &&
           A_IS_LESS_B(&ratio, & RW_RATIO_UPPER_THRESHOLD) 
           ? 1 : -1;
}



static  __s8 has_malicious_entropy_score(struct entropy_data *entropy_data)
{   
    struct fixed_point avg_entropy = get_avg_entropy(entropy_data);
    __s8 ret = A_IS_GRATHER_B(&avg_entropy, &ENTROPY_THRESHOLD) == 1 ? 1 : -1;
    return ret;
}

static int thread_level_decision(struct user_stats_t *stats)
{
    // cast is premissibale because we only have 3 stages, so the thread_level will never exceed the range of __s8
    __s8 thread_level = stats->thread_level;
    switch(thread_level) 
    {
        case STAGE_SCREENING:
            thread_level += has_exeeded_normal_open_rate();

            break;
    
        case STAGE_INVESTIGATION:
            thread_level += has_malicoud_r_w_ratio(stats);
            break;
            
        case STAGE_VERDICT:
            thread_level += has_malicious_entropy_score(&stats->entropy_data);
            break;
        default:
            break;
    }
    // Update thread_level safely within the lock
    stats->thread_level = thread_level;

    return thread_level >= BLOCK_ACTION;
}

static int process_entropy(struct file *file, struct iov_iter *iter, struct entropy_data *entropy_data)
{
    struct fixed_point local_entropy;
    if(!CalcEntropy(file, iter, &local_entropy))
        return 1;

    struct fixed_point *entropy_sum_ptr = &entropy_data->entropy_sum;

    // this makes it thread safe when updateing
    bpf_spin_lock(&entropy_data->lock);
    *entropy_sum_ptr = add(entropy_sum_ptr, &local_entropy);
    entropy_data->count++;
    bpf_spin_unlock(&entropy_data->lock);

    return 0;
}

// this allows to do the detection logic for only one thread, the other ones that are also dealing wiht the same client, will skip it for now

static int process(struct user_stats_t *stats)
{
    bpf_printk("TRY_LOCK_USER_T_OR_SKIP entered %llu", BPF_KTIME_GET_MS());
    if(TRY_LOCK_USER_T_OR_SKIP(stats))
    {
        bpf_printk("Inside TRY_LOCK_USER_T_OR_SKIP  %llu", BPF_KTIME_GET_MS());
        thread_level_decision(stats);
        stats->last_access_ms = BPF_KTIME_GET_MS();
        UNLOCK_USER_T(stats);
    }
    bpf_printk("Outside TRY_LOCK_USER_T_OR_SKIP %llu", BPF_KTIME_GET_MS());
    return 0;
}

static int try_run_detection(struct user_stats_t *stats, int stage_name)
{
    // Only collect entropy in VERDICT stage or Skip if decision is already in progress
    bpf_printk("Enter: SHOULD_SKIP_STAGE_OR_WORKk entered ");
    if(SHOULD_SKIP_STAGE_OR_WORK(stage_name, stats))
    {
        bpf_printk("Skip: SHOULD_SKIP_STAGE_OR_WORKk entered ");
        bpf_printk("Current thread level: %u", stats->thread_level);
        bpf_printk("Current stats_lock: %u", stats->stats_lock);
        bpf_printk("Current last_access_ms: %llu", stats->last_access_ms);
        bpf_printk("Current time: %llu", BPF_KTIME_GET_MS());
        return 0;
    }

    bpf_printk("Pass: SHOULD_SKIP_STAGE_OR_WORKk ");

    if(trigger_detector(stats))
    {
        bpf_printk("Trigger Detector passed -> do detction possibly");
        process(stats);
        return 1;
    }
    return  0;
}

SEC("fentry/vfs_iter_write")
int BPF_PROG(vfs_iter_write_enter, struct file *file, struct iov_iter *iter)
{
    if (!is_nfsd()) 
        return 0;
    struct user_stats_t *stats;
    __u32 uid = GET_USER_UID();

    stats = GetOrCreateUserStats(uid);
    if (!stats)
    {
        bpf_printk("Failed to get or create user stats for UID %u", uid);
        return 0;
    }
    if(try_run_detection(stats, STAGE_VERDICT))
        return 0;

    bpf_printk("Process Entropy: look entered ");
    process_entropy(file, iter, &stats->entropy_data);
    bpf_printk("Process Entropy: look entered ");

    return 0; 
}

SEC("lsm/file_permission")
int BPF_PROG(log_file_permission, struct file *file, int mask)
{
    if (SHOULD_IGNORE_EVENT(mask)) 
        return 0;
    bpf_printk("Enter: READ OR WRITE permission check with mask %d", mask);
    struct user_stats_t *stats;
    __u32 uid = GET_USER_UID();

    stats = GetOrCreateUserStats(uid);
    if (!stats)
        return 0;
    
    if(try_run_detection(stats, STAGE_SCREENING))
        return 0;

    // Just count the event in file_permission handler
    // Decision happens in vfs_iter_write_enter with proper locking
    bpf_printk("Enter: CountEvent  ");
    CountEvent(mask, stats, uid);
    bpf_printk("Exit: CountEvent  ");
    return 0;
}

SEC("lsm/file_open")
int BPF_PROG(lsm_file_open, struct file *file)
{
    if (!is_nfsd())  // oder dein lokales VFS-Filter
        return 0;

    bpf_printk("open file: %s", file->f_path.dentry->d_name.name);
    // daten sammeln ...
    // wenn blocken:

    // sonst:
    return 0;
}