#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 cms19859230182-lang
#
# Launch the d1s machine with an RT-Thread image.
#
# Usage:
#   run.sh <rtthread.bin> [--bsp <rt-thread/bsp/allwinner/d1s>]
#                         [--uart0-log FILE] [--trace FILE]
#                         [--console uart3|uart0]
#                         [--timeout SECONDS] [--] [qemu args...]
#
# The OpenSBI image (sbi.bin) and device tree (u-boot.dtb) are looked up in
# the directory given by --bsp; if not given, they are taken from
# $RTT_D1S_BSP.  sbi.bin and u-boot.dtb ship with the RT-Thread tree under
# bsp/allwinner/d1s and are not vendored here.
#
# The trampoline, OpenSBI, DTB and payload are loaded into DRAM at fixed
# addresses:
#   0x40100000  trampoline (this repo, firmware/tramp/tramp.bin)
#   0x40000000  OpenSBI (sbi.bin from --bsp)
#   0x40200000  device tree (u-boot.dtb from --bsp)
#   0x40400000  RT-Thread image (first positional argument)
#
# UART3 is the application console; the boot chain takes care of bringing
# it up.  UART0 is wired to the vendor firmware console and captured into
# the file given by --uart0-log (default: /dev/null).  --console uart0 swaps
# the two: UART0 goes to stdio (the console of the upstream RT-Smart d1s BSP)
# and UART3 to the --uart0-log file.  --trace FILE enables
# -d guest_errors,unimp logging; it is off by default because it grows fast.

set -eu

here=$(cd "$(dirname "$0")" && pwd)

# ----------------------------------------------------------- argument parsing
rtthread=""
bsp="${RTT_D1S_BSP:-}"
uart0_log=""
trace=""
timeout=""
console=uart3

while [ $# -gt 0 ]; do
        case "$1" in
            --bsp) bsp=$2; shift 2;;
            --bsp=*) bsp=${1#--bsp=}; shift;;
            --uart0-log) uart0_log=$2; shift 2;;
            --uart0-log=*) uart0_log=${1#--uart0-log=}; shift;;
            --trace) trace=$2; shift 2;;
            --trace=*) trace=${1#--trace=}; shift;;
            --console) console=$2; shift 2;;
            --console=*) console=${1#--console=}; shift;;
            --timeout) timeout=$2; shift 2;;
            --timeout=*) timeout=${1#--timeout=}; shift;;
            --) shift; break;;
            -*) echo "unknown option: $1" >&2; exit 2;;
            *)
                if [ -z "$rtthread" ]; then rtthread=$1; else break; fi
                shift;;
        esac
done

if [ -z "$rtthread" ]; then
    echo "usage: run.sh <rtthread.bin> [--bsp <rt-thread/bsp/allwinner/d1s>]" >&2
    exit 2
fi

[ -r "$rtthread" ] || { echo "error: cannot read $rtthread" >&2; exit 1; }
[ -n "$bsp" ] || { echo "error: --bsp or RTT_D1S_BSP is required" >&2; exit 1; }
[ -r "$bsp/sbi.bin" ] || { echo "error: $bsp/sbi.bin not found" >&2; exit 1; }
[ -r "$bsp/u-boot.dtb" ] || { echo "error: $bsp/u-boot.dtb not found" >&2; exit 1; }

tramp=$here/firmware/tramp/tramp.bin
[ -r "$tramp" ] || { echo "error: $tramp missing; run firmware/tramp/build.sh" >&2; exit 1; }

qemu=$here/qemu-10.1.2/build/qemu-system-riscv64
[ -x "$qemu" ] || {
    echo "error: $qemu not built; run scripts/fetch-qemu.sh && scripts/apply-patches.sh && scripts/build.sh" >&2
    exit 1
}

# ----------------------------------------------------------- qemu options
side=${uart0_log:-/dev/null}
case "$console" in
    uart3) serial_args="-serial stdio -serial file:$side";;
    uart0) serial_args="-serial file:$side -serial stdio";;
    *) echo "error: --console must be uart3 or uart0" >&2; exit 2;;
esac

trace_arg=""
[ -n "$trace" ] && trace_arg="-d guest_errors,unimp -D $trace"

timeout_cmd=""
if [ -n "$timeout" ]; then
    timeout_cmd="timeout $timeout"
fi

# ----------------------------------------------------------- launch
exec $timeout_cmd "$qemu" \
    -M d1s -cpu thead-c906 -m 64M -nographic -monitor none \
    $serial_args \
    -bios none \
    -device loader,file="$bsp/sbi.bin",addr=0x40000000,force-raw=on \
    -device loader,file="$bsp/u-boot.dtb",addr=0x40200000,force-raw=on \
    -device loader,file="$rtthread",addr=0x40400000,force-raw=on \
    -device loader,file="$tramp",addr=0x40100000,force-raw=on \
    $trace_arg "$@"
