#!/bin/bash

# Color definitions for logging
log_info() {
    echo -e "\033[0;34m[*] $1\033[0m"  # Blue for info
}

log_error() {
    echo -e "\033[0;31m[ERROR] $1\033[0m"  # Red for errors
}

log_success() {
    echo -e "\033[0;32m[+] $1\033[0m"  # Green for success
}

log_action() {
    echo -e "\033[0;33m[-] $1\033[0m"  # Yellow for actions
}

# =============================================================================
# Target architecture configuration
# =============================================================================
# TARGET_ARCH is set from -A (x64|arm64), defaulting to x64 so that manual
# builds keep their historic behaviour. Everything below derives from it.
#
#   arch      Crystal target (agent)              Zig target (link / BOFs)
#   x64       x86_64-<os>...                      x86_64-...
#   arm64     aarch64-<os>...                     aarch64-...
#
# Note on Crystal vs Zig triples for Linux: Crystal is given the plain
# `aarch64-unknown-linux-gnu` triple so that its stdlib `flag?(:gnu)` checks
# still evaluate true (Crystal's Target#gnu? does not recognise a `gnu.2.27`
# environment suffix). The glibc 2.27 compatibility floor is enforced at link
# time instead, via Zig's `aarch64-linux-gnu.2.27` target.
configure_target() {
    case "$TARGET_ARCH" in
        x64)
            ELF_MACHINE="x86_64"
            BOF_ZIG_ARCH="x86_64"
            BOF_ARCH_DEFINES="-D__x86_64__=1"
            CRYSTAL_LINUX_TARGET="x86_64-unknown-linux-gnu"
            ZIG_LINUX_TARGET="x86_64-linux-gnu.2.27"
            LINUX_LIB_PREFIX="/opt/multiarch-libs/x86_64-linux-gnu"
            MACOS_CRYSTAL_TARGET="x86_64-apple-macosx12.0"
            MACOS_ZIG_TARGET="x86_64-macos-none"
            MACOS_ARCH="x86_64-apple-darwin"
            ;;
        arm64)
            ELF_MACHINE="aarch64"
            BOF_ZIG_ARCH="aarch64"
            BOF_ARCH_DEFINES="-D__aarch64__=1 -D__arm64__=1"
            CRYSTAL_LINUX_TARGET="aarch64-unknown-linux-gnu"
            ZIG_LINUX_TARGET="aarch64-linux-gnu.2.27"
            LINUX_LIB_PREFIX="/opt/multiarch-libs/aarch64-linux-gnu"
            MACOS_CRYSTAL_TARGET="aarch64-apple-macosx12.0"
            MACOS_ZIG_TARGET="aarch64-macos-none"
            MACOS_ARCH="aarch64-apple-darwin"
            ;;
        *)
            log_error "Invalid architecture: ${TARGET_ARCH}. Must be 'x64' or 'arm64'"
            exit 1
            ;;
    esac
    MACOS_PREFIX="/opt/multiarch-libs/${MACOS_ARCH}"
    MACOS_SDK="/opt/macos-sdk/MacOSX12.3.sdk"

    log_info "Target architecture: ${TARGET_ARCH} (BOF machine: ${ELF_MACHINE})"
}

# Create output directories
setup_directories() {
    mkdir -p output
    mkdir -p "output/bofs/linux-${TARGET_ARCH}"
    mkdir -p "output/bofs/macos-${TARGET_ARCH}"
    log_info "Created output directories"
}

