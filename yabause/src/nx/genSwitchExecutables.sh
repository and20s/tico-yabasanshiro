#!/bin/sh

set -o xtrace

# romfs dir passed as $1 from CMake, fallback to script-relative path
if [ -n "$1" -a -d "$1" ]; then
    ROMFS_DIR="$1"
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    ROMFS_DIR="$SCRIPT_DIR/romfs"
fi

mv yabasanshiro yabasanshiro.elf

if [ -d "$ROMFS_DIR" ] && [ "$(find "$ROMFS_DIR" -type f | head -1)" ]; then
    echo "Embedding romfs from: $ROMFS_DIR"
    elf2nro yabasanshiro.elf ../../yabasanshiro.nro --romfsdir="$ROMFS_DIR"
else
    echo "WARNING: No romfs directory or empty, building NRO without romfs"
    elf2nro yabasanshiro.elf ../../yabasanshiro.nro
fi

elf2nso yabasanshiro.elf ../../yabasanshiro.nso

#mkdir -p exefs
#cp yabasanshiro.nso ./exefs/main
#build_pfs0 exefs yabasanshiro.pfs0
