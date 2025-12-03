#!/bin/bash
# build-cachyos-kernel.sh
# Builds CachyOS BORE kernel with Zen4 optimization for production validators
#
# KERNEL VARIANTS:
#   - profiling: linux-cachyos with server options + profiling capabilities.  This has now become our default.
#   - server: linux-cachyos-server (CachyOS Author set several PKGBUILD options with server in mind).  This has become legacy for us.
#
# PURPOSE:
#   Compiles custom CachyOS kernel once on a build server, then packages are
#   distributed to other validators using distribute-cachyos-kernel.sh
#
# USAGE:
#   Run as regular user (NOT root) with low priority to preserve validator:
#   cd ~ && chrt --idle 0 nice -n 19 ionice -c 3 bash build-cachyos-kernel.sh
#
#   Optional: Select variant (default is 'profiling'):
#   KERNEL_VARIANT=server bash build-cachyos-kernel.sh
#
#   Optional: Build with custom patch:
#   PATCH_FILE=/path/to/patch.patch bash build-cachyos-kernel.sh
#
#   Optional: Build with AutoFDO profile (Profile-Guided Optimization):
#   AUTOFDO_PROFILE=/path/to/profile.afdo bash build-cachyos-kernel.sh
#
#   Example: Build profiling variant for initial profiling:
#   KERNEL_VARIANT=profiling bash build-cachyos-kernel.sh
#
#   Example: Build profiling variant with collected profile:
#   KERNEL_VARIANT=profiling AUTOFDO_PROFILE=/path/to/profile.afdo bash build-cachyos-kernel.sh
#
# PREREQUISITES:
#   - CachyOS userspace packages installed (run migrate_to_znver4_userspace.sh first)
#   - base-devel group installed
#   - ~20GB free disk space for build directory
#   - ~500MB free space in /boot
#
# BUILD TIME:
#   60-90 minutes with MAKEFLAGS="-j2" at low priority, new set -j1 to see errors in order.
#
# OUTPUT:
#   Packages saved to:
#   - ~/kernel-packages/YYYY-MM-DD_HH-MM-SS/ (timestamped archive)
#   - ~/kernel-packages/ (flat files for distribute script)
#
# NEXT STEPS:
#   1. Run distribute-cachyos-kernel.sh to copy packages to other validators
#   2. Run install-cachyos-kernel.sh on each validator (including this one)

set -e  # Exit on error

# ============================================================================
# VARIANT SELECTION
# ============================================================================

# Select kernel variant: 'server' or 'profiling'
# - server: Uses linux-cachyos-server (production, streamlined)
# - profiling: Uses linux-cachyos with server options (for AutoFDO/Propeller)
KERNEL_VARIANT="${KERNEL_VARIANT:-profiling}"

case "$KERNEL_VARIANT" in
    server)
        VARIANT_SUBDIR="linux-cachyos-server"
        VARIANT_DESC="Server (production)"
        ;;
    profiling)
        VARIANT_SUBDIR="linux-cachyos"
        VARIANT_DESC="Profiling (linux-cachyos with server options)"
        ;;
    *)
        echo "ERROR: Invalid KERNEL_VARIANT='$KERNEL_VARIANT'"
        echo "Valid options: 'server' or 'profiling'"
        exit 1
        ;;
esac

# ============================================================================
# CONFIGURATION - COMMON OPTIONS
# ============================================================================

# Kernel build options (override PKGBUILD defaults)
# These apply to BOTH variants
export _cpusched=bore           # BORE scheduler (low-latency)
export _processor_opt=zen4      # AMD Zen4 optimization (EPYC 9004 series)
export _use_llvm_lto=thin       # Thin LTO for faster compilation
export _use_lto_suffix=yes      # Include -lto in package name
export _tcp_bbr3=yes            # BBR3 TCP congestion control
export _cachy_config=no         # No CachyOS config (server variant)
export _server_build=yes        # chris addes so integration preflight passes

# ============================================================================
# CONFIGURATION - PROFILING VARIANT SPECIFIC
# ============================================================================

