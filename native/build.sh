#!/usr/bin/env bash
#
# Build SBLoveNative and install it as a UE4SS mod.
#
#   ./build.sh            configure if needed, build, install
#   ./build.sh clean      wipe the build directory first
#   ./build.sh status     report what is installed
#   ./build.sh uninstall  remove the mod
#
# Cross-compiles Linux -> Windows x64 with clang-cl against the MSVC SDK that
# xwin fetched. See toolchain-clang-cl.cmake for why the MSVC ABI is required.
#
# This NEVER touches the installed UE4SS.dll. Upgrading UE4SS broke the game's
# launch once already (there is a rollback in mod-backups/), and this mod does
# not use the UE4SS C++ API, so it has no reason to care which build is present.

set -euo pipefail

SB_DIR="${SB_DIR:-/mnt/eins0fxE/SteamLibrary/steamapps/common/StellarBlade}"
WIN64="$SB_DIR/SB/Binaries/Win64"
TARGET="$WIN64/ue4ss/Mods/SBLoveNative"
SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$SOURCE/build"
LOG="$TARGET/SBLoveNative.txt"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 not found. $2"
}

case "${1:-build}" in
    status)
        if [ -f "$TARGET/dlls/main.dll" ]; then
            printf 'installed: %s\n' "$TARGET/dlls/main.dll"
            [ -f "$TARGET/enabled.txt" ] && printf '  ENABLED\n' || printf '  disabled\n'
        else
            printf 'not installed\n'
        fi
        [ -f "$LOG" ] && { printf '\n--- %s ---\n' "$LOG"; cat "$LOG"; }
        exit 0
        ;;

    uninstall)
        rm -rf "$TARGET"
        rm -f "$LOG"
        printf 'removed %s\n' "$TARGET"
        exit 0
        ;;

    clean)
        rm -rf "$BUILD"
        printf 'build directory wiped\n'
        ;;
esac

need cmake "Install it with: pkexec pacman -S cmake"
need ninja "Install it with: pkexec pacman -S ninja"
need clang-cl "Install it with: pkexec pacman -S clang"

[ -d "$HOME/.xwin/crt/include" ] || die \
    "no MSVC SDK. Run: cargo install xwin && xwin --accept-license --arch x86_64 splat --output ~/.xwin"

if [ ! -f "$BUILD/build.ninja" ]; then
    cmake -S "$SOURCE" -B "$BUILD" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$SOURCE/toolchain-clang-cl.cmake" \
        -DCMAKE_BUILD_TYPE=Release
fi

cmake --build "$BUILD"

[ -f "$BUILD/main.dll" ] || die "build produced no main.dll"

[ -d "$WIN64/ue4ss/Mods" ] || die "UE4SS not found at $WIN64/ue4ss/Mods"

mkdir -p "$TARGET/dlls"
cp "$BUILD/main.dll" "$TARGET/dlls/main.dll"
: > "$TARGET/enabled.txt"

# A stale log read as a fresh run has already cost this project a debugging
# cycle, so it goes before every run rather than after.
rm -f "$LOG"

printf 'installed %s\n' "$TARGET/dlls/main.dll"
printf 'run the game, then: ./build.sh status\n'
