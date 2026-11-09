#!/bin/sh
# amdgpu userptr fast path: builds the amdgpu module of the RUNNING kernel with the patch below, installs it beside the
# distribution's own (in /lib/modules/<kernel>/updates/, which depmod prefers), or takes it out again.
#
#   sudo sh amdgpu-userptr-fastpath.sh install     build for the running kernel and install (asks for "yes")
#   sudo sh amdgpu-userptr-fastpath.sh uninstall   remove it: the distribution's module is used again
#   sh amdgpu-userptr-fastpath.sh status           which amdgpu is installed and which one is loaded
#   sh amdgpu-userptr-fastpath.sh build            only build it, into ./amdgpu-userptr-fastpath-<kernel>/ (no root)
#
# Reboot after install and uninstall. After a kernel update the new kernel has the stock module: run install again.
#
# WARNING: the patch weakens a security check in the amdgpu driver; the amdgpu maintainer rejected the same change
# upstream ("it leads to security issues"). Read https://github.com/deadlynch/phenom-kernel-patches before using it.
#
# How it builds: the amdgpu sources of the kernel's version from kernel.org (sha256 checked against kernel.org's
# sha256sums.asc), the patch applied, compiled as an external module against the running kernel's own headers
# (/lib/modules/<kernel>/build) with the same compiler family, stripped, signed when the headers carry the kernel's
# signing key, compressed like the kernel's other modules. Needs: the kernel headers package, make, patch, curl, xz,
# and gcc or clang + lld as the kernel was built with.
set -eu

NAME=amdgpu-userptr-fastpath
KERNEL=$(uname -r)
BUILD=/lib/modules/$KERNEL/build
DEST=/lib/modules/$KERNEL/updates/$NAME
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/$NAME

die() { echo "$NAME: $*" >&2; exit 1; }
say() { echo "$NAME: $*"; }
need_root() { [ "$(id -u)" = 0 ] || die "run it with sudo"; }
conf() { grep -E "^$1=" "$BUILD/.config" 2>/dev/null | cut -d= -f2- | tr -d '"'; }

