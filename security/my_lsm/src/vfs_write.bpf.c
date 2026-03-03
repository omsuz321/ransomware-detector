// Definieren wir selbst, da wir linux/uio.h nicht inkludieren können

#include "../include/vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>

#include "../include/common.h"
#include "../include/dfp.h"
#include "../include/io_helpers.h"
#include "../include/entropy.h"
#include "../include/read_write_ratio.h"
#include "../include/ransomware_event.h"





#define SHOULD_IGNORE_EVENT(mask) ( !is_nfsd() || (mask != MAY_READ && mask != MAY_WRITE) )
// the ordr matters, as wthing the region that we lock, we also update hte thread:level, thus ensureing, that we oyuls only 
// do the decision logic for one thread, because only one thread would have updated the thread level, the other ones would see that the thread level is already updated and skip the decision logic, even if they also triggered the time based trigger
#define SHOULD_SKIP_STAGE_OR_WORK(stage, stats) (stats->stats_lock == 1 || stats->thread_level != stage)

//if true, someone else has the lock
#define TRY_LOCK_USER_T_OR_SKIP(stats) (__sync_val_compare_and_swap(&stats->stats_lock, 0, 1) == 0)
//if ture, user was successfully unlocked
#define UNLOCK_USER_T(stats) (__sync_val_compare_and_swap(&stats->stats_lock, 1, 0) == 1) 

// Spinlock macros for thread-safe access
#define LOCK_STATS(stats) bpf_spin_lock(&(stats)->stats_lock)
#define UNLOCK_STATS(stats) bpf_spin_unlock(&(stats)->stats_lock)

#define BPF_KTIME_GET_MS() (bpf_ktime_get_ns() / 1000000ULL)


char LICENSE[] SEC("license") = "GPL";

struct fixed_point __symmetriy_index_tollerance = RW_SYMMERTY_TOLLERANCE;
struct fixed_point __entropy_threshold = ENTROPY_THRESHOLD;

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

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 8 * 1024 * 1024);
} events SEC(".maps");

static __always_inline void submit_ransomware_event(
    __u8 event_type,
    __u32 uid,
    __u64 user_created_ms,
    __u8 ransomware_detected,
    struct file *file)
{
    struct ransomware_event *evt = bpf_ringbuf_reserve(&events, sizeof(*evt), 0);
    if (!evt)
        return;

    __builtin_memset(evt, 0, sizeof(*evt));
    evt->ts_ns = bpf_ktime_get_ns();
    evt->uid = uid;
    evt->user_created_ms = user_created_ms;
    evt->event_type = event_type;
    evt->ransomware_detected = ransomware_detected;
    if (file)
        evt->inode = BPF_CORE_READ(file, f_inode, i_ino);

    bpf_ringbuf_submit(evt, 0);
}


// it can only be one of them. therefore i can use jus t one lock for both the thread level and the last access time, because only the thread that updaets the thread level would also update the last access time, thus ensuring that we have a consistent view of the thread level and the last access time, because if another thread has updated the thread level, then we know that it has also updated the last access time, thus we can use the last access time to determine whether we should do the decision logic or not
static void CountEvent(int mask, struct user_stats_t *stats, __u32 uid)
{
    //BPF_LOG("mask: %d", mask);
    if (mask == MAY_WRITE)
    {
        //BPF_LOG("enter write");
        __sync_fetch_and_add(&stats->io_stats.write_count, 1);
        return;
    }
    else if (mask == MAY_READ)
    {
        //BPF_LOG("enter read");
        __sync_fetch_and_add(&stats->io_stats.read_count, 1);
    }
}