# Build C BOF object files for Linux (native gcc for x64, Zig cross for arm64)
build_bofs() {
    local bof_dir="output/bofs/linux-${TARGET_ARCH}"
    log_info "Building BOF object files for Linux ${TARGET_ARCH}..."
    local build_error=0

    if [ "${TARGET_ARCH}" = "x64" ]; then
        bof_cc="gcc -fPIC"
    else
        bof_cc="zig cc -target ${ZIG_LINUX_TARGET} -fPIC ${BOF_ARCH_DEFINES}"
    fi

    # Process substitution (not a pipe) so build_error survives the loop
    while read -r c_file; do
        base_name=$(basename "$c_file")
        output_name="${base_name%.c}.o"
        log_action "Compiling $base_name from $c_file"
        $bof_cc -c "$c_file" -o "${bof_dir}/$output_name" -I src/bofs/includes -w

        if [ $? -eq 0 ]; then
            log_success "Built $output_name"
        else
            log_error "Failed to build $output_name"
            build_error=1
        fi
    done < <(find src/bofs -name "*.c")

    # Exit with error if any BOF failed to build
    if [ $build_error -eq 1 ]; then
        log_error "One or more BOFs failed to build"
        exit 1
    fi
}

# Build C BOF object files for macOS using Zig cross-compiler
# BOFs are ELF relocatable objects loaded by the agent's in-process ELF loader,
# so the target format is linux-none even for macOS -- only the machine matters.
build_bofs_macos() {
    local bof_dir="output/bofs/macos-${TARGET_ARCH}"
    log_info "Building BOF object files for macOS (${TARGET_ARCH})..."
    local build_error=0

    mkdir -p "${bof_dir}"

    while read -r c_file; do
        base_name=$(basename "$c_file")
        output_name="${base_name%.c}.o"
        log_action "Compiling ${base_name} for macOS ${TARGET_ARCH}"
        /opt/zig/zig cc \
            -target "${BOF_ZIG_ARCH}-linux-none" \
            -I "${MACOS_SDK}/usr/include" \
            ${BOF_ARCH_DEFINES} \
            -DTARGET_MACOS=1 \
            -D_FORTIFY_SOURCE=0 \
            -fPIC -c "${c_file}" \
            -o "${bof_dir}/${output_name}" \
            -I src/bofs/includes -w

        if [ $? -eq 0 ]; then
            log_success "Built ${output_name} (macOS ${TARGET_ARCH})"
        else
            log_error "Failed to build ${output_name}"
            build_error=1
        fi
    done < <(find src/bofs -name "*.c")

    if [ $build_error -eq 1 ]; then
        log_error "One or more macOS BOFs failed to build"
        exit 1
    fi
}

# Build Dark Agent natively on the build host (Linux x64 only)
build_agent() {
    local mode="$1"          # debug, release, or socks-debug
    local output_file="$2"   # output filename
    local extra_flags="$3"   # additional crystal build flags
    local description="$4"   # human-readable description

    log_info "Building Dark Agent in $description..."

    # Print Crystal version
    log_info "Crystal version info: "
    crystal --version

    if [ -z "$DARK_AGENT_CONFIG_PATH" ]; then
        log_error "Dark agent config JSON path not provided (DARK_AGENT_CONFIG_PATH environment variable)"
        exit 1
    fi

    log_info "Building for profile type: $PROFILE_TYPE"

    # Build base flags
    local base_flags="src/dark/dark-agent.cr"
    local profile_flags=""
    local debug_socks_flags="${DEBUG_SOCKS:+-D debug_socks}"

    # Add profile-specific flags
    if [ "$PROFILE_TYPE" = "httpx" ]; then
        profile_flags="-D httpx_profile"
    fi

    # Static OpenSSL 3 baked into the binary with no target libssl dependency.
    # --as-needed prevents pkg-config's subsequent dynamic -lssl from adding a NEEDED
    # entry once the symbols are already resolved by the static archive.
    export PKG_CONFIG_PATH="/opt/openssl-3/lib64/pkgconfig"

    # Execute crystal build with combined flags (including multi-threading support)
    echo "$base_flags $profile_flags $debug_socks_flags $extra_flags -Dpreview_mt -o $output_file"
    crystal build $base_flags $profile_flags $debug_socks_flags $extra_flags \
      --link-flags "-Wl,--as-needed -Wl,-Bstatic -L/opt/openssl-3/lib64 -lssl -lcrypto -Wl,-Bdynamic" \
      -Dpreview_mt -o "$output_file"

    if [ $? -eq 0 ]; then
        log_success "Built Dark Agent ($description) for $PROFILE_TYPE profile"
    else
        log_error "Failed to build Dark Agent in $description"
        exit 1
    fi
}

