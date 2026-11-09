# Phenom kernel patches

Local kernel patches for my Phenom II X6 1100T + RX 580 gaming PC (Void Linux, linux-tkg kernels built on another
machine). Kept here so they survive kernel rebuilds.

> [!WARNING]
> **`amdgpu-userptr-skip-unchanged.patch` is a deliberate local trade-off, not a fix to share.** The same idea was
> posted to amd-gfx on 2026-03-31 ("drm/amdgpu: add fast-path for userptr BO validation") and the amdgpu maintainer
> rejected it: *"we have intentionally removed that before because it leads to security issues"*. Use it only on a
> machine where that risk is acceptable (a single-user gaming PC). Don't send it upstream, don't recommend it.

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
