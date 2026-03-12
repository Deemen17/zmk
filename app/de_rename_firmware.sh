#!/bin/bash

# xác định thư mục project
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$APP_DIR/build/zephyr"
OUTPUT_DIR="$APP_DIR/firmware"

UF2="$BUILD_DIR/zmk.uf2"

if [ ! -f "$UF2" ]; then
    echo "UF2 file not found"
    exit 1
fi

BOARD=$(grep '^CONFIG_BOARD="' "$BUILD_DIR/.config" | cut -d'"' -f2)
TIME=$(date +"%Y%m%d_%H%M%S")

mkdir -p "$OUTPUT_DIR"

NAME="${BOARD}_${TIME}.uf2"

cp "$UF2" "$OUTPUT_DIR/$NAME"

echo "Exported firmware: firmware/$NAME"