# ------------------------------------------------------------------ the patch (GPL-2.0-only, like the kernel)
write_patch() {
cat > "$1" <<'PATCH_END'
diff --git a/drivers/gpu/drm/amd/amdgpu/amdgpu_cs.c b/drivers/gpu/drm/amd/amdgpu/amdgpu_cs.c
index ef8a61ce4..acb74a839 100644
--- a/drivers/gpu/drm/amd/amdgpu/amdgpu_cs.c
+++ b/drivers/gpu/drm/amd/amdgpu/amdgpu_cs.c
@@ -909,6 +909,21 @@ static int amdgpu_cs_parser_bos(struct amdgpu_cs_parser *p,
 			goto out_free_user_pages;
 		}
 
+		/* The pages the last submission used are still the backing
+		 * pages when the MMU notifier has seen no invalidation since:
+		 * skip faulting in and comparing every page again (a large
+		 * imported host allocation costs a walk of all its pages per
+		 * submission otherwise). amdgpu_cs_submit() checks the sequence
+		 * again under the notifier lock, as for a fresh range.
+		 */
+		if (bo->userptr_seq_set &&
+		    !mmu_interval_read_retry(&bo->notifier, bo->userptr_seq)) {
+			e->range->hmm_range.notifier = &bo->notifier;
+			e->range->hmm_range.notifier_seq = bo->userptr_seq;
+			e->user_invalidated = false;
+			continue;
+		}
+
 		r = amdgpu_ttm_tt_get_user_pages(bo, e->range);
 		if (r)
 			goto out_free_user_pages;
@@ -1325,7 +1340,13 @@ static int amdgpu_cs_submit(struct amdgpu_cs_parser *p,
 	 */
 	r = 0;
 	amdgpu_bo_list_for_each_userptr_entry(e, p->bo_list) {
-		r |= !amdgpu_hmm_range_valid(e->range);
+		bool valid = amdgpu_hmm_range_valid(e->range);
+
+		r |= !valid;
+		/* the BO's pages are those of this range's sequence now */
+		e->bo->userptr_seq_set = valid;
+		if (valid)
+			e->bo->userptr_seq = e->range->hmm_range.notifier_seq;
 		amdgpu_hmm_range_free(e->range);
 		e->range = NULL;
 	}
diff --git a/drivers/gpu/drm/amd/amdgpu/amdgpu_object.h b/drivers/gpu/drm/amd/amdgpu/amdgpu_object.h
index ff11a0903..d655dbda8 100644
--- a/drivers/gpu/drm/amd/amdgpu/amdgpu_object.h
+++ b/drivers/gpu/drm/amd/amdgpu/amdgpu_object.h
@@ -116,6 +116,11 @@ struct amdgpu_bo {
 
 #ifdef CONFIG_MMU_NOTIFIER
 	struct mmu_interval_notifier	notifier;
+	/* userptr: notifier sequence of the pages the last submission used
+	 * (amdgpu_cs.c); valid while userptr_seq_set and no invalidation since
+	 */
+	unsigned long			userptr_seq;
+	bool				userptr_seq_set;
 #endif
 	struct kgd_mem                  *kfd_bo;
 
PATCH_END
}

# ------------------------------------------------------------------ checks
check_kernel() {
    [ -f "$BUILD/Makefile" ] && [ -f "$BUILD/.config" ] && [ -f "$BUILD/Module.symvers" ] || die "no headers for kernel
  $KERNEL in $BUILD. Install your distribution's kernel headers package (linux-headers, linux-cachyos-headers,
  kernel-devel, linux-headers-$KERNEL...) for this exact kernel, then run it again."
    case $(conf CONFIG_DRM_AMDGPU) in
    m) ;;
    y) die "amdgpu is built into this kernel, not a module: rebuild the kernel with the patch instead (README)" ;;
    *) die "this kernel has no amdgpu driver" ;;
    esac
    V=$(sed -n 's/^VERSION = //p' "$BUILD/Makefile"); P=$(sed -n 's/^PATCHLEVEL = //p' "$BUILD/Makefile")
    S=$(sed -n 's/^SUBLEVEL = //p' "$BUILD/Makefile")
    [ -n "$V" ] && [ -n "$P" ] || die "can't read the kernel version from $BUILD/Makefile"
    BASE=$V.$P; [ "${S:-0}" = 0 ] || BASE=$V.$P.$S
    if [ -n "$(conf CONFIG_CC_IS_CLANG)" ]; then
        MAKEVARS="LLVM=1"
        for t in clang ld.lld; do command -v $t >/dev/null || die "the kernel was built with clang: install clang and lld"; done
    else
        MAKEVARS=""
        command -v gcc >/dev/null || die "the kernel was built with gcc: install gcc"
    fi
    for t in make patch curl xz; do command -v $t >/dev/null || die "install $t"; done
    EXT=""
    [ -z "$(conf CONFIG_MODULE_COMPRESS_ZSTD)" ] || EXT=.zst
    [ -z "$(conf CONFIG_MODULE_COMPRESS_XZ)" ] || EXT=.xz
    [ -z "$(conf CONFIG_MODULE_COMPRESS_GZIP)" ] || EXT=.gz
    case $EXT in .zst) command -v zstd >/dev/null || die "install zstd" ;; .xz) ;; .gz) command -v gzip >/dev/null || die "install gzip" ;; esac
}

can_load_unsigned() {  # 0 when an unsigned module would load
    [ "$(cat /sys/module/module/parameters/sig_enforce 2>/dev/null)" != Y ] || return 1
    [ -n "$(conf CONFIG_MODULE_SIG_FORCE)" ] && return 1
    case $(cat /sys/kernel/security/lockdown 2>/dev/null) in *"[none]"*|"") return 0 ;; *) return 1 ;; esac
}

