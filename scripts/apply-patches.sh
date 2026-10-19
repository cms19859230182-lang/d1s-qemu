#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 cms19859230182-lang
#
# Apply the d1s patch series to the unpacked QEMU tree.
#
# Run scripts/fetch-qemu.sh first.  This script refuses to run twice: it
# records which patches it applied in a stamp file inside the QEMU tree,
# so a second invocation reports an error instead of half-applying or
# double-applying anything.

set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here"

qemu_version=$(sed -n 's/^QEMU release:[[:space:]]*//p' QEMU_VERSION)
srcdir=qemu-$qemu_version
stamp=$srcdir/.d1s-patches-applied

[ -d "$srcdir" ] || {
    echo "error: $srcdir not found; run scripts/fetch-qemu.sh first" >&2
    exit 1
}

if [ -e "$stamp" ]; then
    echo "error: the d1s patches are already applied to $srcdir" >&2
    echo "       (see $stamp); remove the tree and re-fetch to start over" >&2
    exit 1
fi

patch_cmd="patch"
if command -v git >/dev/null 2>&1; then
    patch_cmd="git apply"
fi

applied=""
for p in patches/[0-9][0-9][0-9][0-9]-*.patch; do
    [ -e "$p" ] || { echo "error: no patches found in patches/" >&2; exit 1; }
    echo "applying $(basename "$p")"
    if [ "$patch_cmd" = "git apply" ]; then
        # git apply works relative to the enclosing git work tree and silently
        # skips paths outside the current directory, so when this checkout is
        # itself a git clone the patches would not land.  Give the QEMU tree
        # its own repository so git apply runs from its top.
        [ -e "$srcdir/.git" ] || git -C "$srcdir" init -q
        ( cd "$srcdir" && git apply --whitespace=nowarn "$here/$p" )
    else
        ( cd "$srcdir" && patch -p1 --no-backup-if-mismatch -i "$here/$p" )
    fi
    applied="$applied $(basename "$p")"
done

[ -f "$srcdir/hw/riscv/d1s.c" ] || {
    echo "error: patches did not apply (hw/riscv/d1s.c missing)" >&2
    exit 1
}

{
    echo "applied by scripts/apply-patches.sh"
    for a in $applied; do echo "$a"; done
} > "$stamp"

echo "done:$applied"