# Build Dark Agent for Linux arm64 via two-phase Crystal cross-compile + Zig link.
# glibc stays dynamic (2.27 floor) while OpenSSL, pcre2, bdwgc and zlib are
# linked statically from the arm64 prefix, matching the x64 build's contract.
build_linux_cross() {
    local extra_flags="$1"   # extra crystal flags (e.g. "--release --no-debug")
    local output_file="$2"
    local description="$3"
    local strip_flag="$4"    # "-s" to strip at link time (host strip cannot touch arm64)
    local OBJ_FILE="${output_file}.o"

    log_info "Building Dark Agent for Linux ${TARGET_ARCH} (${description}) via cross-compile..."

    if [ -z "$DARK_AGENT_CONFIG_PATH" ]; then
        log_error "DARK_AGENT_CONFIG_PATH not set"
        exit 1
    fi

    if [ "$TARGET_ARCH" != "x64" ]; then
        require_cross_libs "${LINUX_LIB_PREFIX}"
    fi

    local profile_flags=""
    if [ "$PROFILE_TYPE" = "httpx" ]; then
        profile_flags="-D httpx_profile"
    fi
    local debug_socks_flags="${DEBUG_SOCKS:+-D debug_socks}"

    log_info "Phase 1: Crystal -> object file (target: ${CRYSTAL_LINUX_TARGET})"
    PKG_CONFIG_LIBDIR="${LINUX_LIB_PREFIX}/lib/pkgconfig" \
    crystal build \
        --cross-compile \
        --target "${CRYSTAL_LINUX_TARGET}" \
        --static \
        -Dpreview_mt \
        ${profile_flags} \
        ${debug_socks_flags} \
        ${extra_flags} \
        -o "${output_file}" \
        src/dark/dark-agent.cr

    if [ $? -ne 0 ]; then
        log_error "Crystal cross-compile failed"
        exit 1
    fi

    log_info "Phase 2: Zig -> ELF executable"

    # Crystal's own link line is not used; Zig supplies the arm64 linker, the
    # glibc 2.27 sysroot/stubs and the target C runtime. Third-party libraries
    # are taken statically from the arm64 prefix. libevent is intentionally
    # absent: Crystal 1.20 uses epoll on Linux unless built with -Devloop=libevent.
    #
    # --export-dynamic is mandatory: the BOF loader resolves libc symbols with
    # dlsym(RTLD_DEFAULT), which only sees symbols exported from the executable.
    /opt/zig/zig cc \
        -target "${ZIG_LINUX_TARGET}" \
        "${OBJ_FILE}" \
        -o "${output_file}" \
        -Wl,--export-dynamic \
        ${strip_flag} \
        -Wl,--as-needed \
        -Wl,-Bstatic -L"${LINUX_LIB_PREFIX}/lib" -lssl -lcrypto -lpcre2-8 -lgc -lz -Wl,-Bdynamic \
        -lpthread -ldl -lm

    if [ $? -ne 0 ]; then
        log_error "Zig link failed"
        exit 1
    fi

    rm -f "${OBJ_FILE}"

    log_success "Built Dark Agent (${description}) for $PROFILE_TYPE profile (Linux ${TARGET_ARCH})"
}

