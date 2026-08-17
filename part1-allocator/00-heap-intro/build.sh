#!/bin/bash

set -e

GLIBC_VERSION=$(ldd --version | head -n 1 | grep -oE '[0-9]+\.[0-9]+' | head -n 1)
GLIBC_TAG=$(echo "$GLIBC_VERSION" | tr -d '.')

OUTPUT="sample${GLIBC_TAG}"

gcc \
    -g \
    -O0 \
    -fno-omit-frame-pointer \
    -o "$OUTPUT" \
    sample.c

echo "Built: $OUTPUT (glibc $GLIBC_VERSION)"

echo ""
echo "[i] Run this manually if needed:"
echo "    echo 0 | sudo tee /proc/sys/kernel/randomize_va_space"