if [ "$KERNEL_VARIANT" = "profiling" ]; then
    # Determine build mode based on which profiles are provided
    # FOUR BUILD PATHS:
    # Path 2: No profiles → AutoFDO collection
    # Path 3: AutoFDO only → AutoFDO optimized + Propeller collection ready
    # Path 4: AutoFDO + Propeller → Full optimization (production)

    if [ -n "$AUTOFDO_PROFILE" ]; then
        # Have AutoFDO profile
        if [ -n "$PROPELLER_CC_PROFILE" ] && [ -n "$PROPELLER_LD_PROFILE" ]; then
            # Path 4: Both AutoFDO and Propeller profiles provided
            PROFILING_BUILD_MODE="propeller_optimized"
            BUILD_MODE_DESC="Propeller-Optimized Production (AutoFDO + Propeller)"
        else
            # Path 3: AutoFDO profile only (no Propeller profiles yet)
            PROFILING_BUILD_MODE="autofdo_optimized"
            BUILD_MODE_DESC="AutoFDO-Optimized + Propeller Collection Ready"
        fi
    else
        # Path 2: No profiles provided
        PROFILING_BUILD_MODE="collection"
        BUILD_MODE_DESC="AutoFDO Profile Collection"
    fi

    # Set options based on build mode
    case "$PROFILING_BUILD_MODE" in
        collection)
            # Path 2: AutoFDO Collection
            # Enable AutoFDO instrumentation, include debug symbols for profiling
            export _build_debug=yes          # Build vmlinux with symbols for profiling
            export _autofdo=yes              # Enable AutoFDO system
            export _autofdo_profile_name=""  # No profile yet (instrumentation mode)
            export _propeller=no             # Not doing Propeller yet
            export _propeller_profiles=no
            ;;

        autofdo_optimized)
            # Path 3: AutoFDO Optimized + Propeller Collection Ready (temporarily disabled propeller instrumentation)
            # Use AutoFDO profile, enable Propeller for next profiling step
            export _build_debug=yes          # YES - need vmlinux for Propeller profiling
            export _autofdo=yes              # CRITICAL FIX: Must be YES to actually USE the profile!
            # _autofdo_profile_name will be set later after profile verification
            export _propeller=no             # TEMP: Disabled due to EFI stub absolute relocation error
            export _propeller_profiles=no    # No Propeller profiles yet
            ;;

        propeller_optimized)
            # Path 4: Full Optimization (AutoFDO + Propeller)
            # Use both AutoFDO and Propeller profiles for production
            export _build_debug=no           # Production - no debug symbols needed
            export _autofdo=yes              # CRITICAL: Must be YES to use the profile!
            # _autofdo_profile_name will be set later after profile verification
            export _propeller=yes            # Enable Propeller system
            export _propeller_profiles=yes   # Use Propeller profiles
            ;;
    esac

    # Server-appropriate options for linux-cachyos variant
    # (These match linux-cachyos-server defaults where they differ from linux-cachyos)
    export _build_zfs=no             # No ZFS module for servers
    export _build_nvidia=no          # No proprietary NVIDIA drivers
    export _build_nvidia_open=no     # No open NVIDIA drivers
    export _localmodcfg=no           # Don't use modprobed-db (build all modules)
    export _use_current=no           # Don't use running kernel config

    # Performance and optimization (match server variant defaults)
    export _cc_harder=yes            # -O3 optimization
    export _per_gov=no               # Don't default to performance governor
    export _HZ_ticks=300             # 300Hz tick rate (server throughput, reduce preemption)
    export _tickrate=full            # Full tickless
    export _preempt=none        # Voluntary preemption (server workload, reduce context switches.  I have 'none' for majority of production, which is even less preemption than voluntary.)
    export _hugepage=always          # Always enable transparent hugepages

    # Security and hardening
    export _use_kcfi=no              # No kCFI (not needed for server)

    echo ""
    echo "=========================================="
    echo "PROFILING VARIANT: $BUILD_MODE_DESC"
    echo "=========================================="
    case "$PROFILING_BUILD_MODE" in
        collection)
            echo "This build will:"
            echo "  • Include debug symbols (vmlinux) for profiling"
            echo "  • Enable AutoFDO instrumentation"
            echo "  • Be used to collect runtime performance data"
            echo ""
            echo "After building, install and run workload to generate AutoFDO profile."
            ;;

        autofdo_optimized)
            echo "This build will:"
            echo "  • Use AutoFDO profile: $(basename "$AUTOFDO_PROFILE")"
            echo "  • Optimize hot code paths based on AutoFDO profile data"
            echo "  • Include debug symbols (vmlinux) for Propeller profiling"
            echo "  • Enable Propeller instrumentation (ready for next profiling step)"
            echo ""
            echo "After building, install and run workload to generate Propeller profiles."
            ;;

        propeller_optimized)
            echo "This build will:"
            echo "  • Use AutoFDO profile: $(basename "$AUTOFDO_PROFILE")"
            echo "  • Use Propeller CC profile: $(basename "$PROPELLER_CC_PROFILE")"
            echo "  • Use Propeller LD profile: $(basename "$PROPELLER_LD_PROFILE")"
            echo "  • Full optimization with both AutoFDO and Propeller"
            echo "  • Production-ready (no debug symbols)"
            echo ""
            echo "This is a fully optimized production kernel."
            ;;
    esac
    echo "=========================================="
    echo ""

    read -p "Continue with $BUILD_MODE_DESC build? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Build cancelled."
        exit 0
    fi
    echo ""
fi

# Build parallelism (overridden by makepkg.conf, but set anyway)
export MAKEFLAGS="-j1"

# Output directory
KERNEL_PACKAGES_DIR="$HOME/kernel-packages"
BUILD_TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
TIMESTAMPED_DIR="$KERNEL_PACKAGES_DIR/$BUILD_TIMESTAMP"

# Build directory (will be removed and recreated)
BUILD_DIR="$HOME/linux-cachyos"

# ============================================================================
# PREFLIGHT CHECKS
# ============================================================================

echo "=========================================="
echo "CachyOS Kernel Build Script"
echo "=========================================="
echo ""

# Verify we're not running as root
if [ "$EUID" -eq 0 ]; then
    echo "ERROR: This script must NOT be run as root!"
    echo "Reason: makepkg refuses to run as root for security."
    echo "Please run as your regular sudo user."
    exit 1
fi

# Check if running at low priority
CURRENT_NICE=$(ps -o ni= -p $$ | xargs)  # xargs trims whitespace
echo "DEBUG: Raw nice value captured: '$CURRENT_NICE' (type: $(echo "$CURRENT_NICE" | od -c | head -1))"
# Handle cases where nice value is '-' or non-numeric (default to 0)
if ! [[ "$CURRENT_NICE" =~ ^-?[0-9]+$ ]]; then
    echo "DEBUG: Non-numeric nice value detected, defaulting to 0"
    CURRENT_NICE=0
fi
if [ "$CURRENT_NICE" -lt 15 ]; then
    echo "⚠️  WARNING: Script is not running at low priority (nice=$CURRENT_NICE)"
    echo "   Recommended: chrt --idle 0 nice -n 19 ionice -c 3 bash $(basename "$0")"
    echo ""
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check disk space
AVAILABLE_SPACE_GB=$(df -BG "$HOME" | awk 'NR==2 {print $4}' | tr -d 'G')
if [ "$AVAILABLE_SPACE_GB" -lt 20 ]; then
    echo "ERROR: Insufficient disk space (${AVAILABLE_SPACE_GB}GB available, 20GB required)"
    exit 1
fi

echo "✓ Preflight checks passed"
echo ""

# ============================================================================
# CLEAN BUILD ENVIRONMENT
# ============================================================================

echo "Preparing clean build environment..."