# Verify a cross-compile library set exists and is usable before the agent
# links against it. Guards against a stale or malformed /opt/multiarch-libs set
# producing a cryptic "unknown cpu architecture" error from the zig linker.
require_cross_libs() {
    local prefix="$1"
    local missing=""

    if [ ! -d "${prefix}/lib" ]; then
        log_error "Cross-compile libraries not found at ${prefix}/lib"
        log_error "Rebuild the container: docker build (or mythic-cli build dark_agent)"
        exit 1
    fi

    for lib in libssl.a libcrypto.a libpcre2-8.a libgc.a libz.a; do
        if [ ! -f "${prefix}/lib/${lib}" ]; then
            missing="${missing} ${lib}"
        fi
    done

    if [ -n "${missing}" ]; then
        log_error "Missing static libraries in ${prefix}/lib:${missing}"
        log_error "Rebuild the container: docker build (or mythic-cli build dark_agent)"
        exit 1
    fi

    # A corrupt archive (e.g. built with the host GNU ar instead of zig ar)
    # cannot be parsed by the zig linker. Detect it here with a clear message.
    local bad=""
    for lib in libssl.a libcrypto.a libpcre2-8.a libgc.a libz.a; do
        if ! /opt/zig/zig ar t "${prefix}/lib/${lib}" >/dev/null 2>&1; then
            bad="${bad} ${lib}"
        fi
    done

    if [ -n "${bad}" ]; then
        log_error "Corrupt static libraries in ${prefix}/lib:${bad}"
        log_error "These archives cannot be read by the zig linker, which usually"
        log_error "means they were built with the host 'ar' instead of 'zig ar'."
        log_error "Rebuild the container image to regenerate them."
        exit 1
    fi
}

# Build Dark Agent for macOS (Mach-O binary) via two-phase Crystal cross-compile + Zig link
build_macos() {
    local crystal_flags="$1"   # extra crystal flags (e.g. "-D debug")
    local output_file="$2"
    local description="$3"
    local OBJ_FILE="${output_file}.o"

    log_info "Building Dark Agent for macOS ${TARGET_ARCH} (${description}) via cross-compile..."

    if [ -z "$DARK_AGENT_CONFIG_PATH" ]; then
        log_error "DARK_AGENT_CONFIG_PATH not set"
        exit 1
    fi

    # Fail fast with an actionable message rather than letting Zig emit
    # "unknown cpu architecture: <garbage>" if the library set is missing,
    # stale, or was produced with the wrong archiver.
    require_cross_libs "${MACOS_PREFIX}"

    log_info "Phase 1: Crystal → object file (target: ${MACOS_CRYSTAL_TARGET})"
    PKG_CONFIG_LIBDIR="${MACOS_PREFIX}/lib/pkgconfig" \
    crystal build \
        --cross-compile \
        --target "${MACOS_CRYSTAL_TARGET}" \
        --static \
        -Dpreview_mt \
        -Dgc_none \
        ${crystal_flags} \
        -o "${output_file}" \
        src/dark/dark-agent.cr

    if [ $? -ne 0 ]; then
        log_error "Crystal cross-compile failed"
        exit 1
    fi

    log_info "Phase 2: Zig → Mach-O binary"

    # darwin_stop_world.c requires Mach framework internals we can't cross-compile.
    # These stubs satisfy the linker. GC works cooperatively with Crystal fibers and the conservative collector tolerates the lack of explicit world-stop on macOS.
    cat > /tmp/gc_darwin_stubs.c << 'GCEOF'
void GC_push_all_stacks(void) {}
void GC_darwin_register_mach_handler_thread(void *p) { (void)p; }
void GC_start_world(void) {}
void GC_stop_world(void) {}
GCEOF
    /opt/zig/zig cc -target "${MACOS_ZIG_TARGET}" \
        -c /tmp/gc_darwin_stubs.c \
        -o output/gc_darwin_stubs.o

    /opt/zig/zig cc \
        -target "${MACOS_ZIG_TARGET}" \
        "${OBJ_FILE}" \
        output/gc_darwin_stubs.o \
        -o "${output_file}" \
        -L"${MACOS_PREFIX}/lib" \
        -L"${MACOS_SDK}/usr/lib" \
        -isysroot "${MACOS_SDK}" \
        -lssl -lcrypto \
        -lpcre2-8 \
        -lgc \
        -lz \
        -lpthread \
        -levent \
        -liconv \
        -dead_strip

    if [ $? -ne 0 ]; then
        log_error "Zig link failed"
        exit 1
    fi

    rm -f "${OBJ_FILE}"

    # Zig on ubuntu:18.04 (glibc 2.27) produces Mach-O with incorrect ad-hoc page hashes.
    # rcodesign produces SHA-256 CodeDirectory hashes required by macOS 14+; ldid only emits SHA-1.
    rcodesign sign --adhoc "${output_file}"

    log_success "Built Dark Agent (${description}) for macOS ${TARGET_ARCH}"
}

