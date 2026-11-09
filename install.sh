#!/bin/sh
# Installs or removes the patched amdgpu module (userptr fast path) on the kernel it was built for.
#
#   sudo ./install.sh install [amdgpu.ko.gz]   download the release module (or use the given file), check it, install
#   sudo ./install.sh uninstall                put the original module back
#   ./install.sh status                        which module is on disk and which one is loaded
#
# The patched module WEAKENS A SECURITY CHECK in the amdgpu driver (NAKed upstream): read README.md first.
# A reboot is needed after install and uninstall. Works without cloning:
#   curl -LO https://raw.githubusercontent.com/deadlynch/phenom-kernel-patches/main/install.sh && sudo sh install.sh install
set -eu

KERNEL=7.3.3-tkg-eevdf-llvm
URL=https://github.com/deadlynch/phenom-kernel-patches/releases/download/amdgpu-$KERNEL/amdgpu.ko.gz
SHA256=1ec9fd7664ded684a0c815e90a54a662cc82d617c34acba2b48bd7030892b6c2
DIR=/lib/modules/$KERNEL/kernel/drivers/gpu/drm/amd/amdgpu
MOD=$DIR/amdgpu.ko.gz
ORIG=$DIR/amdgpu.ko.gz.orig

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
    echo "running kernel: $(uname -r) (module built for $KERNEL)"
    if [ -e "$MOD" ]; then
        s=$(sha "$MOD")
        if [ "$s" = "$SHA256" ]; then echo "on disk: patched module"
        elif [ -e "$ORIG" ] && [ "$s" = "$(sha "$ORIG")" ]; then echo "on disk: original module (backup kept as amdgpu.ko.gz.orig)"
        else echo "on disk: original or another module (sha256 $s)"
        fi
    else
        echo "on disk: no $MOD"
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
    [ "$(uname -r)" = "$KERNEL" ] ||
        die "this module is for kernel $KERNEL only; this is $(uname -r). Build it from source (README.md)."
    [ -e "$MOD" ] || die "no $MOD: is this the right kernel?"
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
    if [ $# -ge 1 ]; then cp "$1" "$tmp/amdgpu.ko.gz"
    else
        echo "downloading $URL"
        curl -fL --proto '=https' -o "$tmp/amdgpu.ko.gz" "$URL" || die "download failed"
    fi
    [ "$(sha "$tmp/amdgpu.ko.gz")" = "$SHA256" ] || die "sha256 mismatch: not the published module, nothing changed"
    [ "$(modinfo -F vermagic "$tmp/amdgpu.ko.gz" | cut -d' ' -f1)" = "$KERNEL" ] || die "module is not for $KERNEL"
    if [ ! -e "$ORIG" ]; then
        [ "$(sha "$MOD")" != "$SHA256" ] || die "the installed module is already the patched one and there is no backup"
        cp -a "$MOD" "$ORIG"
        echo "original kept as $ORIG"
    fi
    install -m 644 -o root -g root "$tmp/amdgpu.ko.gz" "$MOD"
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
