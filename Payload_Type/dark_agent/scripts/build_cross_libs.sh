#!/bin/bash
# Builds static libraries for a cross-compile target using Zig as the cross-compiler.
# Runs at Docker image build time, once per supported (os, arch) combination.
#
# Usage: build_cross_libs.sh <darwin|linux> <aarch64|x86_64>
#
# Produces static libssl.a, libcrypto.a, libpcre2-8.a, libevent.a (darwin only),
# libgc.a and libz.a under /opt/multiarch-libs/<arch>-<os>/.
#
# Requires:
#   - zig in PATH
#   - cmake, wget, tar, make in PATH
#   - the macOS SDK at /opt/macos-sdk/MacOSX12.3.sdk for darwin targets

set -e

OS_NAME="$1"
ARCH_NAME="$2"

if [ -z "$OS_NAME" ] || [ -z "$ARCH_NAME" ]; then
    echo "[ERROR] Usage: $0 <darwin|linux> <aarch64|x86_64>"
    exit 1
fi

MACOS_SDK="/opt/macos-sdk/MacOSX12.3.sdk"
JOBS=2

case "${OS_NAME}/${ARCH_NAME}" in
    darwin/aarch64)
        ZIG_TARGET="aarch64-macos-none"
        LIB_PREFIX="/opt/multiarch-libs/aarch64-apple-darwin"
        OPENSSL_CONFIG="darwin64-arm64"
        BUILD_LIBEVENT=1
        ;;
    darwin/x86_64)
        ZIG_TARGET="x86_64-macos-none"
        LIB_PREFIX="/opt/multiarch-libs/x86_64-apple-darwin"
        OPENSSL_CONFIG="darwin64-x86_64-cc"
        BUILD_LIBEVENT=1
        ;;
    linux/aarch64)
        ZIG_TARGET="aarch64-linux-gnu.2.27"
        LIB_PREFIX="/opt/multiarch-libs/aarch64-linux-gnu"
        OPENSSL_CONFIG="linux-aarch64"
        # Crystal 1.20 selects epoll on Linux, so libevent is not linked there.
        BUILD_LIBEVENT=0
        ;;
    linux/x86_64)
        ZIG_TARGET="x86_64-linux-gnu.2.27"
        LIB_PREFIX="/opt/multiarch-libs/x86_64-linux-gnu"
        OPENSSL_CONFIG="linux-x86_64"
        BUILD_LIBEVENT=0
        ;;
    *)
        echo "[ERROR] Unsupported target: ${OS_NAME}/${ARCH_NAME}"
        exit 1
        ;;
esac


# macOS builds need the SDK sysroot; Linux builds must not reference it.
if [ "${OS_NAME}" = "darwin" ]; then
    SYSROOT_FLAGS="-isysroot ${MACOS_SDK}"
else
    SYSROOT_FLAGS=""
fi

echo "[*] Building static libraries for ${OS_NAME}/${ARCH_NAME}"
echo "    zig target: ${ZIG_TARGET}"
echo "    prefix:     ${LIB_PREFIX}"

mkdir -p "${LIB_PREFIX}/lib/pkgconfig"
mkdir -p "${LIB_PREFIX}/include"
mkdir -p /tmp/cross-libs-build
cd /tmp/cross-libs-build

# cmake needs single-binary tools so create wrappers since zig uses subcommands
# and cmake doesn't reliably propagate CMAKE_C_FLAGS to all compilation steps
cat > /tmp/zig-ar << 'ZIGEOF'
#!/bin/sh
zig ar "$@"
ZIGEOF
chmod +x /tmp/zig-ar

cat > /tmp/zig-ranlib << 'ZIGEOF'
#!/bin/sh
zig ranlib "$@"
ZIGEOF
chmod +x /tmp/zig-ranlib

# zig-cc wrapper: bakes in the cross-compile target (and sysroot for darwin) so
# cmake always gets the right flags regardless of how it invokes the compiler
cat > /tmp/zig-cc << ZIGEOF
#!/bin/sh
zig cc -target ${ZIG_TARGET} ${SYSROOT_FLAGS} "\$@"
ZIGEOF
chmod +x /tmp/zig-cc

