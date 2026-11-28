#!/usr/bin/env bash
# Build Vortex Crosshair.
#   ./build.sh          -> dist/VortexCrosshair.exe (cross-compiled with MinGW-w64)
#   ./build.sh preview  -> build/preview_ui (Linux harness that renders the UI to PNG)
# Requirements (Debian/Ubuntu): sudo apt install g++-mingw-w64-x86-64-posix mingw-w64
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build dist

CXXFLAGS_COMMON="-std=c++17 -O2 -Wall -Wextra -Wno-missing-field-initializers"
PORTABLE="src/canvas.cpp src/crosshair.cpp src/settings.cpp src/ui.cpp"

if [[ "${1:-}" == "preview" ]]; then
    g++ $CXXFLAGS_COMMON -o build/preview_ui tools/preview_ui.cpp $PORTABLE
    echo "built build/preview_ui"
    exit 0
fi

# 1) app icon (rendered by the real crosshair renderer)
g++ $CXXFLAGS_COMMON -o build/make_icon tools/make_icon.cpp src/canvas.cpp src/crosshair.cpp
./build/make_icon res/vortex.ico assets/icon-256.png

# 2) resources (icon, manifest, version info)
x86_64-w64-mingw32-windres -I res res/resource.rc -O coff -o build/resource.o

# 3) the executable: static, no runtime DLLs needed
CXX=x86_64-w64-mingw32-g++-posix
command -v "$CXX" >/dev/null || CXX=x86_64-w64-mingw32-g++
"$CXX" $CXXFLAGS_COMMON -municode -mwindows -DNDEBUG -fno-exceptions -fno-rtti \
    -ffunction-sections -fdata-sections \
    -o dist/VortexCrosshair.exe src/main_win32.cpp $PORTABLE build/resource.o \
    -static -static-libgcc -static-libstdc++ -Wl,--gc-sections -s \
    -ldwmapi -lgdi32 -luser32 -lshell32 -ladvapi32 -lole32
ls -la dist/VortexCrosshair.exe