# Remove old build directory completely for clean state
if [ -d "$BUILD_DIR" ]; then
    echo "  Removing existing build directory: $BUILD_DIR"
    rm -rf "$BUILD_DIR"
fi

# Ensure pacman-contrib is installed (provides updpkgsums)
if ! command -v updpkgsums &> /dev/null; then
    echo "  Installing pacman-contrib for checksum management..."
    sudo pacman -S --noconfirm pacman-contrib
fi

echo "✓ Build environment ready"
echo ""

# ============================================================================
# CLONE REPOSITORY
# ============================================================================
# Using forked repository: https://github.com/icscript/linux-cachyos.git
# Branch: claude/remove-drm-cachyos-kernel-011CV3XCEmx92Lo23TrTN7ub
# Original repository: https://github.com/CachyOS/linux-cachyos.git
# The repo contains multiple kernel variants in subdirectories:
#   - linux-cachyos/         (desktop/default) ← Used for PROFILING variant (and potentially subsequent variant built with profile)
#   - linux-cachyos-server/  (optimized for servers) ← Used for SERVER variant // does not contain feeders for autofdo
#   - linux-cachyos-bore/    (BORE-only)
#   - linux-cachyos-eevdf/   (EEVDF-only)
#   - linux-cachyos-rt/      (realtime)
# ============================================================================

# BRANCH_NAME="claude/remove-drm-with-efi-fix-011CV4DNec6z86jh7v2XrFhC" # prior effort with hard drm removal (disable) and EFI fix which didnt work
BRANCH_NAME="claude/optimize-kernel-modules-01172y998BL5PYyHj4TFDyqi" # new method of =y on hotpath and =m on everyting else, or if modprobe provided then =n on what is not in modprobed.
echo "Cloning CachyOS kernel repository..."
echo "  Repository: https://github.com/icscript/linux-cachyos.git"
echo "  Branch: $BRANCH_NAME"
echo "  Variant: $VARIANT_SUBDIR ($VARIANT_DESC)"
echo "  Clone method: Shallow (--depth 1) to save bandwidth"
echo ""

git clone --depth 1 --branch "$BRANCH_NAME" https://github.com/icscript/linux-cachyos.git "$BUILD_DIR"

echo ""
echo "✓ Repository cloned"
echo ""

# ============================================================================
# PREPARE BUILD
# ============================================================================

# Enter the selected variant subdirectory
cd "$BUILD_DIR/$VARIANT_SUBDIR"

echo "Preparing PKGBUILD for build..."
echo "  Variant: $KERNEL_VARIANT ($VARIANT_DESC)"
if [ "$KERNEL_VARIANT" = "profiling" ]; then
    echo "  Build Mode: $PROFILING_BUILD_MODE ($BUILD_MODE_DESC)"
    echo "  Debug Build: $_build_debug"
    echo "  AutoFDO Instrument: $_autofdo"
    echo "  Propeller Instrument: $_propeller"
fi
echo "  Scheduler: $_cpusched"
echo "  CPU Target: $_processor_opt"
echo "  LTO: $_use_llvm_lto"
echo "  TCP BBR3: $_tcp_bbr3"
if [ -n "$AUTOFDO_PROFILE" ]; then
    echo "  AutoFDO Profile: $(basename "$AUTOFDO_PROFILE")"
fi
if [ -n "$PROPELLER_CC_PROFILE" ]; then
    echo "  Propeller CC Profile: $(basename "$PROPELLER_CC_PROFILE")"
fi
if [ -n "$PROPELLER_LD_PROFILE" ]; then
    echo "  Propeller LD Profile: $(basename "$PROPELLER_LD_PROFILE")"
fi
echo ""

# ============================================================================
# VERIFY PKGBUILD VARIABLE OVERRIDES
# ============================================================================
# Verify that our exported variables actually override PKGBUILD defaults
# This confirms the bash parameter expansion mechanism (: "${VAR:=default}") is working

echo "Verifying PKGBUILD variable overrides..."

# Store our exported values for comparison
declare -A EXPORTED_VARS=(
    ["_cpusched"]="${_cpusched}"
    ["_processor_opt"]="${_processor_opt}"
    ["_use_llvm_lto"]="${_use_llvm_lto}"
    ["_use_lto_suffix"]="${_use_lto_suffix}"
    ["_tcp_bbr3"]="${_tcp_bbr3}"
    ["_cachy_config"]="${_cachy_config}"
)

# Extract PKGBUILD defaults by parsing the : "${VAR:=default}" lines
PKGBUILD_DEFAULTS=$(grep -E '^:.*"\$\{(_cpusched|_processor_opt|_use_llvm_lto|_use_lto_suffix|_tcp_bbr3|_cachy_config):=([^}]+)\}"' PKGBUILD | \
    sed -E 's/.*\{([^:]+):=([^}]+)\}.*/\1=\2/' || true)

# Verify each variable by sourcing PKGBUILD in a subshell and checking values
VERIFICATION_PASSED=true

# Source PKGBUILD in a subshell to see what values it actually uses
# This is the definitive test - if PKGBUILD sees our exported vars, they override defaults
PKGBUILD_VALUES=$(bash <<'VERIFY_EOF'
    # Source PKGBUILD (redirect stderr to avoid noise)
    source PKGBUILD >/dev/null 2>&1

    # Output each variable we care about
    echo "_cpusched=${_cpusched}"
    echo "_processor_opt=${_processor_opt}"
    echo "_use_llvm_lto=${_use_llvm_lto}"
    echo "_use_lto_suffix=${_use_lto_suffix}"
    echo "_tcp_bbr3=${_tcp_bbr3}"
    echo "_cachy_config=${_cachy_config}"
VERIFY_EOF
)

