#!/bin/sh
# On the Phenom: installs amdgpu.ko.gz for the running kernel (the original is kept once as amdgpu.ko.gz.orig),
# then depmod and the initramfs. Reboot afterwards.   sudo scripts/install-module.sh amdgpu.ko.gz
# Revert:                                            sudo scripts/install-module.sh --revert
set -e
K=$(uname -r)
D=/lib/modules/$K/kernel/drivers/gpu/drm/amd/amdgpu
if [ "$1" = --revert ]; then
    cp -a "$D/amdgpu.ko.gz.orig" "$D/amdgpu.ko.gz"
else
    [ -e "$D/amdgpu.ko.gz.orig" ] || cp -a "$D/amdgpu.ko.gz" "$D/amdgpu.ko.gz.orig"
    install -m 644 -o root -g root "$1" "$D/amdgpu.ko.gz"
fi
depmod "$K"
dracut -f "/boot/initramfs-$K.img" "$K"
echo "done: reboot to load it"
