#!/bin/bash
# Original script by TIMISONG-dev
#
# Usage: ./build.sh [clean] [-c|--config]
#
#   clean          wipe out/ before building
#   -c, --config   ask for the build settings again
#
# Build settings (user, host, device) are asked on the first run and
# saved to .build.conf (git-ignored); later runs read them from there.
#
# Environment overrides:
#   DEVICE=munch          device fragment, overrides .build.conf for this run
#   USE_NEUTRON=1         use Neutron clang instead of the system clang
#   JOBS=8                parallel jobs (default: nproc)
#   VERBOSE=1             verbose kbuild output

set -euo pipefail

JOBS=${JOBS:-$(nproc)}
VERBOSE=${VERBOSE:-0}
USE_NEUTRON=${USE_NEUTRON:-0}

KERNEL_PATH=$(cd "$(dirname "$0")" && pwd)
OUT_DIR="$KERNEL_PATH/out"
BOOT_DIR="$OUT_DIR/arch/arm64/boot"
DTS_DIR="$BOOT_DIR/dts/vendor/qcom"
LOG="$KERNEL_PATH/build.log"

PERF_DIR="$HOME/perf"
ANYKERNEL_REPO=https://github.com/olzhas0986/Anykernel3.git

NEUTRON_DIR="$HOME/toolchains/neutron-clang"
NEUTRON_URL=https://github.com/Neutron-Toolchains/clang-build-catalogue/releases/download/06092026/neutron-clang-06092026.tar.zst

CONF="$KERNEL_PATH/.build.conf"
cd "$KERNEL_PATH"

msg() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m==> error:\033[0m %s\n' "$*" >&2; exit 1; }

CLEAN=0
RECONFIG=0
for arg in "$@"; do
    case "$arg" in
        clean) CLEAN=1 ;;
        -c|--config) RECONFIG=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) err "unknown argument: $arg (see --help)" ;;
    esac
done

# Ask for a value, offering the current one as the default
ask() {
    local var=$1 prompt=$2 cur=$3 val
    read -r -p "$prompt [$cur]: " val
    printf -v "$var" '%s' "${val:-$cur}"
}

# Defaults, overridden by .build.conf
BUILD_USER=$(id -un)
BUILD_HOST=$(uname -n)
BUILD_DEVICE=munch
[ -f "$CONF" ] && . "$CONF"

if [ ! -f "$CONF" ] || [ "$RECONFIG" = 1 ]; then
    [ -t 0 ] || err "no $CONF and no terminal to ask; run ./build.sh -c interactively"
    msg "Build settings (Enter keeps the value in brackets)"
    ask BUILD_USER   "Build user (KBUILD_BUILD_USER)" "$BUILD_USER"
    ask BUILD_HOST   "Build host (KBUILD_BUILD_HOST)" "$BUILD_HOST"
    ask BUILD_DEVICE "Device"                         "$BUILD_DEVICE"
    [ -f "arch/arm64/configs/vendor/xiaomi/$BUILD_DEVICE.config" ] ||
        msg "warning: arch/arm64/configs/vendor/xiaomi/$BUILD_DEVICE.config does not exist"
    printf 'BUILD_USER=%q\nBUILD_HOST=%q\nBUILD_DEVICE=%q\n' \
        "$BUILD_USER" "$BUILD_HOST" "$BUILD_DEVICE" > "$CONF"
    msg "Saved to $CONF"
fi

# The DEVICE environment variable still wins for one-off builds
DEVICE=${DEVICE:-$BUILD_DEVICE}
export KBUILD_BUILD_USER="$BUILD_USER"
export KBUILD_BUILD_HOST="$BUILD_HOST"
export ARCH=arm64

start_time=$(date +%s)

# Toolchain
if [ "$USE_NEUTRON" = 1 ]; then
    if [ ! -x "$NEUTRON_DIR/bin/clang" ]; then
        msg "Downloading Neutron clang to $NEUTRON_DIR"
        command -v zstd >/dev/null || err "zstd is required to unpack Neutron clang"
        mkdir -p "$NEUTRON_DIR"
        curl -fL "$NEUTRON_URL" | tar --zstd -x -C "$NEUTRON_DIR"
    fi
    export PATH="$NEUTRON_DIR/bin:$PATH"
fi

# Dependencies. Cross binutils are not needed: LLVM=1 LLVM_IAS=1 uses clang/lld only.
. /etc/os-release 2>/dev/null || true
case " ${ID:-} ${ID_LIKE:-} " in
    *" arch "*)            PKGS="base-devel bc python clang lld llvm openssl git p7zip ccache" ;;
    *" debian "*|*" ubuntu "*) PKGS="build-essential bc bison flex libssl-dev python3 clang lld llvm git p7zip-full ccache" ;;
    *" fedora "*|*" rhel "*)   PKGS="make gcc bc bison flex openssl-devel python3 clang lld llvm git p7zip p7zip-plugins ccache" ;;
    *" suse "*|*" opensuse "*) PKGS="make bc bison flex libopenssl-devel python3 clang lld llvm git 7zip ccache" ;;
    *)                     PKGS="make bc bison flex perl python3 clang lld llvm openssl-headers git zip" ;;
esac

missing=()
for t in make bc bison flex perl python3 git clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-strip; do
    command -v "$t" >/dev/null || missing+=("$t")
