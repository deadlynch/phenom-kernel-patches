#!/bin/bash
# Builds only the amdgpu module from a kernel tree that was already built (linux-tkg's linux-src-git), with the
# patches in ../patches applied, and leaves it stripped, signed and gzip-compressed like the installed modules.
#   scripts/build-amdgpu-module.sh [kernel tree] [output dir]
set -euo pipefail
K=${1:-$HOME/kbuild/linux-tkg/linux-src-git}
OUT=${2:-$PWD/out}
cd "$K"
make LLVM=1 LLVM_IAS=1 -j"$(nproc)" M=drivers/gpu/drm/amd/amdgpu modules
mkdir -p "$OUT"
cp drivers/gpu/drm/amd/amdgpu/amdgpu.ko "$OUT/"
llvm-strip --strip-debug "$OUT/amdgpu.ko"
scripts/sign-file "$(grep -oP '^CONFIG_MODULE_SIG_HASH="\K[^"]+' .config)" certs/signing_key.pem certs/signing_key.x509 "$OUT/amdgpu.ko"
gzip -9 -n -f "$OUT/amdgpu.ko"
echo "$OUT/amdgpu.ko.gz for $(modinfo -F vermagic "$OUT/amdgpu.ko.gz")"
