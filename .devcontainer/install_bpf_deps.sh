#!/usr/bin/env bash
set -euo pipefail

# Install the bpftool packages that match the running kernel.
KERNEL_RELEASE="$(uname -r)"
PKGS=("linux-tools-${KERNEL_RELEASE}" "linux-cloud-tools-${KERNEL_RELEASE}")
APT_GET="$(command -v apt-get || true)"

if [[ -z "${APT_GET}" ]]; then
  echo "apt-get not found; please install the packages manually." >&2
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  SUDO="sudo"
else
  SUDO=""
fi

missing_pkgs=()
for pkg in "${PKGS[@]}"; do
  if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
    missing_pkgs+=("${pkg}")
  fi
done

if (( ${#missing_pkgs[@]} == 0 )); then
  echo "All kernel-specific bpftool packages already installed for ${KERNEL_RELEASE}."
  exit 0
fi

echo "Installing packages: ${missing_pkgs[*]}";
${SUDO} apt-get update
${SUDO} apt-get install -y "${missing_pkgs[@]}" || {
  echo "Primary install failed; trying generic packages." >&2
  ${SUDO} apt-get install -y linux-tools-generic linux-cloud-tools-generic
}

echo "Done. bpftool path: $(command -v bpftool || true)"