// when we do return 1, this means we di the update. this means that only we would be able to do the decision logic, because we are the only one that updated the last_access_ms value. if we return 0, this means that another thread has already updated the last_access_ms value and therefore we should not do the decision logic, because another thread is already doing it
static int trigger_detector(struct user_stats_t *stats)
{
    __u64 now = BPF_KTIME_GET_MS();

    switch(stats->thread_level)
    {
        //case STAGE_SCREENING:
        //    return now - stats->last_access_ms >= SCREENING_INTERVAL_MS; 
        case STAGE_INVESTIGATION:
            return now - stats->last_access_ms >= INVESTIGATION_INTERVAL_MS; 
        case STAGE_VERDICT:
            return now - stats->last_access_ms >= VERDICT_INTERVAL_MS; 
        default:
            return 0;
    }
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

    //BPF_LOG("Creating new user stats for UID %u", uid)
    struct user_stats_t init_stats = {0};
    init_stats.last_access_ms = BPF_KTIME_GET_MS();
    init_stats.created_ms = init_stats.last_access_ms;
    init_stats.thread_level = STAGE_INVESTIGATION;
    
    
    //BPF_LOG("Enter: GetOrCreateUserStats for UID %u", uid)
    bpf_map_update_elem(&user_tracker, &uid, &init_stats, BPF_NOEXIST);
    submit_ransomware_event(RANSOMWARE_EVT_USER_CREATED, uid, init_stats.created_ms, 0, 0);
    return bpf_map_lookup_elem(&user_tracker, &uid);
}



//static __always_inline __u8 malicious_open_rate(struct user_stats_t *stats)
//{
//    run_leaky_bucket(stats);
//    return stats->used_bucket_capacity > BUCKET_CAPACITY ? 1 : 0;
//}

static int malicious_read_write_ratio(struct io_stats *io_stats)
{
    struct fixed_point s_index = symmetry_index(io_stats->write_count, io_stats->read_count);
    BPF_LOG("Symmetry index for UID %u: r=%d w=%d", GET_USER_UID(), io_stats->read_count, io_stats->write_count);
    print_fixed_point("X.XX", &s_index);
    
    io_stats->write_count = 0;
    io_stats->read_count = 0;
    if(!A_IS_LESS_OR_EQUAL_B(&s_index, &__symmetriy_index_tollerance))
    {
        io_stats->k_streak = 0;
        BPF_LOG("change k %d", io_stats->k_streak);
        return 0;
    }
    io_stats->k_streak++;
        BPF_LOG("change k %d", io_stats->k_streak);

    return io_stats->k_streak >= INVESTIGATION_STREAK_K ? 1 : 0;
}



static  __s8 has_malicious_entropy_score(struct entropy_data *entropy_data)
{   
    struct fixed_point avg_entropy = get_avg_entropy(entropy_data);
    
    entropy_data->entropy_sum = (struct fixed_point){0};
    entropy_data->count = 0;
    if(!A_IS_GREATER_OR_EQUAL_B(&avg_entropy, &__entropy_threshold))
    {
        entropy_data->k_streak = 0;
        return -1;
    }
    entropy_data->k_streak++;
    return entropy_data->k_streak >= VERDICT_STREAK_K ? 1 : 0;
}

static void reset_user_stats(struct user_stats_t *stats, __s32 prev_thread)
{
    switch(prev_thread) 
    {
       // case STAGE_SCREENING:
       //     stats->used_bucket_capacity = 0;
       //     stats->open_count = 0;
       //     break;
    
        case STAGE_INVESTIGATION:
            stats->io_stats = (struct io_stats){0};
            break;
            
        case STAGE_VERDICT:
            stats->entropy_data.entropy_sum = (struct fixed_point){0};
            stats->entropy_data.count = 0;
            stats->entropy_data.k_streak = 0;
            break;
        default:
            break;
    }
}

static int thread_level_decision(struct user_stats_t *stats, __u32 uid, struct file *file)
{
    // cast is premissibale because we only have 3 stages, so the thread_level will never exceed the range of __s8
    int block_decision;
    __s32 prev_thread_level = stats->thread_level;
    switch(prev_thread_level) 
    {
        //case STAGE_SCREENING:
        //    stats->thread_level += malicious_open_rate(stats);
        //    break;
    
        case STAGE_INVESTIGATION:
            stats->thread_level += malicious_read_write_ratio(&stats->io_stats);
            break;
            
        case STAGE_VERDICT:
            stats->thread_level += has_malicious_entropy_score(&stats->entropy_data);
            break;
        default:
            break;
    }

    if(prev_thread_level != stats->thread_level)
    {
        reset_user_stats(stats, prev_thread_level);
        BPF_LOG("Thread level changed from %d to %d for UID %u", prev_thread_level, stats->thread_level, uid);
    }

    block_decision = stats->thread_level >= BLOCK_ACTION;
    if (block_decision) {
        submit_ransomware_event(RANSOMWARE_EVT_DETECTED, uid, stats->created_ms, 1, file);
        BPF_LOG("block decision: tl=%d, uid=%u", stats->thread_level, uid);
    }

    return block_decision;
}

