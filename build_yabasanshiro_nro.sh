#!/bin/bash
set -e

# Setup paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YABA_DIR="$SCRIPT_DIR"
BUILD_DIR="$YABA_DIR/build_tico"

echo "=== Building YabaSanshiro2 for Switch ===" 
echo "Source: $YABA_DIR"
echo "Build:  $BUILD_DIR"

if [ ! -d "$YABA_DIR" ]; then
    echo "Error: YabaSanshiro2 source directory not found at $YABA_DIR"
    exit 1
fi

# # --- Patched libdrm_nouveau: pre-clear stale Uncached memory attributes ---
# # Replaces the stock portlib with our patched version that prevents
# # Data Abort in armDCacheFlush when heap pages carry stale Uncached attrs
# # from a previous NRO's leaked GPU buffer objects.
# PATCHED_DRM="/project/for_reference/libdrm_nouveau/lib/libdrm_nouveau.a"
# PORTLIB_DRM="/opt/devkitpro/portlibs/switch/lib/libdrm_nouveau.a"
# if [ -f "$PATCHED_DRM" ]; then
#     echo "Installing patched libdrm_nouveau.a over portlib..."
#     cp -f "$PATCHED_DRM" "$PORTLIB_DRM"
#     echo "Done — patched libdrm_nouveau installed"
# else
#     echo "WARNING: Patched libdrm_nouveau.a not found at $PATCHED_DRM"
#     echo "         Using stock portlib (stale-attr crash fix NOT applied)"
# fi

# Clean and create build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Configure for Switch
# WORKAROUND: conflicting zlib and libpng targets
sed -i 's/include( ..\/glfw\/external_zlib.cmake )/#include( ..\/glfw\/external_zlib.cmake )/g' "$YABA_DIR/yabause/src/nx/CMakeLists.txt"
sed -i 's/include( ..\/glfw\/external_libpng.cmake )/#include( ..\/glfw\/external_libpng.cmake )/g' "$YABA_DIR/yabause/src/nx/CMakeLists.txt"

# WORKAROUND: remove invalid -mtp=soft flag from toolchain for aarch64
sed -i 's/-mtp=soft//g' "$YABA_DIR/yabause/src/nx/nx-toolchain.cmake"

# WORKAROUND: enable exceptions
sed -i 's/-fno-exceptions//g' "$YABA_DIR/yabause/src/nx/nx-toolchain.cmake"

# WORKAROUND: exclude cd-web.cpp (requires ifaddrs.h which is missing on Switch)
sed -i 's/cd-web.cpp/#cd-web.cpp/g' "$YABA_DIR/yabause/src/CMakeLists.txt"

# WORKAROUND: exclude PlayRecorder.cpp (causes linker errors with zlib and threading)
sed -i 's/PlayRecorder.cpp/#PlayRecorder.cpp/g' "$YABA_DIR/yabause/src/CMakeLists.txt"