# ------------------------------------------------------------------ build
build() {  # $1: output dir; leaves $1/amdgpu.ko$EXT
    out=$1
    check_kernel
    say "kernel $KERNEL (kernel.org $BASE, ${MAKEVARS:-gcc}), modules ${EXT:-uncompressed}"
    mkdir -p "$CACHE" "$out"
    tarball=linux-$BASE.tar.xz
    url=https://cdn.kernel.org/pub/linux/kernel/v$V.x
    if [ ! -f "$CACHE/$tarball" ]; then
        say "downloading $url/$tarball"
        curl -fL --proto '=https' -o "$CACHE/$tarball.part" "$url/$tarball" || die "download failed"
        mv "$CACHE/$tarball.part" "$CACHE/$tarball"
    fi
    curl -fsL --proto '=https' -o "$CACHE/sha256sums.asc" "$url/sha256sums.asc" || die "can't get kernel.org's sha256sums"
    want=$(awk -v f="$tarball" '$2 == f {print $1}' "$CACHE/sha256sums.asc")
    [ -n "$want" ] && [ "$(sha256sum "$CACHE/$tarball" | cut -d' ' -f1)" = "$want" ] ||
        { rm -f "$CACHE/$tarball"; die "$tarball doesn't match kernel.org's sha256: removed, run it again"; }
    src=$out/src
    rm -rf "$src" && mkdir -p "$src"
    say "unpacking the amd driver sources"
    tar -xJf "$CACHE/$tarball" -C "$src" --strip-components=1 "linux-$BASE/drivers/gpu/drm/amd"
    write_patch "$out/$NAME.patch"
    (cd "$src" && patch -p1 --dry-run -s < "$out/$NAME.patch" >/dev/null 2>&1) ||
        die "the patch doesn't apply to kernel $BASE's amdgpu: this kernel isn't supported"
    (cd "$src" && patch -p1 -s < "$out/$NAME.patch")
    say "building amdgpu (a few minutes; tens of minutes on an old CPU)"
    # (-I: the tracepoint headers include ../../drivers/gpu/drm/amd/... from the kernel tree; this resolves it here)
    # shellcheck disable=SC2086
    make -C "$BUILD" $MAKEVARS M="$src/drivers/gpu/drm/amd/amdgpu" KCFLAGS="-I$src/drivers/gpu" -j"$(nproc)" modules \
        > "$out/build.log" 2>&1 || { tail -20 "$out/build.log"; die "build failed: see $out/build.log"; }
    if grep -q "undefined!" "$out/build.log"; then grep "undefined!" "$out/build.log" | head; die "missing kernel symbols"; fi
    ko=$out/amdgpu.ko
    cp "$src/drivers/gpu/drm/amd/amdgpu/amdgpu.ko" "$ko"
    if [ -n "$MAKEVARS" ]; then llvm-strip --strip-debug "$ko" 2>/dev/null || strip --strip-debug "$ko"
    else strip --strip-debug "$ko"; fi
    key=$BUILD/$(conf CONFIG_MODULE_SIG_KEY)
    if [ -n "$(conf CONFIG_MODULE_SIG)" ] && [ -f "$key" ] && [ -f "$BUILD/certs/signing_key.x509" ]; then
        "$BUILD/scripts/sign-file" "$(conf CONFIG_MODULE_SIG_HASH)" "$key" "$BUILD/certs/signing_key.x509" "$ko"
        say "signed with the kernel's own key"
    else
        SIGNED=no
    fi
    case $EXT in .zst) zstd -q -19 --rm -f "$ko" ;; .xz) xz -f --check=crc32 "$ko" ;; .gz) gzip -9 -n -f "$ko" ;; esac
    [ "$(modinfo -F vermagic "$ko$EXT" | cut -d' ' -f1)" = "$KERNEL" ] || die "built for another kernel version"
    rm -rf "$src"
    say "built $ko$EXT"
}

initramfs() {
    if command -v dracut >/dev/null; then dracut -f --kver "$KERNEL"
    elif command -v mkinitcpio >/dev/null; then mkinitcpio -P
    elif command -v update-initramfs >/dev/null; then update-initramfs -u -k "$KERNEL"
    elif command -v booster >/dev/null; then booster build --force --kernel-version "$KERNEL" "/boot/booster-$(uname -r).img"
    else say "no dracut, mkinitcpio, update-initramfs or booster: if amdgpu is in your initramfs, rebuild it yourself"
    fi
}

