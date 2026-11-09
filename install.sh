#!/bin/sh
# Installs or removes the patched amdgpu module (userptr fast path) on the kernel it was built for.
#
#   sudo ./install.sh install                 download the published module (kernel 7.3.3-tkg-eevdf-llvm only), install
#   sudo ./install.sh install amdgpu.ko.xx    install a module you built for the running kernel (build-module.sh)
#   sudo ./install.sh uninstall               put the original module back
#   ./install.sh status                       which module is on disk and which one is loaded
#
# The patched module WEAKENS A SECURITY CHECK in the amdgpu driver (NAKed upstream): read README.md first.
# A reboot is needed after install and uninstall. Works without cloning:
#   curl -LO https://raw.githubusercontent.com/deadlynch/phenom-kernel-patches/main/install.sh && sudo sh install.sh install
set -eu

PUBLISHED=7.3.3-tkg-eevdf-llvm  # the kernel of the published module
URL=https://github.com/deadlynch/phenom-kernel-patches/releases/download/amdgpu-$PUBLISHED/amdgpu.ko.gz
SHA256=1ec9fd7664ded684a0c815e90a54a662cc82d617c34acba2b48bd7030892b6c2
KERNEL=$(uname -r)
DIR=/lib/modules/$KERNEL/kernel/drivers/gpu/drm/amd/amdgpu
MOD=$(ls "$DIR"/amdgpu.ko "$DIR"/amdgpu.ko.gz "$DIR"/amdgpu.ko.xz "$DIR"/amdgpu.ko.zst 2>/dev/null | head -1 || true)
EXT=${MOD##*/amdgpu.ko}    # "", .gz, .xz or .zst: what this kernel's modules use
ORIG=$MOD.orig

die() { echo "install.sh: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "run it with sudo"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

initramfs() {  # rebuild the running kernel's initramfs with whichever tool the system has
    if command -v dracut >/dev/null; then dracut -f "/boot/initramfs-$KERNEL.img" "$KERNEL"
    elif command -v mkinitcpio >/dev/null; then mkinitcpio -P
    elif command -v update-initramfs >/dev/null; then update-initramfs -u -k "$KERNEL"
    else echo "install.sh: no dracut, mkinitcpio or update-initramfs: rebuild the initramfs yourself if amdgpu is in it"
    fi
}

status() {
    echo "running kernel: $KERNEL"
    if [ -n "$MOD" ] && [ -e "$MOD" ]; then
        s=$(sha "$MOD")
        if [ "$s" = "$SHA256" ]; then echo "on disk: patched module"
        elif [ -e "$ORIG" ] && [ "$s" = "$(sha "$ORIG")" ]; then echo "on disk: original module (backup kept as amdgpu.ko.gz.orig)"
        else echo "on disk: original or another module (sha256 $s)"
        fi
    else
        echo "on disk: no amdgpu module in $DIR"
    fi
    if [ -r /sys/module/amdgpu/taint ]; then
        case $(cat /sys/module/amdgpu/taint) in
        *O*) echo "loaded: an out-of-tree amdgpu (the patched one, if installed from here)" ;;
        *) echo "loaded: the kernel's own amdgpu" ;;
        esac
    else
        echo "loaded: amdgpu is not loaded"
    fi
}

install_mod() {
    need_root
    [ -n "$MOD" ] || die "no amdgpu module in $DIR"
    [ $# -ge 1 ] || [ "$KERNEL" = "$PUBLISHED" ] ||
        die "the published module is for kernel $PUBLISHED only; this is $KERNEL. Build one for it (README.md)."
    cat <<'EOF'

  WARNING: this module weakens a security check in the amdgpu driver. The amdgpu maintainer
  rejected the same change upstream ("it leads to security issues"). A local program could
  abuse it to make the GPU read or write memory it shouldn't. Use it only on a single-user
  gaming PC, keep a known-good kernel in the boot menu, and know how to undo it:
      sudo ./install.sh uninstall && sudo reboot

EOF
    printf 'Type "yes" to install: '
    read -r answer < /dev/tty || answer=
    [ "$answer" = yes ] || die "not installed"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    new=$tmp/amdgpu.ko$EXT
    if [ $# -ge 1 ]; then
        case $1 in *"amdgpu.ko$EXT") ;; *) die "this kernel's modules are amdgpu.ko$EXT: give a module compressed the same way";; esac
        cp "$1" "$new"
    else
        echo "downloading $URL"
        curl -fL --proto '=https' -o "$new" "$URL" || die "download failed"
        [ "$(sha "$new")" = "$SHA256" ] || die "sha256 mismatch: not the published module, nothing changed"
    fi
    [ "$(modinfo -F vermagic "$new" | cut -d' ' -f1)" = "$KERNEL" ] || die "the module is not for kernel $KERNEL"
    if [ ! -e "$ORIG" ]; then
        [ "$(modinfo -F vermagic "$MOD" >/dev/null && sha "$MOD")" != "$(sha "$new")" ] ||
            die "the installed module is already this one and there is no backup of the original"
        cp -a "$MOD" "$ORIG"
        echo "original kept as $ORIG"
    fi
    install -m 644 -o root -g root "$new" "$MOD"
    depmod "$KERNEL"
    initramfs
    echo "installed: reboot to load it (sudo reboot)"
}

uninstall_mod() {
    need_root
    [ -e "$ORIG" ] || die "no backup $ORIG: the original module was never replaced from here"
    cp -a "$ORIG" "$MOD"
    depmod "$KERNEL"
    initramfs
    echo "original module back: reboot to load it (sudo reboot). The backup stays as $ORIG."
}

case ${1:-} in
install) shift; install_mod "$@" ;;
uninstall) uninstall_mod ;;
status) status ;;
*) sed -n '2,10p' "$0"; exit 2 ;;
esac