# --- Target-aware entry points -------------------------------------------------

# Release build for the selected OS/arch
build_release() {
    local output_file="output/dark-agent-linux-${TARGET_ARCH}"
    if [ "${TARGET_ARCH}" = "x64" ]; then
        build_agent "release" "${output_file}" "--release --no-debug" "release mode"
        strip "${output_file}"
        log_success "Stripped release binary ($(du -sh ${output_file} | cut -f1))"
    else
        build_linux_cross "--release --no-debug" "${output_file}" "release mode" "-s"
        log_success "Release binary: $(du -sh ${output_file} | cut -f1)"
    fi
}

# Debug build for the selected Linux arch
build_debug() {
    local output_file="output/dark-agent-linux-${TARGET_ARCH}-debug"
    if [ "${TARGET_ARCH}" = "x64" ]; then
        build_agent "debug" "${output_file}" "" "debug mode"
    else
        build_linux_cross "-D debug" "${output_file}" "debug mode" ""
    fi
}

# SOCKS debug build for the selected Linux arch
build_socks_debug() {
    local output_file="output/dark-agent-linux-${TARGET_ARCH}-socks-debug"
    if [ "${TARGET_ARCH}" = "x64" ]; then
        build_agent "socks-debug" "${output_file}" "-D debug -D debug_socks" "SOCKS debug mode"
    else
        build_linux_cross "-D debug -D debug_socks" "${output_file}" "SOCKS debug mode" ""
    fi
}

build_macos_release() {
    build_macos "--release --no-debug" "output/dark-agent-macos-${TARGET_ARCH}" "release mode"
}

build_macos_debug() {
    build_macos "-D debug" "output/dark-agent-macos-${TARGET_ARCH}-debug" "debug mode"
}

# Build Dark Agent in direct mode (COFF loader only)
build_direct_mode() {
    log_info "Building Dark Agent in direct mode (COFF loader only)..."

    crystal build src/dark/dark-agent-direct.cr --debug -o output/dark-agent-direct -D debugmem -Dpreview_mt

    if [ $? -eq 0 ]; then
        log_success "Built Dark Agent (direct mode)"
    else
        log_error "Failed to build Dark Agent in direct mode"
        exit 1
    fi
}

# Build standalone SOCKS server for testing
build_socks_server() {
    log_info "Building standalone SOCKS server..."

    crystal build src/socks-server.cr -o output/socks-server --release --error-trace -Dpreview_mt

    if [ $? -eq 0 ]; then
        log_success "Built standalone SOCKS server"
    else
        log_error "Failed to build SOCKS server"
        exit 1
    fi
}

# Clean outputs
clean() {
    log_action "Cleaning output directory..."
    rm -f output/dark-agent output/dark-agent-debug output/dark-agent-direct output/dark-agent-direct.ll output/socks-server
    rm -f output/dark-agent-linux-* output/dark-agent-macos-*
    rm -f output/dark-agent-macos*.o output/gc_darwin_stubs.o
    rm -rf output/bofs
    log_success "Cleaned Dark Agent builds and BOF object files"
}

