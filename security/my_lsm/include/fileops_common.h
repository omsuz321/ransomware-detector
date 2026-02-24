// SPDX-License-Identifier: GPL-2.0
#ifndef __FILEOPS_COMMON_H
#define __FILEOPS_COMMON_H

#ifdef __BPF__
  #include <vmlinux.h>
#else
  #include <linux/types.h>
#endif

#define FILEOPS_TASK_COMM_LEN 16

enum fileops_op_type {
    FILEOPS_OP_OPEN  = 1,
    FILEOPS_OP_READ  = 2,
    FILEOPS_OP_WRITE = 3,
};

/* Userspace-kompatibles Fixed-Point “Wire”-Format */
struct fp_wire {
    __s32 number;
    __u8  q;
    __u8  _pad[3]; /* align -> sizeof(fp_wire)=8 */
};

struct fileops_event {
  __u64 ts_ns;
  __u64 bytes;
  __u32 uid;
  __u32 tgid;
  __u32 pid;
  __u32 entropy_len;   /* wie viele Bytes in Entropie-Berechnung */
  __u32 _pad1;         /* align */
  
  __u16 _pad0;         /* align */
  __u8  op;
  __u8  entropy_valid; /* 1 wenn gesetzt */
  struct fp_wire entropy;
};

#endif /* __FILEOPS_COMMON_H */