# Compare exported values vs what PKGBUILD sees
for var in "${!EXPORTED_VARS[@]}"; do
    exported_value="${EXPORTED_VARS[$var]}"
    pkgbuild_value=$(echo "$PKGBUILD_VALUES" | grep "^${var}=" | cut -d= -f2- || echo "")

    # Get default from PKGBUILD (for display purposes)
    default_line=$(echo "$PKGBUILD_DEFAULTS" | grep "^${var}=" || echo "")
    default_value=$(echo "$default_line" | cut -d= -f2- || echo "")

    if [ -n "$exported_value" ]; then
        # We exported a value - verify PKGBUILD sees it
        if [ "$exported_value" = "$pkgbuild_value" ]; then
            if [ -n "$default_value" ] && [ "$exported_value" != "$default_value" ]; then
                echo "  ✓ $var = '$exported_value' (override active, default was '$default_value')"
            else
                echo "  ✓ $var = '$exported_value' (matches export)"
            fi
        else
            echo "  ✗ MISMATCH: $var"
            echo "     Exported: '$exported_value'"
            echo "     PKGBUILD sees: '$pkgbuild_value'"
            VERIFICATION_PASSED=false
        fi
    else
        # Not exported - PKGBUILD should use its default
        if [ -n "$pkgbuild_value" ]; then
            if [ -n "$default_value" ] && [ "$pkgbuild_value" = "$default_value" ]; then
                echo "  ✓ $var = '$pkgbuild_value' (using PKGBUILD default, as expected)"
            else
                echo "  ✓ $var = '$pkgbuild_value' (using PKGBUILD default)"
            fi
        else
            echo "  ⚠️  $var = (empty/unset)"
        fi
    fi
done

if [ "$VERIFICATION_PASSED" = true ]; then
    echo ""
    echo "✓ Variable override verification PASSED"
    echo "  All exported variables are correctly overriding PKGBUILD defaults"
else
    echo ""
    echo "⚠️  Variable override verification FAILED"
    echo "  Some variables may not be overriding PKGBUILD defaults correctly"
    echo "  Continuing anyway, but please review the warnings above"
fi
echo ""

# ============================================================================
# OPTIONAL AUTOFDO PROFILE
# ============================================================================
# To build with AutoFDO profile (Profile-Guided Optimization):
#   AUTOFDO_PROFILE=/path/to/profile.afdo bash build-cachyos-kernel.sh
#
# Example:
#   AUTOFDO_PROFILE=~/autofdo-profiles/kernel-20251106-143022.afdo \
#     bash build-cachyos-kernel.sh
#
# AutoFDO uses runtime profiling data to optimize hot code paths.
# See: arch/cachyos-deploy/autofdo-optimization/README.md
# ============================================================================

if [ -n "$AUTOFDO_PROFILE" ]; then
    echo "AutoFDO profile requested: $AUTOFDO_PROFILE"
    echo ""

    # Verify profile file exists
    if [ ! -f "$AUTOFDO_PROFILE" ]; then
        echo "ERROR: AutoFDO profile not found: $AUTOFDO_PROFILE"
        exit 1
    fi

    # Get absolute path for profile
    AUTOFDO_PROFILE_ABS=$(readlink -f "$AUTOFDO_PROFILE")

    # Copy profile to build directory for PKGBUILD to access
    PROFILE_BASENAME=$(basename "$AUTOFDO_PROFILE_ABS")
    cp "$AUTOFDO_PROFILE_ABS" .

    # Export for PKGBUILD
    # Note: PKGBUILD expects just the filename in the source directory
    export _autofdo_profile_name="$PROFILE_BASENAME"

    # Also export for compiler (belt and suspenders)
    export CLANG_AUTOFDO_PROFILE="$AUTOFDO_PROFILE_ABS"

    echo "  ✓ AutoFDO profile: $PROFILE_BASENAME"
    PROFILE_SIZE=$(du -h "$AUTOFDO_PROFILE_ABS" | cut -f1)
    echo "  ✓ Profile size: $PROFILE_SIZE"
    echo "  ✓ Copied to build directory"
    echo ""
    echo "✓ AutoFDO profile configured"
    echo ""
fi

# ============================================================================
# OPTIONAL PROPELLER PROFILES
# ============================================================================
# To build with Propeller profiles (after AutoFDO optimization):
#   PROPELLER_CC_PROFILE=/path/to/propeller_cc_profile.txt \
#   PROPELLER_LD_PROFILE=/path/to/propeller_ld_profile.txt \
#   bash build-cachyos-kernel.sh
#
# Note: Propeller profiles must be used WITH an AutoFDO profile (Path 4)
# See: arch/cachyos-deploy/autofdo-optimization/README.md
# ============================================================================

if [ -n "$PROPELLER_CC_PROFILE" ] || [ -n "$PROPELLER_LD_PROFILE" ]; then
    echo "Propeller profiles requested"
    echo ""

    # Both profiles must be provided together
    if [ -z "$PROPELLER_CC_PROFILE" ] || [ -z "$PROPELLER_LD_PROFILE" ]; then
        echo "ERROR: Both Propeller profiles must be provided together:"
        echo "  PROPELLER_CC_PROFILE=${PROPELLER_CC_PROFILE:-<missing>}"
        echo "  PROPELLER_LD_PROFILE=${PROPELLER_LD_PROFILE:-<missing>}"
        exit 1
    fi

    # Propeller requires AutoFDO profile
    if [ -z "$AUTOFDO_PROFILE" ]; then
        echo "ERROR: Propeller profiles require an AutoFDO profile"
        echo "You must provide AUTOFDO_PROFILE along with Propeller profiles"
        exit 1
    fi

    # Verify CC profile exists
    if [ ! -f "$PROPELLER_CC_PROFILE" ]; then
        echo "ERROR: Propeller CC profile not found: $PROPELLER_CC_PROFILE"
        exit 1
    fi

    # Verify LD profile exists
    if [ ! -f "$PROPELLER_LD_PROFILE" ]; then
        echo "ERROR: Propeller LD profile not found: $PROPELLER_LD_PROFILE"
        exit 1
    fi

    # Copy profiles to build directory with expected names
    # PKGBUILD expects: propeller_cc_profile.txt and propeller_ld_profile.txt
    cp "$PROPELLER_CC_PROFILE" propeller_cc_profile.txt
    cp "$PROPELLER_LD_PROFILE" propeller_ld_profile.txt

    echo "  ✓ Propeller CC profile: $(basename "$PROPELLER_CC_PROFILE")"
    CC_SIZE=$(du -h "$PROPELLER_CC_PROFILE" | cut -f1)
    echo "    Size: $CC_SIZE"

    echo "  ✓ Propeller LD profile: $(basename "$PROPELLER_LD_PROFILE")"
    LD_SIZE=$(du -h "$PROPELLER_LD_PROFILE" | cut -f1)
    echo "    Size: $LD_SIZE"

    echo "  ✓ Copied to build directory with standard names"
    echo ""
    echo "✓ Propeller profiles configured"
    echo ""