# Display usage
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -a    Build both debug and release versions"
    echo "  -b    Build BOF object files only (linux)"
    echo "  -d    Build debug version only"
    echo "  -r    Build release version only"
    echo "  -c    Clean Dark Agent builds and BOF object files"
    echo "  -D    Build direct mode version"
    echo "  -s    Build standalone SOCKS server"
    echo "  -S    Build Dark Agent with SOCKS debug mode (suppresses HTTP logs)"
    echo "  -p    Specify profile type (http or httpx)"
    echo "  -B    Build BOF object files for macOS"
    echo "  -m    Build macOS Mach-O binary (release)"
    echo "  -M    Build macOS Mach-O binary (debug)"
    echo "  -A    Target architecture: x64 (default) or arm64"
    echo "  -h    Show this help message"
}

# Default profile type is http
PROFILE_TYPE="http"

# Default target architecture
TARGET_ARCH="x64"

# Execute build actions based on provided arguments
execute_build() {
    local action="$1"

    case "$action" in
        "all")
            build_bofs
            build_debug
            build_release
            ;;
        "bofs")
            build_bofs
            ;;
        "bofs-macos")
            build_bofs_macos
            ;;
        "debug")
            build_debug
            ;;
        "release")
            build_release
            ;;
        "direct")
            build_direct_mode
            ;;
        "socks-server")
            build_socks_server
            ;;
        "socks-debug")
            build_socks_debug
            ;;
        "macos")
            build_macos_release
            ;;
        "macos-debug")
            build_macos_debug
            ;;
        "clean")
            clean
            return 0
            ;;
        "help")
            usage
            return 0
            ;;
    esac
}

# Main execution
if [ $# -eq 0 ]; then
    # Default to building both versions and BOFs if no args provided
    configure_target
    setup_directories
    execute_build "all"
    exit 0
fi

while getopts "abdrcDsShjBmMp:x:A:" opt; do
    case $opt in
        a) BUILD_ACTION="all" ;;
        b) BUILD_ACTION="bofs" ;;
        d) BUILD_ACTION="debug" ;;
        r) BUILD_ACTION="release" ;;
        c) BUILD_ACTION="clean" ;;
        D) BUILD_ACTION="direct" ;;
        s) BUILD_ACTION="socks-server" ;;
        S) BUILD_ACTION="socks-debug" ;;
        h) BUILD_ACTION="help" ;;
        B) BUILD_ACTION="bofs-macos" ;;
        m) BUILD_ACTION="macos" ;;
        M) BUILD_ACTION="macos-debug" ;;
        p)
            PROFILE_TYPE="$OPTARG"
            if [ "$PROFILE_TYPE" != "http" ] && [ "$PROFILE_TYPE" != "httpx" ]; then
                log_error "Invalid profile type: $PROFILE_TYPE. Must be 'http' or 'httpx'"
                exit 1
            fi
            log_info "Using profile type: $PROFILE_TYPE"
            ;;
        A)
            TARGET_ARCH="$OPTARG"
            if [ "$TARGET_ARCH" != "x64" ] && [ "$TARGET_ARCH" != "arm64" ]; then
                log_error "Invalid architecture: $TARGET_ARCH. Must be 'x64' or 'arm64'"
                exit 1
            fi
            ;;
        x)
            DEBUG_SOCKS=1
            log_info "SOCKS debug mode enabled"
            ;;
        \?)
            usage
            exit 1
            ;;
    esac
done

# Resolve all architecture-dependent paths and triples (not needed for help)
if [ "$BUILD_ACTION" != "help" ]; then
    configure_target
fi

# Execute the build action if one was specified
if [ -n "$BUILD_ACTION" ]; then
    # Only setup directories if we're not just cleaning or showing help
    if [ "$BUILD_ACTION" != "clean" ] && [ "$BUILD_ACTION" != "help" ]; then
        setup_directories
    fi
    execute_build "$BUILD_ACTION"
fi

exit 0
