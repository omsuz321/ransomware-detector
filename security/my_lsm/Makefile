# Tools
CLANG   ?= clang
BPFTOOL ?= bpftool
GCC     ?= gcc
ENABLE_VFS_ITER_WRITE ?= 1
ENABLE_ENTROPY ?= 1

# Robust project root (egal von wo make aufgerufen wird)
PROJECT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# Dirs
SRC_DIR      := $(PROJECT_ROOT)/src
INCLUDE_DIR  := $(PROJECT_ROOT)/include
MONITOR_DIR  := $(SRC_DIR)/monitor

# Header source dir: support both old nested layout and normal repo layout.
LSM_INCLUDE_CANDIDATES := $(PROJECT_ROOT)/security/my_lsm/include $(PROJECT_ROOT)/include
LSM_INCLUDE_DIR := $(firstword $(wildcard $(LSM_INCLUDE_CANDIDATES)))
ifeq ($(LSM_INCLUDE_DIR),)
LSM_INCLUDE_DIR := $(PROJECT_ROOT)/include
endif

# Workaround für falsches include in monitor-bpf: "../include/vmlinux.h" aus src/monitor/
SRC_INCLUDE_DIR := $(SRC_DIR)/include
SRC_VMLINUX_H   := $(SRC_INCLUDE_DIR)/vmlinux.h

# Kernel BTF -> vmlinux.h
VMLINUX_BTF ?= /sys/kernel/btf/vmlinux
VMLINUX_H   := $(INCLUDE_DIR)/vmlinux.h

# Arch mapping for __TARGET_ARCH_*
ARCH := $(shell uname -m | sed 's/x86_64/x86/')

# BPF Compiler Flags (Ohne Monitor-Dir)
BPF_CFLAGS = -g -O2 -target bpf -D__TARGET_ARCH_$(ARCH) -D__BPF__ \
    -mllvm -enable-machine-outliner=never \
    -I$(INCLUDE_DIR) \
    -I$(LSM_INCLUDE_DIR) \
    -I$(SRC_DIR) \
    -I/usr/include \
    -I/usr/include/bpf

MONITOR_BPF_CFLAGS = $(BPF_CFLAGS) \
    -DENABLE_VFS_ITER_WRITE_HOOK=$(ENABLE_VFS_ITER_WRITE) \
    -DENABLE_ENTROPY=$(ENABLE_ENTROPY)

# Userspace Flags
USERSPACE_CFLAGS = -O2 -g -Wall
USERSPACE_LIBS   = -lbpf -lelf -lz

# === Targets ===

# VFS Write (altes System) - Wieder auf $(SRC_DIR) gesetzt
BPF_SRC  := $(SRC_DIR)/vfs_write.bpf.c
BPF_OBJ  := $(PROJECT_ROOT)/vfs_write.bpf.o

# Fileops Monitor (neues System)
MONITOR_BPF_SRC := $(MONITOR_DIR)/fileops_lsm.bpf.c
MONITOR_BPF_OBJ := $(MONITOR_DIR)/fileops_lsm.bpf.o
MONITOR_SKEL_H  := $(MONITOR_DIR)/fileops_lsm.skel.h
MONITOR_LOG_SRC := $(MONITOR_DIR)/fileops_logger.c
MONITOR_LOG_BIN := $(MONITOR_DIR)/fileops_logger

.PHONY: all bpf monitor monitor-bpf monitor-userspace vmlinux link-headers clean clean-bpf clean-monitor

all: bpf monitor

# 1) vmlinux.h generieren
vmlinux: $(VMLINUX_H) $(SRC_VMLINUX_H)

$(VMLINUX_H):
	@echo "[VMLINUX] Generating $(VMLINUX_H)..."
	@mkdir -p $(INCLUDE_DIR)
	$(BPFTOOL) btf dump file $(VMLINUX_BTF) format c > $@
	@echo "[VMLINUX] Generated."

# Workaround: falls irgendwo "../include/vmlinux.h" aus src/monitor/ verwendet wird
$(SRC_VMLINUX_H): $(VMLINUX_H)
	@echo "[VMLINUX] Providing $(SRC_VMLINUX_H) (workaround)..."
	@mkdir -p $(SRC_INCLUDE_DIR)
	cp -f $(VMLINUX_H) $@

# 2) Header-Linking: mirror headers into ./include (except generated vmlinux.h)
link-headers:
	@echo "[INCLUDE] Linking headers from $(LSM_INCLUDE_DIR) -> $(INCLUDE_DIR) ..."
	@mkdir -p $(INCLUDE_DIR)
	@if [ ! -d "$(LSM_INCLUDE_DIR)" ]; then \
	  echo "[INCLUDE] WARN: $(LSM_INCLUDE_DIR) not found"; \
	elif [ "$(realpath $(LSM_INCLUDE_DIR))" = "$(realpath $(INCLUDE_DIR))" ]; then \
	  echo "[INCLUDE] Using local include directory (no links needed)."; \
	else \
	  for f in $(LSM_INCLUDE_DIR)/*.h; do \
	    base=$$(basename $$f); \
	    if [ "$$base" != "vmlinux.h" ]; then \
	      ln -sf "$$f" $(INCLUDE_DIR)/$$base; \
	    fi; \
	  done; \
	fi

# === BPF (alt) ===
bpf: link-headers vmlinux $(BPF_OBJ)

$(BPF_OBJ): $(BPF_SRC)
	@echo "[BPF] Compiling $(BPF_OBJ)..."
	$(CLANG) $(BPF_CFLAGS) -c $< -o $@

# === Monitor ===
monitor: monitor-bpf monitor-userspace

monitor-bpf: link-headers vmlinux $(MONITOR_BPF_OBJ) $(MONITOR_SKEL_H)

$(MONITOR_BPF_OBJ): $(MONITOR_BPF_SRC)
	@echo "[MONITOR-BPF] Compiling $(MONITOR_BPF_OBJ)..."
	@echo "[MONITOR-BPF] ENABLE_VFS_ITER_WRITE=$(ENABLE_VFS_ITER_WRITE)"
	@echo "[MONITOR-BPF] ENABLE_ENTROPY=$(ENABLE_ENTROPY)"
	$(CLANG) $(MONITOR_BPF_CFLAGS) -c $< -o $@

$(MONITOR_SKEL_H): $(MONITOR_BPF_OBJ)
	@echo "[MONITOR-SKEL] Generating skeleton..."
	$(BPFTOOL) gen skeleton $< > $@

monitor-userspace: $(MONITOR_LOG_BIN)

$(MONITOR_LOG_BIN): $(MONITOR_LOG_SRC) $(MONITOR_SKEL_H)
	@echo "[MONITOR-USERSPACE] Compiling logger..."
	$(GCC) $(USERSPACE_CFLAGS) -I$(INCLUDE_DIR) \
	    $(MONITOR_LOG_SRC) -o $@ $(USERSPACE_LIBS)

# === Cleanup ===
clean-bpf:
	rm -f $(BPF_OBJ)

clean-monitor:
	rm -f $(MONITOR_BPF_OBJ) $(MONITOR_SKEL_H) $(MONITOR_LOG_BIN)
	rm -f $(SRC_VMLINUX_H)
	rm -f $(VMLINUX_H)

clean: clean-bpf clean-monitor
	@echo "[CLEAN] Done."
