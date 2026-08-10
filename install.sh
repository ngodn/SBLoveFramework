#!/usr/bin/env bash
#
# SBLoveFramework install / uninstall / status
#
# The mod is plain Lua, so installing is a file copy. This script exists
# because the path is long, because forgetting enabled.txt silently does
# nothing, and because uninstalling has to remove the output files too.
#
#   ./install.sh              install and enable
#   ./install.sh probe NAME   install probe/NAME.lua as the entry point
#   ./install.sh disable      leave files in place but stop it loading
#   ./install.sh uninstall    remove the mod and its output entirely
#   ./install.sh status       report what is installed
#
# Override the game location with SB_DIR if yours differs:
#   SB_DIR="/path/to/StellarBlade" ./install.sh

set -euo pipefail

SB_DIR="${SB_DIR:-/mnt/eins0fxE/SteamLibrary/steamapps/common/StellarBlade}"
WIN64="$SB_DIR/SB/Binaries/Win64"
MODS="$WIN64/ue4ss/Mods"
TARGET="$MODS/SBLoveFramework"
SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Output files the mod writes, removed on uninstall so a stale log is never
# mistaken for a fresh run. That exact confusion cost a debugging cycle.
OUTPUTS=(
    "$WIN64/ue4ss/SBLoveFramework_scan.txt"
    "$WIN64/ue4ss/SBLoveFramework_probe.txt"
)

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

check_game() {
    [ -d "$WIN64" ] || die "game not found at $WIN64 (set SB_DIR)"
    [ -d "$MODS" ]  || die "UE4SS not found at $MODS -- install UE4SS first"
}

case "${1:-install}" in
    install)
        check_game
        mkdir -p "$TARGET/Scripts"
        cp "$SOURCE/Scripts/"*.lua "$TARGET/Scripts/"
        : > "$TARGET/enabled.txt"
        rm -f "${OUTPUTS[@]}"
        printf 'installed and enabled:\n'
        ls -1 "$TARGET/Scripts/" | sed 's/^/  /'
        printf '\nLoad a save and stand in the world. Output:\n  %s\n' "${OUTPUTS[0]}"
        ;;

    probe)
        # Install a probe in place of main.lua. The probe still needs the
        # modules beside it, so everything is copied and only the entry point
        # differs. Running install again puts the real mod back.
        check_game
        name="${2:-}"
        [ -n "$name" ] || die "usage: ./install.sh probe <name>  (e.g. P9_console)"
        src="$SOURCE/probe/$name.lua"
        [ -f "$src" ] || die "no such probe: $src"
        mkdir -p "$TARGET/Scripts"
        cp "$SOURCE/Scripts/"*.lua "$TARGET/Scripts/"
        cp "$src" "$TARGET/Scripts/main.lua"
        : > "$TARGET/enabled.txt"
        rm -f "${OUTPUTS[@]}"
        printf 'probe %s installed as the entry point\n' "$name"
        printf 'run the game, then: ./install.sh status\n'
        printf 'restore the real mod with: ./install.sh\n'
        ;;

    disable)
        # UE4SS keys off enabled.txt, so removing it is enough. Keeping the
        # scripts means re-enabling is instant.
        [ -d "$TARGET" ] || die "not installed"
        rm -f "$TARGET/enabled.txt"
        printf 'disabled (scripts left in place; run install to re-enable)\n'
        ;;

    uninstall)
        rm -rf "$TARGET"
        rm -f "${OUTPUTS[@]}"
        printf 'removed %s and its output files\n' "$TARGET"
        ;;

    status)
        if [ -d "$TARGET" ]; then
            if [ -f "$TARGET/enabled.txt" ]; then
                printf 'installed, ENABLED\n'
            else
                printf 'installed, disabled\n'
            fi
            ls -1 "$TARGET/Scripts/" 2>/dev/null | sed 's/^/  /'
        else
            printf 'not installed\n'
        fi
        for out in "${OUTPUTS[@]}"; do
            [ -f "$out" ] && printf 'output: %s (%s lines)\n' \
                "$out" "$(wc -l < "$out")"
        done
        exit 0
        ;;

    *)
        die "unknown command '$1' (install | probe <name> | disable | uninstall | status)"
        ;;
esac
