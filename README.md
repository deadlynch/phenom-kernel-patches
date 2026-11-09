# Phenom kernel patches

Local kernel patches for my Phenom II X6 1100T + RX 580 gaming PC (Void Linux, linux-tkg kernels built on another
machine). Kept here so they survive kernel rebuilds.

> [!CAUTION]
> **Read this before using anything here.**
>
> - **`amdgpu-userptr-skip-unchanged.patch` weakens a security check in the amdgpu driver.** The same idea was posted
>   to amd-gfx on 2026-03-31 ([drm/amdgpu: add fast-path for userptr BO validation](https://ratatoskr.run/amd-gfx/2026/03/16014637/t))
>   and the amdgpu maintainer rejected it at once: *"Well absolutely clear NAK on that, we have intentionally removed
>   that before because it leads to security issues."* The exact issue isn't documented there; the check it skips is
>   what makes sure the GPU only touches memory pages that still belong to the program that submitted the work.
> - **Assume a local program could abuse it** to make the GPU read or write memory it shouldn't (memory disclosure or
>   corruption). Anything that submits GPU work counts, including a web browser's GPU process.
> - **Only for a single-user machine used for games**, where that risk is accepted on purpose. Not for a PC with
>   personal, work or financial data, not for shared or multi-user systems, not for servers.
> - **Not upstream, not supported, no warranty.** It will not be sent to the kernel; don't report bugs from a kernel
>   with it to amdgpu or your distribution. The numbers below come from one machine and one game.
> - **Kernel modules can stop your system from booting.** Keep a known-good kernel in the boot menu and know how to
>   revert (below) before installing.
> - Written with an AI assistant (Claude Code); the human who installs it is responsible for it.

## amdgpu-userptr-skip-unchanged.patch

**Problem.** On every command submission, `amdgpu_cs_parser_bos()` faults in (`hmm_range_fault`) and compares every
page of every userptr BO in the submission, allocating a page array for it each time. Games that import a large host
allocation through `VK_EXT_external_memory_host` pay that per submission: Power Moon Recomp (Super Mario Odyssey)
imports its whole 3.2 GB guest heap, and on the Phenom its render thread spent ~68% of its time in the kernel
(`amdgpu_cs_parser_bos` 27%, `hmm_vma_walk_pmd` 25%, `prep_new_page` 11%).

**Change.** The BO remembers the MMU notifier sequence of the pages the last valid submission used. While the
notifier has seen no invalidation since, the walk is skipped; `amdgpu_cs_submit()` still checks the sequence under the
notifier lock as for a fresh range.

**Measured** (Power Moon Recomp 0.2.1-k10, same spot, `ODYSSEY_VK_PROF=1`, 2-second windows):

| | stock amdgpu | patched |
|---|---|---|
| fps | 37-45 | 60 (the game's cap) |
| worst frame | 25-29 ms | 17-18 ms |
| `vkQueueSubmit` per 2 s | ~1200 ms | ~18 ms |
| render thread | 25% user + 68% kernel | 55% user + 2% kernel |

TotK Recomp and Savage Wind Recomp import host memory too, so they may gain as well (not measured yet).

Written for 7.3.3 (`drivers/gpu/drm/amd/amdgpu/amdgpu_cs.c`, `amdgpu_object.h`); unchanged upstream as of 2026-11-08
(amd-staging-drm-next and mainline), so it should apply to the next kernels too.

## Install or remove

`amdgpu-userptr-fastpath.sh` does it for the **running kernel**, on any distribution where amdgpu is a module:

    curl -LO https://raw.githubusercontent.com/deadlynch/phenom-kernel-patches/main/amdgpu-userptr-fastpath.sh
    sudo sh amdgpu-userptr-fastpath.sh install      # shows the warning, asks you to type "yes", builds and installs
    sudo reboot
    sh amdgpu-userptr-fastpath.sh status            # what is installed and which amdgpu is loaded
    sudo sh amdgpu-userptr-fastpath.sh uninstall && sudo reboot   # back to your distribution's amdgpu

What `install` does:

1. Checks that your kernel's headers are installed (`/lib/modules/<kernel>/build`: the `linux-headers`,
   `linux-cachyos-headers`, `kernel-devel` or `linux-headers-<kernel>` package of **that exact kernel**) and that
   amdgpu is a module there.
2. Downloads that kernel version's source from kernel.org (checked against kernel.org's `sha256sums.asc`) and unpacks
   only `drivers/gpu/drm/amd`.
3. Applies the patch (it is inside the script) and stops if it doesn't apply cleanly.
4. Builds only amdgpu, as an external module against **your** kernel's headers, with the compiler your kernel was
   built with (gcc, or clang + lld): the way DKMS modules are built. That matches your kernel's own structures.
5. Strips it, signs it when your headers carry the kernel's signing key, compresses it like your other modules.
6. Installs it as `/lib/modules/<kernel>/updates/amdgpu-userptr-fastpath/amdgpu.ko*`, beside the distribution's
   module, which stays untouched: `depmod` prefers `updates/`. Then rebuilds the initramfs (dracut, mkinitcpio,
   update-initramfs or booster).

`uninstall` deletes that folder, runs `depmod` and rebuilds the initramfs. `build` only builds it into
`./amdgpu-userptr-fastpath-<kernel>/`, without root and without installing.

Things to know:

- **Kernel updates:** the new kernel comes with the stock amdgpu. Run `install` again after booting it.
- **Distribution changes to amdgpu are lost:** the module is built from kernel.org's source of the same version.
- **Signing:** distribution headers don't carry the kernel's signing key, so the module isn't signed. Without Secure
  Boot / lockdown / `module.sig_enforce` the kernel loads it and marks itself tainted; with them the script refuses
  to install it (sign it with a Machine Owner Key yourself, or don't use it).
- Built-in amdgpu (`CONFIG_DRM_AMDGPU=y`) can't be replaced this way: rebuild the kernel with the patch.
- **Compiler:** a module must be built with the compiler family and major version that built the kernel. The script
  checks it (`CONFIG_CLANG_VERSION` / `CONFIG_GCC_VERSION`) and says which one to install; with clang it takes
  `clang-N`, `ld.lld-N`... when the plain `clang` is another version. A kernel built on another machine with a newer
  compiler than this one has can't get its module built here.
- **Tested:** `build` on CachyOS 7.3.1 (clang 23, zstd modules): same dependencies as the stock module, no missing
  symbols. `install` and `uninstall` haven't been run on a real system yet; the module they install is the one `build`
  makes. On the Phenom the patch was installed by hand (the module replaced in place); the script puts back such a
  module's original (`*.orig`) before installing or on uninstall.

## Patching your own kernel build

The patch is also in `patches/` for kernel builders: linux-tkg (`linux<VERSION><PATCHLEVEL>-tkg-userpatches/` as a
`.mypatch`, with `_user_patches="true"`), an Arch-style PKGBUILD (`source=()` and `prepare()`), Gentoo
(`/etc/portage/patches/sys-kernel/gentoo-sources/`), or `patch -p1` in a plain tree. It applies to 7.3 and should to
newer kernels while `amdgpu_cs_parser_bos()` keeps its shape (unchanged up to 7.3 and amd-staging-drm-next as of
2026-11-08).

## License

The patch modifies the Linux kernel and is GPL-2.0-only like it. Written with an AI assistant (Claude Code).