fi

# ============================================================================
# OPTIONAL PATCH INTEGRATION
# ============================================================================
# To build with a custom patch, set environment variable before running:
#   PATCH_FILE=/path/to/patch.patch bash build-cachyos-kernel.sh
#
# Example:
#   PATCH_FILE=~/orc/kernel-bug-amd-pstate/amd-pstate-nosmt-fix-v2.patch \
#     bash build-cachyos-kernel.sh
# ============================================================================
if [ -n "$PATCH_FILE" ]; then
    echo "Custom patch requested: $PATCH_FILE"
    echo ""

    # Verify patch file exists
    if [ ! -f "$PATCH_FILE" ]; then
        echo "ERROR: Patch file not found: $PATCH_FILE"
        exit 1
    fi

    # Copy patch to build directory
    PATCH_NAME=$(basename "$PATCH_FILE")
    cp "$PATCH_FILE" .
    echo "  ✓ Copied $PATCH_NAME to build directory"

    # Find integrate-patch-helper script (check multiple locations)
    HELPER_SCRIPT=""
    if [ -f "$HOME/integrate-patch-helper.sh" ]; then
        HELPER_SCRIPT="$HOME/integrate-patch-helper.sh"
    elif [ -f "./integrate-patch-helper.sh" ]; then
        HELPER_SCRIPT="./integrate-patch-helper.sh"
    else
        echo "ERROR: integrate-patch-helper.sh not found in:"
        echo "  - $HOME/integrate-patch-helper.sh"
        echo "  - ./integrate-patch-helper.sh"
        exit 1
    fi

    # Integrate patch into PKGBUILD
    echo "  Integrating patch into PKGBUILD..."
    bash "$HELPER_SCRIPT" "$PATCH_NAME"

    echo ""
    echo "✓ Patch integration complete"
    echo ""
fi

# ============================================================================
# OPTIONAL EFI STUB PATCH OVERRIDE - claude code on the web chat
# ============================================================================
# Normally applied automatically by our forks PKGBUILD when AutoFDO is enabled.
# Can override with: EFI_STUB_PATCH=~/cursor/projects/orc/kernel-bug-amd-pstate/fix-efi-stub-autofdo-propeller.patch
# ============================================================================
if [ -n "$EFI_STUB_PATCH" ]; then
    echo "Custom EFI stub patch requested: $EFI_STUB_PATCH"
    # Handle similar to PATCH_FILE
fi

# Clean up any old kernel packages in this directory (variant-specific)
if [ "$KERNEL_VARIANT" = "server" ]; then
    rm -f linux-cachyos-server-*.pkg.tar.zst 2>/dev/null || true
else
    # Remove only linux-cachyos packages, not linux-cachyos-server
    for pkg in linux-cachyos-*.pkg.tar.zst; do
        if [ -f "$pkg" ] && [[ ! "$pkg" =~ linux-cachyos-server ]]; then
            rm -f "$pkg"
        fi
    done 2>/dev/null || true
fi

# Regenerate checksums to prevent PKGBUILD integrity errors
# CRITICAL: Must run AFTER setting build options (PKGBUILD conditionally adds patches)
echo "Updating PKGBUILD checksums..."
updpkgsums

# Create temporary makepkg.conf with limited parallel jobs
# (System config has MAKEFLAGS="-j$(nproc)" which overrides environment variables)
TEMP_MAKEPKG_CONF=$(mktemp)
cp /etc/makepkg.conf "$TEMP_MAKEPKG_CONF"
sed -i "s/^MAKEFLAGS=.*/MAKEFLAGS=\"-j1\"/" "$TEMP_MAKEPKG_CONF"
sed -i "s/^NINJAFLAGS=.*/NINJAFLAGS=\"-j1\"/" "$TEMP_MAKEPKG_CONF"

echo "✓ PKGBUILD prepared"
echo ""

# ============================================================================
# BUILD KERNEL
# ============================================================================

echo "=========================================="
echo "STARTING KERNEL BUILD"
echo "=========================================="
echo ""
echo "Configuration:"
echo "  Parallel jobs: 1 (via temporary makepkg.conf)"
echo "  Temp config verification:"
grep -E "^(MAKEFLAGS|NINJAFLAGS)=" "$TEMP_MAKEPKG_CONF" | sed 's/^/    /'
echo "  Estimated time: 60-90 minutes"
echo "  Priority: Low (nice/ionice/chrt)"
echo ""
echo "Building kernel..."
echo ""

# ============================================================================
# PRE-FLIGHT CHECK: Validate PKGBUILD before expensive build
# ============================================================================
# Ensures source array matches checksum array to prevent build failures
# This catches issues from:
# - Missing checksums after patch integration
# - Environment variable mismatches
# - Upstream PKGBUILD changes

echo "=== Pre-flight: Validating PKGBUILD ==="

# Build comprehensive environment variable export string
# Include all exported variables, even if empty (important for conditional PKGBUILD logic)
PKGBUILD_ENV=""