# Using the nx-toolchain.cmake from the repository
cmake "$YABA_DIR/yabause" \
    -Wno-dev \
    -DCMAKE_TOOLCHAIN_FILE="$YABA_DIR/yabause/src/nx/nx-toolchain.cmake" \
    -DPLATFORM=libnx \
    -DNINTENDO_SWITCH=ON \
    -DYAB_PORTS=nx \
    -DCMAKE_BUILD_TYPE=Release \
    -DDEVKITPRO=/opt/devkitpro \
    -DHAVE_LIBSDL=1 \
    -DYAB_WANT_DYNAREC_DEVMIYAX=TRUE \
    -DDYNAREC_DEVMIYAX=TRUE \
    -DSH2_DYNAREC=FALSE \
    -DAARCH64=TRUE \
    -DUSE_AARCH64_DRC=TRUE \
    -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
    -DYAB_WANT_MUSASHI=1 \
    -DYAB_WANT_SCSP=1 \
    -DHAVE_FLOORF=1 \
    -DYAB_WANT_SH2_CACHE=1 \
    -DHAVE_NEON=1 \
    -DYAB_ASYNC_RENDERING=1 \
    -DDISABLE_LOGGING=1 \
    -DCMAKE_C_FLAGS="-DDISABLE_LOGGING=1 -DHAVE_LIBCHDR=1 -DHAVE_LIBSDL=1 -DYAB_ASYNC_RENDERING=1 -DYAB_WANT_SH2_CACHE=1 -DHAVE_FLOORF=1 -DHAVE_NEON=1 -D__ARM_NEON__ -DYAB_WANT_SCSP=1 -DYAB_WANT_MUSASHI=1 -DDYNAREC_DEVMIYAX=1 -DUSE_AARCH64_DRC=1 -DAARCH64=1 -I/opt/devkitpro/portlibs/switch/include/SDL2 -mcpu=cortex-a57 -mtune=cortex-a57 -ffast-math -flto" \
    -DCMAKE_CXX_FLAGS="-DDISABLE_LOGGING=1 -DHAVE_LIBCHDR=1 -DHAVE_LIBSDL=1 -DYAB_ASYNC_RENDERING=1 -DYAB_WANT_SH2_CACHE=1 -DHAVE_FLOORF=1 -DHAVE_NEON=1 -D__ARM_NEON__ -DYAB_WANT_SCSP=1 -DYAB_WANT_MUSASHI=1 -DDYNAREC_DEVMIYAX=1 -DUSE_AARCH64_DRC=1 -DAARCH64=1 -I/opt/devkitpro/portlibs/switch/include/SDL2 -mcpu=cortex-a57 -mtune=cortex-a57 -ffast-math -flto"

# Build
echo "Running Make..."
make -j$(nproc)

echo ""
echo "=== Build Complete ==="

# ============================================================
# Generate NRO with romfs directly (don't rely on POST_BUILD)
# This matches how flycast/tico do it: elf2nro with --nacp + --romfsdir
# ============================================================
ROMFS_DIR="$YABA_DIR/yabause/src/nx/romfs"
NRO_OUT="$SCRIPT_DIR/yabasanshiro.nro"

# Find the ELF binary (CMake target yabause-nx with OUTPUT_NAME yabasanshiro)
ELF_FILE=""
for candidate in \
    "$BUILD_DIR/src/nx/yabasanshiro" \
    "$BUILD_DIR/src/nx/yabasanshiro.elf" \
    "$BUILD_DIR/src/nx/yabause-nx"; do
    if [ -f "$candidate" ]; then
        ELF_FILE="$candidate"
        break
    fi
done

if [ -z "$ELF_FILE" ]; then
    echo "ERROR: Could not find ELF binary in $BUILD_DIR/src/nx/"
    ls -la "$BUILD_DIR/src/nx/" || true
    exit 1
fi
echo "Found ELF: $ELF_FILE"

# Generate NACP metadata (required for proper ASET section)
NACP_FILE="$BUILD_DIR/yabasanshiro.nacp"
nacptool --create "YabaSanshiro" "devmiyax/tico" "0.0.1" "$NACP_FILE"
echo "Generated NACP: $NACP_FILE"

# Build elf2nro arguments
ELF2NRO_ARGS="--nacp=$NACP_FILE"

# Add romfs if directory exists and has files
if [ -d "$ROMFS_DIR" ] && [ -n "$(find "$ROMFS_DIR" -type f 2>/dev/null | head -1)" ]; then
    echo "Embedding romfs from: $ROMFS_DIR"
    find "$ROMFS_DIR" -type f | while read f; do echo "  romfs: $f"; done
    ELF2NRO_ARGS="$ELF2NRO_ARGS --romfsdir=$ROMFS_DIR"
else
    echo "WARNING: No romfs directory or empty at $ROMFS_DIR — NRO will have no embedded assets"
fi

# Generate NRO
echo "Running: elf2nro $ELF_FILE $NRO_OUT $ELF2NRO_ARGS"
elf2nro "$ELF_FILE" "$NRO_OUT" $ELF2NRO_ARGS

if [ -f "$NRO_OUT" ]; then
    NRO_SIZE=$(stat -c%s "$NRO_OUT" 2>/dev/null || stat -f%z "$NRO_OUT" 2>/dev/null)
    echo "SUCCESS: $NRO_OUT generated ($NRO_SIZE bytes)"
else
    echo "ERROR: elf2nro failed to produce $NRO_OUT"
    exit 1
fi
