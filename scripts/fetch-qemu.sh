#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 cms19859230182-lang
#
# Fetch the upstream QEMU release this repository targets and unpack it
# into ./qemu-10.1.2.
#
# The tarball is verified against the sha256 recorded in QEMU_VERSION
# before anything is unpacked.  Set QEMU_TARBALL to use a local copy
# instead of downloading (useful for offline builds); the checksum is
# verified either way.

set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"

version_file=QEMU_VERSION
[ -f "$version_file" ] || { echo "error: $version_file not found" >&2; exit 1; }

qemu_version=$(sed -n 's/^QEMU release:[[:space:]]*//p' "$version_file")
tarball_url=$(sed -n 's/^Tarball:[[:space:]]*//p' "$version_file")
want_sha256=$(sed -n 's/^Tarball sha256:[[:space:]]*//p' "$version_file")

for v in qemu_version tarball_url want_sha256; do
    eval "val=\$$v"
    [ -n "$val" ] || { echo "error: $v missing from $version_file" >&2; exit 1; }
done

tarball=qemu-$qemu_version.tar.xz
srcdir=qemu-$qemu_version

# ---------------------------------------------------------------- download
if [ -n "${QEMU_TARBALL:-}" ]; then
    src=$QEMU_TARBALL
    [ -r "$src" ] || { echo "error: QEMU_TARBALL=$src is not readable" >&2; exit 1; }
    echo "using local tarball: $src"
elif [ -f "$tarball" ]; then
    src=$tarball
    echo "using existing $tarball"
else
    src=$tarball
    echo "downloading $tarball_url"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 -o "$tarball.part" "$tarball_url"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$tarball.part" "$tarball_url"
    else
        echo "error: need curl or wget to download the tarball" >&2
        exit 1
    fi
    mv "$tarball.part" "$tarball"
fi

# ---------------------------------------------------------------- verify
have_sha256=$(sha256sum "$src" | cut -d' ' -f1)
if [ "$have_sha256" != "$want_sha256" ]; then
    echo "error: sha256 mismatch for $src" >&2
    echo "  expected: $want_sha256" >&2
    echo "  actual:   $have_sha256" >&2
    exit 1
fi
echo "sha256 ok: $have_sha256"

# ---------------------------------------------------------------- unpack
if [ -d "$srcdir" ]; then
    echo "$srcdir already exists, leaving it alone"
    exit 0
fi

echo "unpacking $src"
tar -xf "$src"
[ -d "$srcdir" ] || { echo "error: $srcdir missing after unpack" >&2; exit 1; }
echo "done: $here/$srcdir"
