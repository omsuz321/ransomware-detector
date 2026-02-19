# Tools
CLANG   ?= clang
BPFTOOL ?= bpftool
ARCH    := $(shell uname -m | sed 's/x86_64/x86/')
GCC     ?= gcc

# BPF Compiler Flags
BPF_CFLAGS = -g -O2 -target bpf -D__TARGET_ARCH_$(ARCH) -D__BPF__ \
	-I$(PWD)/include \
	-I$(PWD)/src

# GCC Userspace Flags
USERSPACE_CFLAGS = -O2 -g -Wall
USERSPACE_LIBS = -lbpf -lelf -lz

# Pfade
SRC_DIR         = src
INCLUDE_DIR     = include
MONITOR_DIR     = $(SRC_DIR)/monitor
VMLINUX_H       = $(INCLUDE_DIR)/vmlinux.h

# VFS Write (altes System)
BPF_SRC  = $(SRC_DIR)/vfs_write.bpf.c
BPF_OBJ  = vfs_write.bpf.o
COMMON_H = $(INCLUDE_DIR)/common.h

# Fileops Monitor (neues System)
MONITOR_BPF_SRC = $(MONITOR_DIR)/fileops_lsm.bpf.c
MONITOR_BPF_OBJ = $(MONITOR_DIR)/fileops_lsm.bpf.o
MONITOR_SKEL_H  = $(MONITOR_DIR)/fileops_lsm.skel.h
MONITOR_LOG_SRC = $(MONITOR_DIR)/fileops_logger.c
MONITOR_LOG_BIN = $(MONITOR_DIR)/fileops_logger

.PHONY: all bpf monitor monitor-bpf monitor-userspace vmlinux clean clean-bpf clean-monitor clean-all

# Default: alle bauen
all: bpf monitor

# === BPF (altes System) ===
bpf: $(BPF_OBJ)

$(BPF_OBJ): $(BPF_SRC) $(COMMON_H) $(VMLINUX_H)
	@echo "[BPF] Compiling eBPF Object..."
	$(CLANG) $(BPF_CFLAGS) -c $(BPF_SRC) -o $(BPF_OBJ)

# === Fileops Monitor (neues System) ===
monitor: monitor-bpf monitor-userspace

$(VMLINUX_H):
	@echo "[VMLINUX] Generating vmlinux.h..."
	@mkdir -p $(INCLUDE_DIR)
	bpftool btf dump file /sys/kernel/btf/vmlinux format c > $@
	@echo "[VMLINUX] Generated."

monitor-bpf: $(VMLINUX_H) $(MONITOR_BPF_OBJ) $(MONITOR_SKEL_H)

$(MONITOR_BPF_OBJ): $(MONITOR_BPF_SRC) $(VMLINUX_H)
	@echo "[MONITOR-BPF] Compiling eBPF Object..."
	$(CLANG) $(BPF_CFLAGS) -I$(INCLUDE_DIR) -c $(MONITOR_BPF_SRC) -o $(MONITOR_BPF_OBJ)

$(MONITOR_SKEL_H): $(MONITOR_BPF_OBJ)
	@echo "[MONITOR-SKEL] Generating skeleton..."
	bpftool gen skeleton $(MONITOR_BPF_OBJ) > $@

monitor-userspace: $(MONITOR_LOG_BIN)

$(MONITOR_LOG_BIN): $(MONITOR_LOG_SRC) $(MONITOR_SKEL_H)
	@echo "[MONITOR-USERSPACE] Compiling logger..."
	$(GCC) $(USERSPACE_CFLAGS) -I$(MONITOR_DIR) -I$(INCLUDE_DIR) \
		$(MONITOR_LOG_SRC) -o $@ $(USERSPACE_LIBS)

# === Cleanup ===
clean-bpf:
	@echo "[CLEAN] Removing BPF Object..."
	rm -f $(BPF_OBJ)

clean-monitor:
	@echo "[CLEAN-MONITOR] Removing monitor files..."
	rm -f $(MONITOR_BPF_OBJ) $(MONITOR_SKEL_H) $(MONITOR_LOG_BIN)
	rm -f $(VMLINUX_H)

clean: clean-bpf clean-monitor
	@echo "[CLEAN-ALL] Done."