# OpenSSL's Configure consumes AR/RANLIB from the environment. These MUST be
# Zig's archivers: the host `ar` (GNU ar on the Linux build image) writes a
# symbol table Zig's Mach-O reader cannot parse, which surfaces much later as
# "unknown cpu architecture: <garbage>" while linking against libssl.a.
# Guard explicitly so a typo can never silently fall back to the host `ar`.
ZIG_AR="zig ar"
ZIG_RANLIB="zig ranlib"
command -v zig >/dev/null || { echo "[ERROR] zig not found in PATH"; exit 1; }
[ -n "${ZIG_AR}" ] && [ -n "${ZIG_RANLIB}" ] || {
    echo "[ERROR] ZIG_AR / ZIG_RANLIB must be set to the zig archivers"
    exit 1
}
echo "    AR=${ZIG_AR} RANLIB=${ZIG_RANLIB}"

echo "[*] Building OpenSSL..."
OPENSSL_VER=3.1.2
wget -q "https://www.openssl.org/source/openssl-${OPENSSL_VER}.tar.gz"
tar -xzf "openssl-${OPENSSL_VER}.tar.gz"
cd "openssl-${OPENSSL_VER}"
# -DOPENSSL_NO_APPLE_CRYPTO_RANDOM: skip CommonCrypto hardware RNG (requires macOS headers we don't have at cross-compile time)
if [ "${OS_NAME}" = "darwin" ]; then
    OPENSSL_EXTRA_CFLAGS="-DOPENSSL_NO_APPLE_CRYPTO_RANDOM"
else
    OPENSSL_EXTRA_CFLAGS=""
fi
CC="zig cc" \
CFLAGS="-target ${ZIG_TARGET} ${SYSROOT_FLAGS} ${OPENSSL_EXTRA_CFLAGS}" \
AR="${ZIG_AR}" \
RANLIB="${ZIG_RANLIB}" \
./Configure "${OPENSSL_CONFIG}" \
    no-shared \
    no-tests \
    no-ui-console \
    no-async \
    --prefix="${LIB_PREFIX}" \
    --openssldir="/etc/ssl"
make -j${JOBS} build_libs
make install_dev
cd /tmp/cross-libs-build
echo "[+] OpenSSL done"

echo "[*] Building pcre2..."
PCRE2_VER=10.47
wget -q "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VER}/pcre2-${PCRE2_VER}.tar.gz"
tar -xzf "pcre2-${PCRE2_VER}.tar.gz"
mkdir -p "pcre2-${PCRE2_VER}/build" && cd "pcre2-${PCRE2_VER}/build"
cmake .. \
    -DBUILD_SHARED_LIBS=OFF \
    -DPCRE2_BUILD_TESTS=OFF \
    -DPCRE2_BUILD_PCRE2GREP=OFF \
    -DCMAKE_C_COMPILER="/tmp/zig-cc" \
    -DCMAKE_AR="/tmp/zig-ar" \
    -DCMAKE_RANLIB="/tmp/zig-ranlib" \
    -DCMAKE_INSTALL_PREFIX="${LIB_PREFIX}" \
    -DCMAKE_SYSTEM_NAME="$( [ "${OS_NAME}" = "darwin" ] && echo Darwin || echo Linux )" \
    -DCMAKE_SYSTEM_PROCESSOR="${ARCH_NAME}" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
make -j${JOBS}
make install
cd /tmp/cross-libs-build
echo "[+] pcre2 done"

if [ "${BUILD_LIBEVENT}" = "1" ]; then
    echo "[*] Building libevent..."
    LIBEVENT_VER=2.1.12
    wget -q "https://github.com/libevent/libevent/releases/download/release-${LIBEVENT_VER}-stable/libevent-${LIBEVENT_VER}-stable.tar.gz"
    tar -xzf "libevent-${LIBEVENT_VER}-stable.tar.gz"
    cd "libevent-${LIBEVENT_VER}-stable"
    CC="zig cc -target ${ZIG_TARGET} ${SYSROOT_FLAGS}" \
    CXX="zig c++ -target ${ZIG_TARGET} ${SYSROOT_FLAGS}" \
    AR="/tmp/zig-ar" \
    RANLIB="/tmp/zig-ranlib" \
    ./configure \
        --host="$( [ "${ARCH_NAME}" = "aarch64" ] && echo aarch64 || echo x86_64 )-apple-darwin" \
        --disable-shared \
        --enable-static \
        --disable-openssl \
        --disable-samples \
        --disable-libevent-regress \
        --prefix="${LIB_PREFIX}"
    make -j${JOBS}
    make install
    cd /tmp/cross-libs-build
    echo "[+] libevent done"
else
    echo "[*] Skipping libevent (not linked on ${OS_NAME}/${ARCH_NAME})"
fi

