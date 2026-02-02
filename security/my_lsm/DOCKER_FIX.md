# BPF im Docker Container - Lösung

## Problem

```
libbpf: Error in bpf_object__probe_loading(): Operation not permitted(1)
```

**Ursache:** BPF-Programme benötigen spezielle Kernel-Privilegien, die Docker-Container standardmäßig NICHT haben.

## Lösung 1: Container im Privileged Mode starten (einfachst)

```bash
docker run --privileged \
    --rm -it \
    -v /sys/kernel/debug:/sys/kernel/debug:rw \
    -v $(pwd):/work \
    your-image
```

## Lösung 2: Nur benötigte Capabilities (sicherer)

```bash
docker run \
    --cap-add=SYS_ADMIN \
    --cap-add=SYS_RESOURCE \
    --cap-add=BPF \
    -v /sys/kernel/debug:/sys/kernel/debug:rw \
    -v /sys/fs/bpf:/sys/fs/bpf:rw \
    --rm -it \
    -v $(pwd):/work \
    your-image
```

## Lösung 3: Docker Compose

```yaml
version: '3.8'
services:
  bpf-dev:
    image: your-image
    privileged: true
    volumes:
      - ./:/work
      - /sys/kernel/debug:/sys/kernel/debug:rw
      - /sys/fs/bpf:/sys/fs/bpf:rw
    cap_add:
      - SYS_ADMIN
      - SYS_RESOURCE
      - BPF
```

## Testen

Nach dem Neustart des Containers mit den richtigen Privilegien:

```bash
cd /work/security/my_lsm

# Monitor starten
./monitor

# In neuem Terminal: Test
echo "test" > /tmp/test.txt
```

## Wichtig

- **Kernel muss BPF unterstützen:** `CONFIG_BPF_SYSCALL=y`
- **BTF muss aktiviert sein:** `/sys/kernel/btf/vmlinux` muss existieren
- **debugfs mounten (falls nötig):** `mount -t debugfs none /sys/kernel/debug`

## Alternative: Auf Host-System laufen lassen

Falls Docker-Neustart nicht möglich:

```bash
# Auf dem Host (außerhalb Docker)
cd your-project
make clean && make
sudo ./monitor
```