restore_legacy() {  # an earlier version of this repo replaced the module in place and kept the original as *.orig
    for o in /lib/modules/$KERNEL/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko*.orig; do
        [ -e "$o" ] || continue
        mv -f "$o" "${o%.orig}"
        say "put the original ${o%.orig} back (from an earlier in-place install)"
    done
}

install_mod() {
    need_root
    check_kernel
    SIGNED=yes
    cat <<'EOF'

  WARNING: this patch weakens a security check in the amdgpu driver. The amdgpu maintainer
  rejected the same change upstream ("it leads to security issues"). A local program could
  abuse it to make the GPU read or write memory it shouldn't. Use it only on a single-user
  gaming PC, keep a known-good kernel in the boot menu, and know how to undo it:
      sudo sh amdgpu-userptr-fastpath.sh uninstall && sudo reboot
  Your distribution's own changes to amdgpu (if any) are replaced by kernel.org's amdgpu.

EOF
    if [ "${YES:-}" != 1 ]; then
        printf 'Type "yes" to build and install it for kernel %s: ' "$KERNEL"
        read -r answer < /dev/tty || answer=
        [ "$answer" = yes ] || die "nothing installed"
    fi
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    build "$work"
    if [ "$SIGNED" = no ]; then
        can_load_unsigned || die "the module isn't signed (your headers don't carry the kernel's signing key) and this
  kernel only loads signed modules (Secure Boot / lockdown / sig_enforce): sign it with a key your kernel trusts
  (a Machine Owner Key) or disable that, then run it again. Nothing installed."
        say "not signed (no signing key in the headers): the kernel loads it and marks itself tainted"
    fi
    restore_legacy
    mkdir -p "$DEST"
    install -m 644 -o root -g root "$work/amdgpu.ko$EXT" "$DEST/amdgpu.ko$EXT"
    echo "$NAME for $KERNEL, built $(date -u +%F) from kernel.org $BASE" > "$DEST/README"
    depmod "$KERNEL"
    [ "$(modinfo -n -k "$KERNEL" amdgpu)" = "$DEST/amdgpu.ko$EXT" ] ||
        say "warning: depmod still picks $(modinfo -n -k "$KERNEL" amdgpu); your depmod.d search order must put 'updates' first"
    initramfs
    say "installed for $KERNEL: reboot to load it (sudo reboot)"
}

uninstall_mod() {
    need_root
    found=no
    [ -d "$DEST" ] && { rm -rf "$DEST"; found=yes; }
    for o in /lib/modules/$KERNEL/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko*.orig; do [ -e "$o" ] && found=yes; done
    restore_legacy
    [ "$found" = yes ] || die "not installed for kernel $KERNEL"
    depmod "$KERNEL"
    initramfs
    say "removed: reboot to load the distribution's amdgpu again (sudo reboot)"
}

status() {
    say "kernel $KERNEL"
    if ls "$DEST"/amdgpu.ko* >/dev/null 2>&1; then say "installed: $(cat "$DEST/README" 2>/dev/null)"
    elif ls /lib/modules/"$KERNEL"/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko*.orig >/dev/null 2>&1; then
        say "installed in place by an earlier version (original kept as *.orig): run install or uninstall to tidy up"
    else say "not installed for this kernel"; fi
    say "depmod picks: $(modinfo -n amdgpu 2>/dev/null || echo none)"
    if [ -r /sys/module/amdgpu/taint ]; then
        case $(cat /sys/module/amdgpu/taint) in
        *O*) say "loaded: an out-of-tree amdgpu (this one, if installed)" ;;
        *) say "loaded: the kernel's own amdgpu" ;;
        esac
    else say "loaded: amdgpu is not loaded"; fi
}

case ${1:-} in
install) [ "${2:-}" = --yes ] && YES=1; install_mod ;;
uninstall) uninstall_mod ;;
status) status ;;
build) check_kernel; SIGNED=yes; build "$PWD/$NAME-$KERNEL" ;;
*) sed -n '2,13p' "$0"; exit 2 ;;
esac