done
if command -v clang >/dev/null &&
   ! printf '#include <openssl/bio.h>\n' | clang -E -x c - >/dev/null 2>&1; then
    missing+=("OpenSSL headers")
fi
[ ${#missing[@]} -eq 0 ] ||
    err "missing: ${missing[*]}
    install: $PKGS
    (or run with USE_NEUTRON=1 to get clang/lld/llvm from Neutron)"

msg "Using $(clang --version 2>/dev/null | head -n1 || true)"

# Archiver for the flashable zip
if   command -v 7z  >/dev/null; then ZIPPER=(7z a -tzip -mx9)
elif command -v 7za >/dev/null; then ZIPPER=(7za a -tzip -mx9)
elif command -v 7zz >/dev/null; then ZIPPER=(7zz a -tzip -mx9)
elif command -v zip >/dev/null; then ZIPPER=(zip -r9q)
else err "no archiver found, install p7zip or zip"; fi

CC="clang"
command -v ccache >/dev/null && CC="ccache clang"

# KernelSU submodule
if [ -f .gitmodules ] && [ -z "$(ls -A KernelSU 2>/dev/null)" ]; then
    msg "Fetching KernelSU submodule"
    git submodule update --init --recursive
fi

# dtbo.img packer: in-tree copy, then PATH, then AOSP's script cached in ~/.cache
MKDTBO_ARGS=()
MKDTBO_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/mkdtboimg.py"
MKDTBO_URL="https://android.googlesource.com/platform/system/libufdt/+/refs/heads/main/utils/src/mkdtboimg.py?format=TEXT"
if [ -f scripts/mkdtboimg.py ]; then
    MKDTBO_ARGS=(MKDTBO_EXT="python3 $KERNEL_PATH/scripts/mkdtboimg.py")
elif ! command -v mkdtboimg >/dev/null; then
    if [ ! -s "$MKDTBO_CACHE" ]; then
        command -v curl >/dev/null || err "mkdtboimg not found and curl is missing to fetch it"
        msg "Fetching mkdtboimg.py from AOSP"
        mkdir -p "$(dirname "$MKDTBO_CACHE")"
        curl -fsSL "$MKDTBO_URL" | base64 -d > "$MKDTBO_CACHE.tmp" &&
            mv "$MKDTBO_CACHE.tmp" "$MKDTBO_CACHE" ||
            { rm -f "$MKDTBO_CACHE.tmp"; err "could not download mkdtboimg.py"; }
    fi
    MKDTBO_ARGS=(MKDTBO_EXT="python3 $MKDTBO_CACHE")
fi

MAKE=(make -j"$JOBS" O="$OUT_DIR"
      ARCH=arm64 LLVM=1 LLVM_IAS=1
      CC="$CC" HOSTCC="$CC"
      CROSS_COMPILE=aarch64-linux-gnu-
      CROSS_COMPILE_ARM32=arm-linux-gnueabi-
      V="$VERBOSE"
      "${MKDTBO_ARGS[@]}")

if [ "$CLEAN" = 1 ]; then
    msg "Cleaning $OUT_DIR"
    rm -rf "$OUT_DIR"
fi

msg "Configuring for $DEVICE"
"${MAKE[@]}" vendor/kona-perf_defconfig \
             vendor/xiaomi/sm8250-common.config \
             "vendor/xiaomi/$DEVICE.config" \
             vendor/xiaomi/debloat.config

msg "Building (log: $LOG)"
if ! "${MAKE[@]}" 2>&1 | tee "$LOG"; then
    echo
    grep -E "error:|Error [0-9]|undefined (symbol|reference)" "$LOG" | tail -n 20 || true
    err "compilation failed, see $LOG"
fi

for f in "$BOOT_DIR/Image" "$BOOT_DIR/dtbo.img" "$DTS_DIR/kona.dtb"; do
    [ -f "$f" ] || err "$f was not produced"
done

# AnyKernel3
if [ ! -f "$PERF_DIR/anykernel.sh" ]; then
    msg "Cloning AnyKernel3 into $PERF_DIR"
    rm -rf "$PERF_DIR"
    git clone --depth=1 "$ANYKERNEL_REPO" "$PERF_DIR"
fi
rm -rf "$PERF_DIR/.git"
rm -f "$PERF_DIR/Image" "$PERF_DIR/dtb" "$PERF_DIR/dtbo.img"

cp "$BOOT_DIR/Image" "$PERF_DIR/Image"
cp "$BOOT_DIR/dtbo.img" "$PERF_DIR/dtbo.img"
cat "$DTS_DIR/kona.dtb" "$DTS_DIR/kona-v2.dtb" "$DTS_DIR/kona-v2.1.dtb" > "$PERF_DIR/dtb"

KVER=$(cat "$OUT_DIR/include/config/kernel.release" 2>/dev/null || true)
ZIP="Selenite-$DEVICE-$(date '+%Y-%m-%d_%H-%M-%S').zip"

msg "Packing $ZIP"
(cd "$PERF_DIR" && "${ZIPPER[@]}" "$ZIP" $(ls -A | grep -v '\.zip$') >/dev/null)

elapsed=$(( $(date +%s) - start_time ))
msg "Kernel: $KVER"
msg "Zip:    $PERF_DIR/$ZIP"
msg "Done in $((elapsed / 60))m $((elapsed % 60))s"
command -v ccache >/dev/null && ccache -s | grep -E "Hits|Cache size" | head -n 2 || true
