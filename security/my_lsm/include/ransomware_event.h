// SPDX-License-Identifier: GPL-2.0
#ifndef __RANSOMWARE_EVENT_H
#define __RANSOMWARE_EVENT_H

#ifdef __BPF__
  #include <vmlinux.h>
#else
  #include <linux/types.h>
#endif

enum ransomware_event_type {
    RANSOMWARE_EVT_USER_CREATED = 1,
    RANSOMWARE_EVT_DETECTED = 2,
};

struct ransomware_event {
    __u64 ts_ns;
    __u64 inode;
    __u64 user_created_ms;
    __u32 uid;
    __u8 event_type;
    __u8 ransomware_detected;
    __u16 _pad;
};

#endif