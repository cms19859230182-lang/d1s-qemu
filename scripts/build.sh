#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 cms19859230182-lang
#
# Configure and build qemu-system-riscv64 with the d1s machine.
#
# Only riscv64-softmmu is built, with documentation, tools and the
# various optional back ends turned off, so the dependency set stays
# small.  Output ends up in qemu-<version>/build/qemu-system-riscv64.

set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"

qemu_version=$(sed -n 's/^QEMU release:[[:space:]]*//p' QEMU_VERSION)
srcdir=qemu-$qemu_version
builddir=$srcdir/build

[ -d "$srcdir" ] || {
    echo "error: $srcdir not found; run scripts/fetch-qemu.sh first" >&2
    exit 1
}
[ -e "$srcdir/.d1s-patches-applied" ] || {
    echo "error: the d1s patches are not applied; run scripts/apply-patches.sh" >&2
    exit 1
}
[ -x "$srcdir/configure" ] || {
    echo "error: $srcdir/configure missing or not executable" >&2
    exit 1
}

jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}

mkdir -p "$builddir"
cd "$builddir"

if [ ! -f build.ninja ]; then
    echo "configuring (target-list=riscv64-softmmu)"
    "$here/$srcdir/configure" \
        --target-list=riscv64-softmmu \
        --disable-docs \
        --disable-tools \
        --disable-guest-agent \
        --disable-werror \
        --disable-debug-info
fi

echo "building with -j$jobs"
ninja -j"$jobs"

echo "built: $builddir/qemu-system-riscv64"
