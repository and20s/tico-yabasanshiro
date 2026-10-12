#!/usr/bin/env bash
# Builds the native emulator core (libyabause_ios.a and its dependencies)
# and installs it into this directory, where the Xcode project links it from.
#
# The static libraries at the project root are single-platform: a device build
# and a simulator build cannot coexist. Run this script to switch between them.
#
#   ./tools/build_core.sh device      # for running on hardware / archiving
#   ./tools/build_core.sh simulator   # for the simulator and unit tests
#
# The build directory is kept per platform so switching only relinks.
set -euo pipefail

PLATFORM_ARG="${1:-}"
case "$PLATFORM_ARG" in
  device)
    CMAKE_PLATFORM="OS64"
    BUILD_DIR="build-ios-device"
    ;;
  simulator|sim)
    CMAKE_PLATFORM="SIMULATORARM64"
    BUILD_DIR="build-ios-sim"
    ;;
  *)
    echo "usage: $0 <device|simulator>" >&2
    exit 2
    ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
BUILD_PATH="$REPO_ROOT/$BUILD_DIR"

if [ ! -f "$BUILD_PATH/CMakeCache.txt" ]; then
  echo "==> configuring $BUILD_DIR ($CMAKE_PLATFORM)"
  mkdir -p "$BUILD_PATH"
  (cd "$BUILD_PATH" && cmake ../yabause \
    -DCMAKE_TOOLCHAIN_FILE=../yabause/src/ios/ios.toolchain.cmake \
    -DPLATFORM="$CMAKE_PLATFORM" \
    -DYAB_PORTS=ios \
    -DYAB_WANT_C68K=FALSE \
    -DYAB_WANT_SH2_CACHE=TRUE \
    -DSH2_DYNAREC=FALSE \
    -DYAB_WANT_DYNAREC_DEVMIYAX=FALSE)
fi

INSTALL_DIR="$REPO_ROOT/yabause/src/ios/uoyabause"

# The link target IS the installed library (LIBRARY_OUTPUT_PATH points at the
# project directory), so make compares against whichever platform was built
# last. Without removing it first, switching platforms is a silent no-op:
# the other platform's archive looks newer than this build's objects.
echo "==> removing the previously installed library"
rm -f "$INSTALL_DIR/libyabause_ios.a"

echo "==> building core for $PLATFORM_ARG"
# zlib must exist before yabause_ios, whose post-build step copies it over.
(cd "$BUILD_PATH" && make zlib -j"$(sysctl -n hw.ncpu)")
(cd "$BUILD_PATH" && make yabause_ios -j"$(sysctl -n hw.ncpu)")

case "$PLATFORM_ARG" in
  device) EXPECTED="IOS" ;;
  *)      EXPECTED="IOSSIMULATOR" ;;
esac

echo "==> installed libraries now target:"
STATUS=0
for lib in "$INSTALL_DIR/libyabause_ios.a" \
           "$INSTALL_DIR/libchdr-static.a" \
           "$INSTALL_DIR/liblzma.a" \
           "$INSTALL_DIR/libzstd.a"; do
  actual="$(otool -lv "$lib" 2>/dev/null | grep -m1 -oE 'platform (IOS|IOSSIMULATOR)' \
            | sed 's/platform //' || true)"
  printf '  %-20s %s\n' "$(basename "$lib")" "${actual:-unknown}"
  if [ "$actual" != "$EXPECTED" ]; then
    STATUS=1
  fi
done

if [ "$STATUS" -ne 0 ]; then
  echo "ERROR: expected every library to target $EXPECTED. The build did not switch" >&2
  echo "       platforms. Remove $BUILD_DIR and rerun to force a clean build." >&2
  exit 1
fi