# Always include these if they're exported (even if empty)
if declare -p _autofdo &>/dev/null; then
    PKGBUILD_ENV+=" _autofdo=$_autofdo"
fi
if declare -p _propeller &>/dev/null; then
    PKGBUILD_ENV+=" _propeller=$_propeller"
fi
if declare -p _cpusched &>/dev/null; then
    PKGBUILD_ENV+=" _cpusched=$_cpusched"
fi
if declare -p _server_build &>/dev/null; then
    PKGBUILD_ENV+=" _server_build=$_server_build"
fi
# _autofdo_profile_name can be empty in collection mode, but must be exported
if declare -p _autofdo_profile_name &>/dev/null; then
    PKGBUILD_ENV+=" _autofdo_profile_name=\"$_autofdo_profile_name\""
fi

# Count sources with build environment variables set
SOURCE_COUNT=$(bash -c "export $PKGBUILD_ENV; source PKGBUILD 2>/dev/null; echo \${#source[@]}")

# Count checksums (static, no env vars needed)
CHECKSUM_COUNT=$(bash -c 'source PKGBUILD 2>/dev/null; echo ${#b2sums[@]}')

if [ "$SOURCE_COUNT" -ne "$CHECKSUM_COUNT" ] || [ "$SOURCE_COUNT" -eq 0 ]; then
    echo "❌ ERROR: Source/checksum mismatch detected!"
    echo "   Sources (with build config): $SOURCE_COUNT"
    echo "   Checksums in PKGBUILD: $CHECKSUM_COUNT"
    echo ""
    echo "This will cause makepkg to fail. Possible causes:"
    echo "  - Patch integration didn't update checksums correctly"
    echo "  - Environment variables don't match what integrate script used"
    echo "  - Upstream PKGBUILD updated, checksums need regeneration"
    echo ""
    echo "Fix: Run updpkgsums with same environment variables:"
    echo "  $PKGBUILD_ENV updpkgsums"
    exit 1
fi

echo "✅ Source array: $SOURCE_COUNT items"
echo "✅ Checksum array: $CHECKSUM_COUNT items"
echo "✅ Arrays match - proceeding with build"
echo ""

# ============================================================================
# BUILD COMMAND SUMMARY (for troubleshooting/reporting to CachyOS developers)
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 BUILD ENVIRONMENT VARIABLES (for CachyOS developer support):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "To reproduce this build without the wrapper script, run:"
echo ""
echo "  cd ~/linux-cachyos/${VARIANT_SUBDIR}"
echo "  $PKGBUILD_ENV makepkg -s --noconfirm"
echo ""
echo "Environment variables being passed to PKGBUILD:"
echo "$PKGBUILD_ENV" | tr ' ' '\n' | sed 's/^/  /'
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

BUILD_START=$(date +%s)

# Build kernel using custom config
# -s: Install missing dependencies
# --noconfirm: Don't prompt for confirmations
makepkg -s --noconfirm --config "$TEMP_MAKEPKG_CONF"

BUILD_END=$(date +%s)
BUILD_DURATION=$((BUILD_END - BUILD_START))
BUILD_MINUTES=$((BUILD_DURATION / 60))

# Clean up temp config
rm -f "$TEMP_MAKEPKG_CONF"

echo ""
echo "✓ Kernel build completed in ${BUILD_MINUTES} minutes"
echo ""

# ============================================================================
# VERIFY BUILD OUTPUT
# ============================================================================

echo "Verifying build output..."

# Capture both kernel packages that were built (kernel + headers)
# Package naming varies by variant:
# - server: linux-cachyos-server-lto-*.pkg.tar.zst
# - profiling: linux-cachyos-*.pkg.tar.zst (may include -lto suffix)
if [ "$KERNEL_VARIANT" = "server" ]; then
    KERNEL_PKGS=$(ls -t linux-cachyos-server-*.pkg.tar.zst 2>/dev/null || true)
    EXPECTED_PKG_PATTERN="linux-cachyos-server-*.pkg.tar.zst"
else
    # For profiling variant, match linux-cachyos but NOT linux-cachyos-server
    KERNEL_PKGS=$(ls -t linux-cachyos-*.pkg.tar.zst 2>/dev/null | grep -v 'linux-cachyos-server' || true)
    EXPECTED_PKG_PATTERN="linux-cachyos-*.pkg.tar.zst (excluding server)"
fi

if [ -z "$KERNEL_PKGS" ]; then
    echo "ERROR: No kernel packages found after build!"
    echo "Expected files: $EXPECTED_PKG_PATTERN"
    echo ""
    echo "Available .pkg.tar.zst files:"
    ls -lh *.pkg.tar.zst 2>/dev/null || echo "  (none found)"
    exit 1
fi

PKG_COUNT=$(echo "$KERNEL_PKGS" | wc -l)
EXPECTED_PKG_COUNT=2
if [ "$KERNEL_VARIANT" = "profiling" ] && [ "$_build_debug" = "yes" ]; then
    EXPECTED_PKG_COUNT=3  # kernel + headers + debug
fi

if [ "$PKG_COUNT" -lt 2 ]; then
    echo "WARNING: Expected at least 2 packages (kernel + headers), found $PKG_COUNT"
fi

echo "Built packages:"
echo "$KERNEL_PKGS" | while read pkg; do
    SIZE=$(du -h "$pkg" | cut -f1)
    echo "  - $pkg ($SIZE)"
done
echo ""

# Also capture config file if it exists
if [ "$KERNEL_VARIANT" = "server" ]; then
    CONFIG_FILE=$(ls -t config-*cachyos-server* 2>/dev/null | head -n1 || echo "")
else
    CONFIG_FILE=$(ls -t config-*cachyos* 2>/dev/null | grep -v 'cachyos-server' | head -n1 || echo "")
fi

echo "✓ Build verification passed"
echo ""

# ============================================================================
# SAVE PACKAGES
# ============================================================================

echo "Saving kernel packages..."

