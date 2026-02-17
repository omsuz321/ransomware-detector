#ifndef __FILEOPS_COMMON_H
#define __FILEOPS_COMMON_H

#ifdef __BPF__
  #include <vmlinux.h>
#else
  // Userspace: types are already defined via linux/types.h (also included by libbpf)
  #include <linux/types.h>
#endif

#define FILEOPS_TASK_COMM_LEN 16

enum fileops_op_type {
    FILEOPS_OP_OPEN  = 1,
    FILEOPS_OP_READ  = 2,
    FILEOPS_OP_WRITE = 3,
};

struct fileops_event {
    __u64 ts_ns;
    __u32 uid;
    __u32 tgid;
    __u32 pid;

    __u8  op;
    __u8  _pad[3];

    __u64 bytes;
};

#endif /* __FILEOPS_COMMON_H */
