# Tools
CLANG   ?= clang
BPFTOOL ?= bpftool
ARCH    := $(shell uname -m | sed 's/x86_64/x86/')

# BPF Compiler Flags
BPF_CFLAGS = -g -O2 -target bpf -D__TARGET_ARCH_$(ARCH) -D__BPF__ \
    -I/work/include \
    -I$(PWD)/include \
    -I$(PWD)/src

# Pfade
SRC_DIR     = src
INCLUDE_DIR = include

BPF_SRC  = $(SRC_DIR)/vfs_write.bpf.c
BPF_OBJ  = vfs_write.bpf.o
COMMON_H = $(INCLUDE_DIR)/common.h

.PHONY: all bpf clean clean-all

# Default: nur BPF bauen
all: bpf

bpf: $(BPF_OBJ)

$(BPF_OBJ): $(BPF_SRC) $(COMMON_H)
	@echo "[BPF] Compiling eBPF Object..."
	$(CLANG) $(BPF_CFLAGS) -c $(BPF_SRC) -o $(BPF_OBJ)

# Cleanup
clean-bpf:
	@echo "[CLEAN] Removing BPF Object..."
	rm -f $(BPF_OBJ)

clean: clean-bpf
	@echo "[CLEAN-ALL] Done."