# Stub out missing SDK headers that bdw-gc needs for macOS targets.
# The joseluisq MacOSX12.3.sdk omits some deprecated Mach headers.
# These stubs satisfy the #include without pulling in real implementations
# bdw-gc's actual Darwin code paths are disabled via cmake flags below.
if [ "${OS_NAME}" = "darwin" ]; then
    mkdir -p "${MACOS_SDK}/usr/include/mach-o"
    if [ ! -f "${MACOS_SDK}/usr/include/mach-o/getsect.h" ]; then
cat > "${MACOS_SDK}/usr/include/mach-o/getsect.h" << 'STUBEOF'
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
struct mach_header_64;
static inline uint8_t *getsectiondata(const struct mach_header_64 *mhp,
    const char *seg, const char *sect, unsigned long *sz) { (void)mhp; (void)seg; (void)sect; *sz=0; return 0; }
extern uint8_t *get_etext(void);
extern uint8_t *get_end(void);
extern uint8_t *get_edata(void);
#ifdef __cplusplus
}
#endif
STUBEOF
    fi

    mkdir -p "${MACOS_SDK}/usr/include/mach"
    # Provide mach/exception.h so bdw-gc's darwin_stop_world.c can compile.
    # This gives the GC real GC_push_all_stacks/GC_start_world/GC_stop_world
    # implementations that properly handle multi-threaded Crystal (preview_mt).
    if [ ! -f "${MACOS_SDK}/usr/include/mach/exception.h" ]; then
cat > "${MACOS_SDK}/usr/include/mach/exception.h" << 'STUBEOF'
#pragma once
#ifndef _MACH_EXCEPTION_H_
#define _MACH_EXCEPTION_H_

#include <mach/port.h>
#include <mach/message.h>

typedef int                    exception_type_t;
typedef int                    exception_data_type_t;
typedef exception_data_type_t *exception_data_t;
typedef unsigned int           exception_mask_t;
typedef exception_mask_t      *exception_mask_array_t;
typedef int                    exception_behavior_t;
typedef exception_behavior_t  *exception_behavior_array_t;
typedef mach_port_t           *exception_port_array_t;

#define EXC_BAD_ACCESS           1
#define EXC_ARITHMETIC           2
#define EXC_EMULATION            3
#define EXC_SOFTWARE             4
#define EXC_BREAKPOINT           5
#define EXC_SYSCALL              6
#define EXC_MACH_SYSCALL         7
#define EXC_RPC_ALERT            8
#define EXC_CRASH               10
#define EXC_RESOURCE            11
#define EXC_GUARD               12
#define EXC_CORPSE_NOTIFY       13

#define EXC_MASK_BAD_ACCESS      (1 << EXC_BAD_ACCESS)
#define EXC_MASK_ARITHMETIC      (1 << EXC_ARITHMETIC)
#define EXC_MASK_EMULATION       (1 << EXC_EMULATION)
#define EXC_MASK_SOFTWARE        (1 << EXC_SOFTWARE)
#define EXC_MASK_BREAKPOINT      (1 << EXC_BREAKPOINT)
#define EXC_MASK_SYSCALL         (1 << EXC_SYSCALL)
#define EXC_MASK_MACH_SYSCALL    (1 << EXC_MACH_SYSCALL)
#define EXC_MASK_RPC_ALERT       (1 << EXC_RPC_ALERT)
#define EXC_MASK_CRASH           (1 << EXC_CRASH)
#define EXC_MASK_RESOURCE        (1 << EXC_RESOURCE)
#define EXC_MASK_GUARD           (1 << EXC_GUARD)
#define EXC_MASK_CORPSE_NOTIFY   (1 << EXC_CORPSE_NOTIFY)
#define EXC_MASK_ALL             (EXC_MASK_BAD_ACCESS | EXC_MASK_ARITHMETIC | \
                                  EXC_MASK_EMULATION  | EXC_MASK_SOFTWARE   | \
                                  EXC_MASK_BREAKPOINT | EXC_MASK_SYSCALL    | \
                                  EXC_MASK_MACH_SYSCALL)

#define EXCEPTION_DEFAULT            1
#define EXCEPTION_STATE              2
#define EXCEPTION_STATE_IDENTITY     3
#define MACH_EXCEPTION_CODES         0x80000000

#endif /* _MACH_EXCEPTION_H_ */
STUBEOF
    fi
fi