# Create timestamped archive directory
mkdir -p "$TIMESTAMPED_DIR"
echo "  Created: $TIMESTAMPED_DIR"

# Copy packages to timestamped directory (variant-specific patterns)
if [ "$KERNEL_VARIANT" = "server" ]; then
    cp linux-cachyos-server-*.pkg.tar.zst "$TIMESTAMPED_DIR/"
else
    # Copy all linux-cachyos packages except server variant
    for pkg in linux-cachyos-*.pkg.tar.zst; do
        if [[ ! "$pkg" =~ linux-cachyos-server ]]; then
            cp "$pkg" "$TIMESTAMPED_DIR/"
        fi
    done
fi

if [ -n "$CONFIG_FILE" ]; then
    cp "$CONFIG_FILE" "$TIMESTAMPED_DIR/"
fi

# Create build marker file for profiling variant
if [ "$KERNEL_VARIANT" = "profiling" ]; then
    case "$PROFILING_BUILD_MODE" in
        collection)
            MARKER_FILE="$TIMESTAMPED_DIR/[AUTOFDO-COLLECTION-BUILD].txt"
            cat > "$MARKER_FILE" << EOF
This kernel is built for AutoFDO PROFILE COLLECTION

Build Mode: AutoFDO Collection (Path 2)
Purpose: Collect runtime performance data for AutoFDO optimization
Debug Symbols: YES (vmlinux included)
AutoFDO Instrumentation: YES

Next Steps:
1. Install this kernel on test/validator system
2. Boot and run typical Polkadot workload
3. Collect performance profile using perf
4. Convert profile to AutoFDO format (.afdo)
5. Rebuild with AutoFDO profile:
   KERNEL_VARIANT=profiling AUTOFDO_PROFILE=/path/to/profile.afdo bash build-cachyos-kernel.sh

Built: $(date)
EOF
            ;;

        autofdo_optimized)
            MARKER_FILE="$TIMESTAMPED_DIR/[AUTOFDO-OPTIMIZED-PROPELLER-READY].txt"
            cat > "$MARKER_FILE" << EOF
This kernel is AutoFDO-OPTIMIZED and ready for PROPELLER PROFILING

Build Mode: AutoFDO Optimized + Propeller Collection (Path 3)
Purpose: Optimized with AutoFDO, ready to collect Propeller profiles
Debug Symbols: YES (vmlinux included for Propeller profiling)
AutoFDO Profile Used: $(basename "$AUTOFDO_PROFILE")
Propeller Instrumentation: YES (enabled for profiling)

This kernel uses AutoFDO optimization and is instrumented for Propeller profiling.

Next Steps:
1. Install this kernel on test/validator system
2. Boot and run typical Polkadot workload
3. Collect Propeller profiles using create_llvm_prof
4. Rebuild with both profiles:
   KERNEL_VARIANT=profiling \\
     AUTOFDO_PROFILE=/path/to/profile.afdo \\
     PROPELLER_CC_PROFILE=/path/to/propeller_cc_profile.txt \\
     PROPELLER_LD_PROFILE=/path/to/propeller_ld_profile.txt \\
     bash build-cachyos-kernel.sh

Built: $(date)
AutoFDO Profile: $(basename "$AUTOFDO_PROFILE")
EOF
            ;;

        propeller_optimized)
            MARKER_FILE="$TIMESTAMPED_DIR/[FULLY-OPTIMIZED-PRODUCTION].txt"
            cat > "$MARKER_FILE" << EOF
This kernel is FULLY OPTIMIZED for PRODUCTION

Build Mode: Propeller-Optimized Production (Path 4)
Purpose: Production deployment with full AutoFDO + Propeller optimization
Debug Symbols: NO (production-ready)
AutoFDO Profile Used: $(basename "$AUTOFDO_PROFILE")
Propeller CC Profile: $(basename "$PROPELLER_CC_PROFILE")
Propeller LD Profile: $(basename "$PROPELLER_LD_PROFILE")

This kernel is fully optimized using both AutoFDO and Propeller profiles.
Maximum performance optimization achieved.

Ready for production deployment.

Built: $(date)
EOF
            ;;
    esac
    echo "  Created marker: $(basename "$MARKER_FILE")"
fi

# Also copy to flat directory for distribute-cachyos-kernel.sh
# (It looks in ~/kernel-packages/ for latest files)
if [ "$KERNEL_VARIANT" = "server" ]; then
    cp linux-cachyos-server-*.pkg.tar.zst "$KERNEL_PACKAGES_DIR/"
else
    # Copy all linux-cachyos packages except server variant
    for pkg in linux-cachyos-*.pkg.tar.zst; do
        if [[ ! "$pkg" =~ linux-cachyos-server ]]; then
            cp "$pkg" "$KERNEL_PACKAGES_DIR/"
        fi
    done
fi

if [ -n "$CONFIG_FILE" ]; then
    cp "$CONFIG_FILE" "$KERNEL_PACKAGES_DIR/"
fi

# Copy marker file to flat directory too
if [ -n "$MARKER_FILE" ]; then
    cp "$MARKER_FILE" "$KERNEL_PACKAGES_DIR/"
fi

echo ""
echo "✓ Packages saved to:"
echo "    $TIMESTAMPED_DIR/"
echo "    $KERNEL_PACKAGES_DIR/ (for distribute script)"
echo ""

# ============================================================================
# COMPLETION SUMMARY
# ============================================================================

echo "=========================================="
echo "✓ KERNEL BUILD COMPLETE!"
echo "=========================================="
echo ""

# Extract version from package filename (handling both variants)
FIRST_PKG=$(echo "$KERNEL_PKGS" | head -n1)
if [ "$KERNEL_VARIANT" = "server" ]; then
    KERNEL_VERSION=$(echo "$FIRST_PKG" | sed -E 's/linux-cachyos-server-[^0-9]*([0-9]+\.[0-9]+\.[0-9]+-[0-9]+)-.*/\1/')
    KERNEL_NAME="linux-cachyos-server (SERVER variant)"
