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

**Prebuilt module** (the one installed on the Phenom): the
[amdgpu-7.3.3-tkg-eevdf-llvm release](https://github.com/deadlynch/phenom-kernel-patches/releases/tag/amdgpu-7.3.3-tkg-eevdf-llvm)
has `amdgpu.ko.gz`. It loads **only** on the kernel it was built for: `7.3.3-tkg-eevdf-llvm`, linux-tkg with
`configs/7.3.3-tkg-eevdf-llvm.config` (AMD K10 tuning, Clang ThinLTO), signed with that build's own key. Any other
kernel needs the module built from source as below. On the Phenom:

    curl -LO https://github.com/deadlynch/phenom-kernel-patches/releases/download/amdgpu-7.3.3-tkg-eevdf-llvm/amdgpu.ko.gz
    sha256sum amdgpu.ko.gz   # 1ec9fd7664ded684a0c815e90a54a662cc82d617c34acba2b48bd7030892b6c2
    sudo scripts/install-module.sh amdgpu.ko.gz && sudo reboot

Its source is the kernel 7.3.3 tree as linux-tkg prepares it, plus `patches/amdgpu-userptr-skip-unchanged.patch`, built
with that config.

**Only the module, on an already built tree** (2-3 minutes instead of a whole kernel):

    # on the build machine, after applying the patch in the tree (git apply patches/*.patch)
    scripts/build-amdgpu-module.sh ~/kbuild/linux-tkg/linux-src-git out
    # copy out/amdgpu.ko.gz to the Phenom, then there
    sudo scripts/install-module.sh amdgpu.ko.gz && sudo reboot

The module built this way is marked out-of-tree (`amdgpu: loading out-of-tree module taints kernel` at boot): that is
expected.

**Revert** (on the Phenom): `sudo scripts/install-module.sh --revert && sudo reboot`, which restores the
`amdgpu.ko.gz.orig` kept at the first install.

## License

The patch modifies the Linux kernel and is GPL-2.0-only like it. Written with an AI assistant (Claude Code).
