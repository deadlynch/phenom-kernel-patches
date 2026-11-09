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

## Use

**With a new linux-tkg build:** the patch is also in `~/kbuild/linux-tkg/linux73-tkg-userpatches/` as `.mypatch`
(`_user_patches="true"` in `customization.cfg`), so it goes into every 7.3 build. For another version, copy it to
`linux<VERSION><PATCHLEVEL>-tkg-userpatches/`.

**Prebuilt module** (the one installed on the Phenom): `install.sh` downloads it from the
[amdgpu-7.3.3-tkg-eevdf-llvm release](https://github.com/deadlynch/phenom-kernel-patches/releases/tag/amdgpu-7.3.3-tkg-eevdf-llvm),
checks its sha256 and kernel version, keeps the original module once as `amdgpu.ko.gz.orig`, installs it and rebuilds
the initramfs. It loads **only** on the kernel it was built for: `7.3.3-tkg-eevdf-llvm`, linux-tkg with
`configs/7.3.3-tkg-eevdf-llvm.config` (AMD K10 tuning, Clang ThinLTO), signed with that build's own key; the script
refuses any other kernel.

    curl -LO https://raw.githubusercontent.com/deadlynch/phenom-kernel-patches/main/install.sh
    sudo sh install.sh install      # asks you to type "yes" after the warning
    sudo reboot
    sh install.sh status            # which module is on disk and which one is loaded
    sudo sh install.sh uninstall && sudo reboot    # the original module back

Its source is the kernel 7.3.3 tree as linux-tkg prepares it, plus `patches/amdgpu-userptr-skip-unchanged.patch`, built
with that config.

**Only the module, on an already built tree** (2-3 minutes instead of a whole kernel):

    # on the build machine, after applying the patch in the tree (git apply patches/*.patch)
    scripts/build-amdgpu-module.sh ~/kbuild/linux-tkg/linux-src-git out
    # copy out/amdgpu.ko.gz to the Phenom, then there
    sudo sh install.sh install amdgpu.ko.gz && sudo reboot   # (any module for the running kernel, same compression)

The module built this way is marked out-of-tree (`amdgpu: loading out-of-tree module taints kernel` at boot): that is
expected.

**Revert** (on the Phenom): `sudo sh install.sh uninstall && sudo reboot`, which restores the `amdgpu.ko.gz.orig`
kept at the first install.

## On another machine

The prebuilt module only fits the Phenom's kernel. Elsewhere the patch has to be built into **your** kernel, from its
source and with its config: a module built from another tree can load and still crash, because core kernel structures
differ between builds. The caveats above apply the same.

1. **Rebuild your kernel with the patch** (the reliable way). Most kernel builders take extra patches:
   - linux-tkg: put it in `linux<VERSION><PATCHLEVEL>-tkg-userpatches/` as `amdgpu-userptr-skip-unchanged.mypatch`
     (`_user_patches="true"` in `customization.cfg`).
   - Arch-style PKGBUILD (`linux`, CachyOS kernels): add it to `source=()` and apply it in `prepare()`.
   - Gentoo: `/etc/portage/patches/sys-kernel/gentoo-sources/`.
   - A plain kernel.org tree: `git apply` or `patch -p1` in it, then build as usual.

   It applies to 7.3 and should to newer kernels while `amdgpu_cs_parser_bos()` keeps its current shape (unchanged up
   to 7.3 and amd-staging-drm-next as of 2026-11-08).
2. **Only the module, from your own kernel's build tree:** after a kernel build you still have (the tree you installed
   it from, with its `.config`, `Module.symvers` and signing key), apply the patch there and run
   `scripts/build-amdgpu-module.sh <tree> out`, then `sudo sh install.sh install out/amdgpu.ko.gz`. It must be the
   exact tree of the running kernel: `install.sh` checks the version, not the build.
3. **Distribution kernels you don't build** (Ubuntu, Fedora, stock Arch): use route 1 with the distribution's kernel
   package source. With Secure Boot or `module.sig_enforce`, a module you build must be signed with a key the kernel
   trusts, or it won't load.

## License

The patch modifies the Linux kernel and is GPL-2.0-only like it. Written with an AI assistant (Claude Code).