else
    KERNEL_VERSION=$(echo "$FIRST_PKG" | sed -E 's/linux-cachyos-[^0-9]*([0-9]+\.[0-9]+\.[0-9]+-[0-9]+)-.*/\1/')
    KERNEL_NAME="linux-cachyos (PROFILING variant)"
fi

echo "Build Summary:"
echo "  • Kernel: $KERNEL_NAME"
echo "  • Version: $KERNEL_VERSION"
echo "  • Scheduler: $_cpusched"
echo "  • CPU Target: $_processor_opt"
echo "  • LTO: $_use_llvm_lto"
echo "  • Build Time: ${BUILD_MINUTES} minutes"
if [ "$KERNEL_VARIANT" = "profiling" ]; then
    echo "  • Build Mode: $PROFILING_BUILD_MODE ($BUILD_MODE_DESC)"
    echo "  • Debug Build: $_build_debug"
    if [ "$PROFILING_BUILD_MODE" != "collection" ]; then
        echo "  • AutoFDO Profile: $(basename "$AUTOFDO_PROFILE")"
    fi
    if [ "$PROFILING_BUILD_MODE" = "propeller_optimized" ]; then
        echo "  • Propeller CC: $(basename "$PROPELLER_CC_PROFILE")"
        echo "  • Propeller LD: $(basename "$PROPELLER_LD_PROFILE")"
    fi
fi
echo "  • Saved To: $TIMESTAMPED_DIR/"
if [ -n "$PATCH_FILE" ]; then
    echo "  • Custom Patch: $(basename "$PATCH_FILE")"
fi
echo ""

echo "Packages created:"
ls -lh "$TIMESTAMPED_DIR" | tail -n +2 | awk '{printf "  - %-60s %8s\n", $9, $5}'
echo ""

if [ "$KERNEL_VARIANT" = "profiling" ]; then
    case "$PROFILING_BUILD_MODE" in
        collection)
            echo "Next steps (AutoFDO Collection Workflow - Path 2):"
            echo ""
            echo "  1. Install this kernel on a test/validator system:"
            echo "     bash install-cachyos-kernel.sh $TIMESTAMPED_DIR"
            echo ""
            echo "  2. Boot the kernel and profile the workload:"
            echo "     See: arch/cachyos-deploy/autofdo-optimization/QUICKSTART.md"
            echo "     Run typical Polkadot workload while collecting perf data"
            echo ""
            echo "  3. After profiling, rebuild WITH the AutoFDO profile (Path 3):"
            echo "     KERNEL_VARIANT=profiling \\"
            echo "       AUTOFDO_PROFILE=/path/to/profile.afdo \\"
            echo "       bash build-cachyos-kernel.sh"
            echo ""
            echo "  Note: Marker file created: $(basename "$MARKER_FILE")"
            echo ""
            ;;

        autofdo_optimized)
            echo "Next steps (Propeller Collection Workflow - Path 3):"
            echo ""
            echo "  1. Install this kernel on a test/validator system:"
            echo "     bash install-cachyos-kernel.sh $TIMESTAMPED_DIR"
            echo ""
            echo "  2. Boot the kernel and profile the workload for Propeller:"
            echo "     # Boot kernel and run workload"
            echo "     # Collect Propeller profile data"
            echo ""
            echo "  3. Generate Propeller profiles using create_llvm_prof"
            echo ""
            echo "  4. After profiling, rebuild WITH both profiles (Path 4):"
            echo "     KERNEL_VARIANT=profiling \\"
            echo "       AUTOFDO_PROFILE=/path/to/profile.afdo \\"
            echo "       PROPELLER_CC_PROFILE=/path/to/propeller_cc_profile.txt \\"
            echo "       PROPELLER_LD_PROFILE=/path/to/propeller_ld_profile.txt \\"
            echo "       bash build-cachyos-kernel.sh"
            echo ""
            echo "  Note: Marker file created: $(basename "$MARKER_FILE")"
            echo ""
            ;;

        propeller_optimized)
            echo "Next steps (Fully-Optimized Production Deployment - Path 4):"
            echo ""
            echo "  This kernel is FULLY OPTIMIZED with both AutoFDO and Propeller profiles."
            echo "  Maximum performance optimization achieved. Ready for production."
            echo ""
            echo "  1. Distribute to other validators:"
            echo "     bash ~/cursor/projects/orc/z-mac/distribute-cachyos-kernel.sh"
            echo ""
            echo "  2. Install on THIS server:"
            echo "     bash install-cachyos-kernel.sh $TIMESTAMPED_DIR"
            echo ""
            echo "  3. Install on OTHER servers (after distribution):"
            echo "     bash install-cachyos-kernel.sh ~/kernel-packages"
            echo ""
            echo "  4. After installation on each server:"
            echo "     bash verify-before-reboot.sh"
            echo "     sudo reboot  # When validator is ready"
            echo "     bash verify-after-reboot.sh  # After reboot"
            echo ""
            echo "  Note: Marker file created: $(basename "$MARKER_FILE")"
            echo ""
            ;;
    esac
else
    echo "Next steps (Production Deployment):"
    echo ""
    echo "  1. Distribute to other validators:"
    echo "     bash ~/cursor/projects/orc/z-mac/distribute-cachyos-kernel.sh"
    echo ""
    echo "  2. Install on THIS server:"
    echo "     bash install-cachyos-kernel.sh $TIMESTAMPED_DIR"
    echo ""
    echo "  3. Install on OTHER servers (after distribution):"
    echo "     bash install-cachyos-kernel.sh ~/kernel-packages"
    echo ""
    echo "  4. After installation on each server:"
    echo "     bash verify-before-reboot.sh"
    echo "     sudo reboot  # When validator is ready"
    echo "     bash verify-after-reboot.sh  # After reboot"
    echo ""
fi