static int process_entropy(struct file *file, struct iov_iter *iter, struct entropy_data *entropy_data)
{
    struct fixed_point local_entropy;

    int key = 0;
    struct scratch_t *s = bpf_map_lookup_elem(&scratch_map, &key);
    if (!s) 
        return 0;

    u64 bytes_to_send = fill_write_event(s, file, iter);
    if (bytes_to_send == 0)
        return 0;

    struct freq_table *table = bpf_map_lookup_elem(&byte_counts, &key);
    
    if(!CalcEntropy(s, table, &local_entropy))
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

static int process(struct user_stats_t *stats, __u32 uid, struct file *file)
{
    if(TRY_LOCK_USER_T_OR_SKIP(stats))
    {
        thread_level_decision(stats, uid, file);
        stats->last_access_ms = BPF_KTIME_GET_MS();
        UNLOCK_USER_T(stats);
    }
    return 0;
}


//TODO: remove the early return after testing
static int try_run_or_skip_detection(struct user_stats_t *stats, int stage_name, __u32 uid, struct file *file)
{
    // Only collect entropy in VERDICT stage or Skip if decision is already in progress
    if(SHOULD_SKIP_STAGE_OR_WORK(stage_name, stats))
    {   
        return 1;
    }

    if(trigger_detector(stats))
    {
        BPF_LOG("Trigger Detector stage=%d tl=%u", stage_name, stats->thread_level);
        process(stats, uid, file);
        return 1;
    }
    return  0;
}


SEC("fentry/vfs_iter_write")
int BPF_PROG(vfs_iter_write_enter, struct file *file, struct iov_iter *iter)
{
    if (!is_nfsd()) 
    return 0;

    //BPF_LOG("enter write");
    struct user_stats_t *stats;
    __u32 uid = GET_USER_UID();

    stats = GetOrCreateUserStats(uid);
    if (!stats)
    {
        BPF_LOG("Failed to get or create user stats for UID %u", uid);
        return 0;
    }
    if(try_run_or_skip_detection(stats, STAGE_VERDICT, uid, file))
        return 0;

    process_entropy(file, iter, &stats->entropy_data);
    //BPF_LOG("entropy");
    return 0; 
}

SEC("lsm/file_permission")
int BPF_PROG(log_file_permission, struct file *file, int mask)
{
    if (SHOULD_IGNORE_EVENT(mask)) 
        return 0;
    struct user_stats_t *stats;
    __u32 uid = GET_USER_UID();
    stats = GetOrCreateUserStats(uid);
    if (!stats)
    {
        BPF_LOG("Failed to get or create user stats for UID %u", uid);
        return 0;

    }
    if(stats->thread_level == BLOCK_ACTION)
        return -EACCES;
    
    if(try_run_or_skip_detection(stats, STAGE_INVESTIGATION, uid, file))
    {
        //BPF_LOG("Early return from file_permission for UID %u due to investigation stage", uid)
        return 0;
    }

    // Just count the event in file_permission handler
    // Decision happens in vfs_iter_write_enter with proper locking
    CountEvent(mask, stats, uid);
    //print_stats(stats, GET_USER_UID());
    return 0;
}

SEC("lsm/file_open")
int BPF_PROG(lsm_file_open, struct file *file)
{

    if (!is_nfsd())  // oder dein lokales VFS-Filter
      return 0;
    
    //BPF_LOG("OPEN");
    struct user_stats_t *stats;
    __u32 uid = GET_USER_UID();
    stats = GetOrCreateUserStats(uid);
    if (!stats)
    {
        BPF_LOG("Failed to get or create user stats for UID %u", uid);
        return 0;

    }
    
    if(stats->thread_level == BLOCK_ACTION)
        return -EACCES;

    
    //if(try_run_or_skip_detection(stats, STAGE_SCREENING))
    //{
    //    //BPF_LOG("Early return from file_open for UID %u due to screening stage", uid)
    //   return 0;
    //}

    //TODO: remove this as the end
    //__sync_fetch_and_add(&stats->open_count, 1);

    // sonst:
    return 0;
}