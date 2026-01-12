FROM ubuntu:noble

ENV DEBIAN_FRONTEND=noninteractive

# 1. Sources aktivieren & Tools installieren (wie vorher) + clang/clangd
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
    && rm -rf /var/lib/apt/lists/*

# Kernel-Build-Dependencies
RUN apt-get update && apt-get build-dep -y linux && rm -rf /var/lib/apt/lists/*

# 2. Cache-Ordner für Kernel-Sourcen
WORKDIR /kernel-cache

# 3. Kernel-Sourcen ins Image holen
RUN apt-get update && apt source linux && rm -rf /var/lib/apt/lists/*

# 4. Arbeitsverzeichnis für deine Arbeit
WORKDIR /work

# 5. Start-CMD: Kernel aus Cache nach /work kopieren (ohne zu überschreiben), dann Shell
CMD ["sh", "-c", "cp -rn /kernel-cache/* /work/ && /bin/bash"]
