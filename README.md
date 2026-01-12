# LSM Kernel Dev (Ubuntu 24.04)

Dev environment for Linux LSM development using a VS Code Dev-Container.

---

## 1. Start Dev-Container

On the host in `bachelor_thesis/dev`:

```
code .
```

In VS Code:

- `F1` → **Dev Containers: Reopen in Container**

Container paths:

- Workspace: `/work`
- Kernel source: `/work/linux-6.8.0`
- clangd uses: `/work/linux-6.8.0/compile_commands.json`

---

## 2. Kernel configuration

If `.config` is missing or reset:

**Host:**

```
cp /boot/config-$(uname -r) ~/bachelor_thesis/dev/linux-6.8.0/.config
```

**Container:**

```
cd /work/linux-6.8.0
make olddefconfig

# disable WERROR
sed -i 's/^CONFIG_WERROR=y/# CONFIG_WERROR is not set/' .config
make olddefconfig
```

---

## 3. Build the kernel

In container:

```
make -j"$(nproc)" 2>&1 | tee build.log
```

Errors:

```
grep -i "error:" build.log | head -20
```

---

## 4. Generate compile_commands.json

After partial or full build:

```
python3 scripts/clang-tools/gen_compile_commands.py
```

Outputs:

```
/work/linux-6.8.0/compile_commands.json
```

---

## 5. clangd integration

Already configured in `.devcontainer/devcontainer.json`:

```jsonc
"clangd.arguments": [
  "--background-index",
  "--compile-commands-dir=/work/linux-6.8.0"
]
```

Open kernel C files to get navigation, hover, references, etc.
