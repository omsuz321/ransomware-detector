FROM ubuntu:noble

ENV DEBIAN_FRONTEND=noninteractive

# 1. Sources aktivieren & Tools installieren + clang/clangd + eBPF-Tools
RUN sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources && \
    apt-get update && apt-get install -y \
        build-essential \
        libncurses-dev \
        bison \
        flex \
        libssl-dev \
        libelf-dev \
        git \
        vim \
        nano \
        python3 \
        fakeroot \
        bc \
        cpio \
        kmod \
        rsync \
        clang \
        clangd \
        gdb \
        linux-tools-generic \
        libbpf-dev \
        llvm \
    && rm -rf /var/lib/apt/lists/*

# Kernel-Build-Dependencies
RUN apt-get update && apt-get build-dep -y linux && rm -rf /var/lib/apt/lists/*

# bpftool verfügbar machen (linux-tools-generic installiert es kernel-version-spezifisch)
RUN ln -sf /usr/lib/linux-tools/*-generic/bpftool /usr/local/bin/bpftool || \
    (apt-get update && apt-get install -y bpftool && rm -rf /var/lib/apt/lists/*)

# Arbeitsverzeichnis für deine Arbeit
WORKDIR /work

# Start-CMD: Shell
CMD ["/bin/bash"]

