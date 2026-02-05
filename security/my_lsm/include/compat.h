// =============================================================================
// Compatibility layer for eBPF vs. userspace builds
// - Controls STANDALONE switch
// - Provides type aliases and printk shim for userspace
// =============================================================================

#ifndef __COMPAT_H__
#define __COMPAT_H__

#ifndef __FLAG_H__
#include "flag.h"
#endif

#if STANDALONE
    
	#include <stdint.h>
	#include <stdio.h>
	#include <sys/types.h>

	typedef unsigned char  __u8;
	typedef unsigned short __u16;
	typedef unsigned int __u32;
	typedef unsigned long __u64;

	typedef char   __s8;
	typedef short  __s16;
	typedef int  __s32;
	typedef long  __s64;

	#ifndef __COMMON_H__
	#include "common.h"
	#endif

	#ifndef __always_inline
	#define __always_inline __attribute__((always_inline))
	#endif

	#define bpf_printk(fmt, ...) printf(fmt "\n", ##__VA_ARGS__)

	static __always_inline long compat_bpf_loop(__u32 max, long (*cb)(__u32, void *), void *ctx, __u64 flags)
	{
		for (__u32 i = 0; i < max; i++) {
			long ret = cb(i, ctx);
			if (ret) return ret;
		}
		return 0;
	}

	#define bpf_loop(max, cb, ctx, flags) compat_bpf_loop((max), (cb), (ctx), (flags))
	#define COMPAT_IS_BPF 0
#endif /* STANDALONE */

#ifndef __COMMON_H__
#include "common.h"
#endif




#endif /* __COMPAT_H__ */