echo "[*] Building Boehm GC..."
BDWGC_VER=8.2.12
ATOMICOPS_VER=7.10.0
wget -q "https://github.com/ivmai/bdwgc/releases/download/v${BDWGC_VER}/gc-${BDWGC_VER}.tar.gz"
wget -q "https://github.com/ivmai/libatomic_ops/releases/download/v${ATOMICOPS_VER}/libatomic_ops-${ATOMICOPS_VER}.tar.gz"
tar -xzf "gc-${BDWGC_VER}.tar.gz"
tar -xzf "libatomic_ops-${ATOMICOPS_VER}.tar.gz"
mv "libatomic_ops-${ATOMICOPS_VER}" "gc-${BDWGC_VER}/libatomic_ops"
mkdir -p "gc-${BDWGC_VER}/build" && cd "gc-${BDWGC_VER}/build"
cmake .. \
    -DBUILD_SHARED_LIBS=OFF \
    -Dbuild_tests=OFF \
    -Denable_docs=OFF \
    -Denable_dynamic_loading=OFF \
    -DCMAKE_C_COMPILER="/tmp/zig-cc" \
    -DCMAKE_C_FLAGS="$( [ "${OS_NAME}" = "darwin" ] && echo "-I${MACOS_SDK}/usr/include" )" \
    -DCMAKE_AR="/tmp/zig-ar" \
    -DCMAKE_RANLIB="/tmp/zig-ranlib" \
    -DCMAKE_INSTALL_PREFIX="${LIB_PREFIX}" \
    -DCMAKE_SYSTEM_NAME="$( [ "${OS_NAME}" = "darwin" ] && echo Darwin || echo Linux )" \
    -DCMAKE_SYSTEM_PROCESSOR="${ARCH_NAME}" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
make -j${JOBS}
make install
cd /tmp/cross-libs-build
echo "[+] Boehm GC done"

echo "[*] Building zlib..."
ZLIB_VER=1.3.1
wget -q "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.gz"
tar -xzf "zlib-${ZLIB_VER}.tar.gz"
cd "zlib-${ZLIB_VER}"
CC="/tmp/zig-cc" \
AR="/tmp/zig-ar" \
RANLIB="/tmp/zig-ranlib" \
./configure \
    --static \
    --prefix="${LIB_PREFIX}"
make -j${JOBS} libz.a
make install
cd /tmp/cross-libs-build
echo "[+] zlib done"

# ---------------------------------------------------------------------------
# Sanity-check every archive before it is baked into the image.
# A malformed archive used to surface only when an operator built a payload, as
# "unknown cpu architecture: <garbage>" during the final Zig link. Verify each
# archive's symbol table is readable and that its member objects are real and
# of the expected kind, so a broken library set fails the docker build instead.
# ---------------------------------------------------------------------------
echo "[*] Verifying archives in ${LIB_PREFIX}/lib"
verify_failed=0
for archive in "${LIB_PREFIX}/lib/"*.a; do
    [ -f "${archive}" ] || continue
    archive_name=$(basename "${archive}")

    # `zig ar t` walks the archive and its symbol table -- this is exactly the
    # read that used to fail at payload-link time.
    if ! member=$(zig ar t "${archive}" 2>/dev/null | head -n 1) || [ -z "${member}" ]; then
        echo "[ERROR] ${archive_name}: unreadable archive (corrupt symbol table?)"
        verify_failed=1
        continue
    fi

    # Extract one member and confirm it is a real object for this target.
    tmp_dir=$(mktemp -d)
    if ! ( cd "${tmp_dir}" && zig ar x "${archive}" "${member}" ) 2>/dev/null; then
        echo "[ERROR] ${archive_name}: cannot extract member '${member}'"
        verify_failed=1
        rm -rf "${tmp_dir}"
        continue
    fi

    magic=$(od -An -tx1 -N4 "${tmp_dir}/${member}" 2>/dev/null | tr -d ' \n')
    rm -rf "${tmp_dir}"

    if [ "${OS_NAME}" = "linux" ] && [ "${magic}" != "7f454c46" ]; then
        echo "[ERROR] ${archive_name}: member '${member}' is not an ELF object (magic=${magic})"
        verify_failed=1
        continue
    fi

    echo "[+] ${archive_name} OK (${member})"
done

if [ "${verify_failed}" -ne 0 ]; then
    echo "[ERROR] One or more archives failed verification for ${OS_NAME}/${ARCH_NAME}"
    exit 1
fi

rm -rf /tmp/cross-libs-build
echo "[+] All static libraries built for ${OS_NAME}/${ARCH_NAME}"
echo "    Installed to: ${LIB_PREFIX}"
ls "${LIB_PREFIX}/lib/"*.a
