#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 cms19859230182-lang
#
# Build firmware/tramp/tramp.bin from firmware/tramp/asm.py.  This script
# uses Python only -- no RISC-V toolchain is required -- and verifies the
# output against the SHA-256 recorded in tramp.SHA256.

set -eu

here=$(cd "$(dirname "$0")" && pwd)

out="$here/tramp.bin"
sha="$here/tramp.SHA256"

python3 "$here/asm.py" --out "$out.tmp" --check "$sha"
mv "$out.tmp" "$out"
echo "OK: $out"