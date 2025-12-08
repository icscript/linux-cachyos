# CLAUDE.md - Project Context for AI Assistants

## Overview

This is a **fork** of [CachyOS/linux-cachyos](https://github.com/CachyOS/linux-cachyos) (the **upstream** repository). The purpose is to build custom CachyOS kernels optimized for blockchain P2P validator nodes.

## Production Branch

```
claude/optimize-kernel-modules-01172y998BL5PYyHj4TFDyqi
```

This is the only branch that matters for production builds. Other branches are experimental/troubleshooting artifacts.

## Primary Kernel Variant

**`linux-cachyos/`** is the primary variant used for builds. It was chosen over `linux-cachyos-server` because it has more user-selectable PKGBUILD options (autofdo, propeller, etc.). An external build script exports environment variables to configure the PKGBUILD options as needed.

**`linux-cachyos-server/`** is legacy and no longer actively used.

## Customizations

### Inlined Builtin Module Configuration

The key customization is the **inlined config section** in the PKGBUILD's `prepare()` function (marked with `### CUSTOM SECTION`). This compiles critical hot-path kernel modules as built-in (`=y`) instead of loadable modules (`=m`), providing 12-18% performance improvement for validator workloads.

> **Note:** Prior to December 2025, this was implemented as a separate `config-fragment-builtin-modules` file. The settings are now inlined directly in the PKGBUILD to eliminate hash conflicts when syncing from upstream. See "Why Inlined?" below.

**Optimized modules (18 total):**
- **Crypto acceleration** (3): AES-NI, GHASH, POLYVAL (encrypted P2P traffic)
- **NVMe storage** (4): nvme, nvme-core, nvme-auth, nvme-keyring (disk I/O latency)
- **Network** (11): ixgbe driver + all dependencies (low-latency networking)

**Target hardware:**
- AMD Zen4 processors (bare metal, not VM)
- Intel ixgbe 10GbE NICs
- NVMe storage

### Enabling/Disabling the Optimizations

**Builtin critical modules** (crypto, NVMe, ixgbe):
```bash
export _builtin_critical_modules=yes   # Enable (default)
export _builtin_critical_modules=no    # Disable
```

**Consumer GPU driver removal** (AMD, Intel, NVIDIA):
```bash
export _disable_gpu_drm=yes   # Disable GPUs (default) - required for Propeller
export _disable_gpu_drm=no    # Enable GPUs (for desktop use)
```

> **Note:** Consumer GPU drivers (AMD/Intel/NVIDIA) are set to `=n` by default to fix Propeller build failures. AMD's Display Core code exceeds LLVM's stack frame size limit during Propeller optimization. IPMI graphics (AST, MGAG200) remain as modules `=m` - we don't modify DRM core settings which are upstream defaults.

### Why Inlined? (Eliminating Hash Conflicts)

Previously, `config-fragment-builtin-modules` was listed in the PKGBUILD's `source=()` array with a corresponding hash in `b2sums`. This caused merge conflicts every time upstream updated their hashes because:
- Upstream's source array had 3 entries
- Our source array had 4 entries (with the fragment)
- The `b2sums` arrays didn't align, causing conflicts

By inlining the config settings directly in the PKGBUILD:
- Our `source` and `b2sums` arrays now match upstream's structure exactly
- Hash updates from upstream can be accepted without conflicts
- Syncing is now a clean merge in most cases

---

## Codebase Maintenance

### Syncing from Upstream

Upstream regularly releases kernel version updates (e.g., 6.17.8 → 6.17.9). To sync:

```bash
git fetch upstream
git checkout claude/optimize-kernel-modules-01172y998BL5PYyHj4TFDyqi
git merge upstream/master
```

**In most cases, this will merge cleanly.** Conflicts only occur if upstream modifies the same PKGBUILD sections we customized (rare).

### If Conflicts Occur

Conflicts are now rare, but if they happen:

1. **In the `prepare()` function**: Preserve our custom sections (marked with `### CUSTOM SECTION` banners)
2. **In the `_builtin_critical_modules` variable**: Keep our definition
3. **In the `_disable_gpu_drm` variable**: Keep our definition
4. **Elsewhere**: Generally take upstream's changes

Our custom code is clearly marked with banner comments:
```bash
### ========================================================================
### CUSTOM SECTION: Builtin Critical Modules Optimization
### Fork: github.com/icscript/linux-cachyos
### ...
### ========================================================================

### ========================================================================
### CUSTOM SECTION: Disable Consumer GPU/DRM Drivers
### Fork: github.com/icscript/linux-cachyos
### ...
### ========================================================================
```

---

## Git Remotes

- `origin` - This fork (icscript/linux-cachyos)
- `upstream` - Source repository (CachyOS/linux-cachyos)

## Technical Notes

- The branch name was auto-generated and is intentionally kept as-is
- SHA crypto modules (SHA1_SSSE3, SHA512_SSSE3) were removed in kernel 6.17 as they moved to lib/crypto
- INTEL_IOATDMA is disabled to allow DCA as builtin on AMD Zen4 (Kconfig constraint)
- The `linux-cachyos-server/` variant has the same inlined customization for consistency

## Documentation

- `KERNEL_MODULE_OPTIMIZATION.md` - Technical details on module selection and performance impact
- `USAGE_GUIDE_MODULE_OPTIMIZATION.md` - User guide for the optimization feature
