# CLAUDE.md - Project Context for AI Assistants

## Overview

This is a **fork** of [CachyOS/linux-cachyos](https://github.com/CachyOS/linux-cachyos) (the **upstream** repository). The purpose is to build custom CachyOS kernels optimized for blockchain P2P validator nodes.

## Production Branch

```
claude/optimize-kernel-modules-01172y998BL5PYyHj4TFDyqi
```

This is the only branch that matters for production builds. Other branches are experimental/troubleshooting artifacts.

## Customizations

### Config Fragment for Built-in Modules

The key customization is `config-fragment-builtin-modules`, which compiles critical hot-path kernel modules as built-in (`=y`) instead of loadable modules (`=m`). This provides 5-12% performance improvement for validator workloads.

**Optimized modules:**
- **Crypto acceleration**: AES-NI, GHASH, POLYVAL (encrypted P2P traffic)
- **NVMe storage**: nvme, nvme-core, nvme-auth (disk I/O latency)
- **Network**: ixgbe driver + dependencies (low-latency networking)

**Target hardware:**
- AMD Zen4 processors (bare metal, not VM)
- Intel ixgbe 10GbE NICs
- NVMe storage

**Modified kernel variants:**
- `linux-cachyos/` - Desktop variant with optimizations
- `linux-cachyos-server/` - Server variant with optimizations

Both variants have their own copy of `config-fragment-builtin-modules` in their directories.

### Enabling/Disabling Optimizations

The PKGBUILD checks for `_builtin_critical_modules`:
```bash
# Enable (default):
export _builtin_critical_modules=yes

# Disable:
export _builtin_critical_modules=no
```

## Syncing from Upstream

Upstream regularly releases kernel version updates (e.g., 6.17.8 → 6.17.9). To sync:

```bash
# Fetch upstream changes
git fetch upstream

# Merge into production branch
git checkout claude/optimize-kernel-modules-01172y998BL5PYyHj4TFDyqi
git merge upstream/master
```

### Resolving b2sums Conflicts

Conflicts typically occur in the `b2sums` array in PKGBUILDs. The array maps 1:1 to the `source` array:

```bash
source=(
    "linux-X.Y.Z.tar.xz"              # → hash 1 (kernel tarball)
    "config"                           # → hash 2 (kernel config)
    "config-fragment-builtin-modules"  # → hash 3 (OUR custom file)
    "0001-cachyos-base-all.patch"      # → hash 4 (upstream patch)
)
```

**Resolution pattern:**
- **Keep our hash** for `config-fragment-builtin-modules` (unchanged)
- **Take upstream's hash** for the patch file (updated with new kernel version)
- **Take upstream's hash** for kernel tarball (new version)

Example conflict:
```
<<<<<<< HEAD (our branch)
        'abc123...'  # our config-fragment hash
        'old456...'  # old patch hash
=======
        'new789...'  # new patch hash from upstream
>>>>>>> upstream/master
```

Correct resolution:
```
        'abc123...'  # keep our config-fragment hash
        'new789...'  # take upstream's new patch hash
```

## Building the Kernel

```bash
cd linux-cachyos  # or linux-cachyos-server
makepkg -s
```

## Repository Structure

```
linux-cachyos/                    # Desktop variant (EEVDF scheduler)
├── PKGBUILD
├── config
└── config-fragment-builtin-modules

linux-cachyos-server/             # Server variant
├── PKGBUILD
├── config
└── config-fragment-builtin-modules

linux-cachyos-bore/               # BORE scheduler variant (unmodified)
linux-cachyos-bmq/                # BMQ scheduler variant (unmodified)
... (other variants are unmodified)
```

## Git Remotes

- `origin` - This fork (icscript/linux-cachyos)
- `upstream` - Source repository (CachyOS/linux-cachyos)

## Notes

- The branch name was auto-generated and is intentionally kept as-is
- SHA crypto modules (SHA1_SSSE3, SHA512_SSSE3) were removed from the fragment in kernel 6.17 as they moved to lib/crypto
- INTEL_IOATDMA is disabled to allow DCA as builtin on AMD Zen4 (Kconfig constraint)
