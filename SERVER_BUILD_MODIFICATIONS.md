# Server Build Modifications for CachyOS Kernel

## Overview
This fork builds a bare metal server-optimized kernel by excluding desktop/workstation hardware subsystems that are unnecessary for datacenter environments.

**NOTE:** Server mode is **ENABLED BY DEFAULT** in this fork. Set `_server_build=no` to build with desktop hardware support.

## Changes Made

### 1. New Build Option: `_server_build`
Added a new configuration variable `_server_build` (default: `yes`) that controls server-specific optimizations.

**Location:** Line 130 in PKGBUILD

```bash
: "${_server_build:=yes}"
```

### 2. Modified DRM Panic Screen Behavior
The QR Code Panic screen feature (which requires DRM) is now disabled when `_server_build=yes`.

**Location:** Line 355 in PKGBUILD

**Before:**
```bash
if ! _is_lto_kernel; then
```

**After:**
```bash
if ! _is_lto_kernel && [ "$_server_build" != "yes" ]; then
```

### 3. Subsystems Disabled in Server Mode
When `_server_build=yes`, the following subsystems are completely disabled:

**Graphics/Display (DRM):**
- CONFIG_DRM - Direct Rendering Manager
- CONFIG_DRM_FBDEV_EMULATION - Framebuffer device emulation
- CONFIG_DRM_PANIC - Panic screen support
- CONFIG_DRM_SIMPLEDRM - Simple DRM driver

**Wireless:**
- CONFIG_WIRELESS - Wireless subsystem
- CONFIG_WLAN - Wireless LAN
- CONFIG_CFG80211 - cfg80211 wireless configuration API
- CONFIG_MAC80211 - Generic IEEE 802.11 networking stack

**Bluetooth:**
- CONFIG_BT - Bluetooth subsystem

**Audio:**
- CONFIG_SOUND - Sound card support
- CONFIG_SND - Advanced Linux Sound Architecture (ALSA)

**Multimedia:**
- CONFIG_MEDIA_SUPPORT - Multimedia support
- CONFIG_VIDEO_DEV - Video4Linux
- CONFIG_DVB_CORE - Digital Video Broadcasting

## Usage

### Basic Server Build
Server mode is **enabled by default**. Simply build:

```bash
export _cachy_config=no  # Recommended: disable desktop optimizations
makepkg -s
```

To build with desktop hardware support, disable server mode:

```bash
export _server_build=no
makepkg -s
```

### Recommended Server Configuration

```bash
# Core settings (_server_build=yes is the default)
export _cachy_config=no          # Disable desktop scheduler/memory tuning

# Performance settings
export _cc_harder=yes            # Enable -O3 optimization
export _use_llvm_lto=thin        # Enable Thin LTO for performance
export _processor_opt=native     # Or "generic" for portability

# Server-appropriate tuning
export _HZ_ticks=300             # Lower tick rate (balance latency/throughput)
export _preempt=voluntary        # Voluntary preemption for throughput
export _hugepage=always          # THP for database/large memory workloads
export _tcp_bbr3=yes             # Modern TCP congestion control

# Module optimization (optional)
export _localmodcfg=yes          # Only build modules you use
export _localmodcfg_path="$HOME/.config/modprobed.db"
```

## Important Considerations

### 1. **No Graphics Output**
With `_server_build=yes`, the kernel will have **NO** graphics capability. This means:
- ❌ No console output on VGA/HDMI/DisplayPort
- ❌ No framebuffer console
- ✅ Serial console (ttyS0) still works for IPMI/SOL/iLO/DRAC

### 2. **Remote Management Required**
Ensure your servers have working:
- Serial console access (IPMI Serial-over-LAN)
- Network-based remote management (SSH after boot)
- Out-of-band management (iLO, iDRAC, IPMI)

### 3. **Testing Virtual Console**
Before deploying, test your datacenter provider's virtual console:
- KVM-over-IP (may not work without DRM)
- Serial console (should work)
- Remote crash dumps (serial console based)

### 4. **CachyOS Config**
Set `_cachy_config=no` for servers because the CachyOS optimizations are desktop-focused:
- Desktop: Lower latency, more context switches, interactive responsiveness
- Server: Higher throughput, fewer context switches, batch processing efficiency

## What's Preserved

The following essential server features remain **enabled**:

✅ **Virtual Terminal (VT)** - Console support
✅ **Serial Console** - UART/ttyS0 for remote access
✅ **Network drivers** - Ethernet (e1000e, ixgbe, etc.)
✅ **Storage drivers** - NVMe, SATA, SAS, hardware RAID
✅ **Virtualization** - KVM, virtio
✅ **Server hardware** - IPMI, sensors, watchdogs

## Build Size Reduction

Approximate reductions when using `_server_build=yes`:
- **Build time:** ~15-25% faster (fewer drivers to compile)
- **Kernel modules:** ~200-400MB smaller
- **initramfs:** Slightly smaller (fewer modules loaded)

## Compatibility

### Works With:
- ✅ Dedicated bare metal servers
- ✅ Headless systems
- ✅ Remote/datacenter deployments
- ✅ Serial console management
- ✅ SSH-only access

### Does NOT Work With:
- ❌ Desktop systems
- ❌ Laptops
- ❌ Systems requiring local graphics
- ❌ Workstations
- ❌ WiFi-dependent systems

## Testing Checklist

Before deploying to production:

- [ ] Kernel boots successfully
- [ ] Serial console works (IPMI SOL / ttyS0)
- [ ] Network interfaces come up
- [ ] Storage devices detected
- [ ] Remote SSH access works
- [ ] System logs accessible via serial/ssh
- [ ] Out-of-band management functional
- [ ] Kernel panics visible via serial console

## Maintenance

When updating from upstream CachyOS:

1. Pull latest changes from CachyOS upstream
2. Verify `_server_build` sections are intact
3. Test build with `_server_build=yes`
4. Verify config changes didn't re-enable disabled subsystems

## File Modifications Summary

**Modified:** `linux-cachyos/PKGBUILD`
- Added `_server_build` variable (line ~130)
- Modified DRM_PANIC condition (line ~355)
- Added server hardware disable section (line ~476-501)

## Support

For issues specific to these server modifications, please file issues in this fork's repository.

For general CachyOS kernel issues, refer to upstream: https://github.com/CachyOS/linux-cachyos
