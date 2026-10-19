#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 cms19859230182-lang
#
# Automated boot-to-msh smoke test.
#
# Usage:
#   tests/smoke.sh <rtthread.bin> <bsp-dir> [seconds]
#   IDLE=120 LIST_THREAD=1 tests/smoke.sh ...   (optional extras)
#
# Boots the d1s machine, sends `version` and `free` (and `list thread` when
# LIST_THREAD=1) over the UART3 console; with IDLE=N it then waits N seconds
# and sends the same commands again,
# and checks that the msh prompt appears together with the expected output.
# Prints PASS or FAIL on the last line and leaves the full transcript in the
# directory given by $LOGDIR (default: a temporary directory).

set -u

here=$(cd "$(dirname "$0")/.." && pwd)
rtthread=${1:-}
bsp=${2:-}
idle=${IDLE:-0}
list_thread=${LIST_THREAD:-0}
seconds=${3:-$((30 + idle * 2))}

[ -n "$rtthread" ] || { echo "usage: smoke.sh <rtthread.bin> <bsp-dir> [seconds]" >&2; exit 2; }
[ -n "$bsp" ] || { echo "error: bsp-dir required" >&2; exit 2; }
[ -r "$rtthread" ] || { echo "error: $rtthread not readable" >&2; exit 1; }
[ -d "$bsp" ] || { echo "error: $bsp not a directory" >&2; exit 1; }

qemu=$here/qemu-10.1.2/build/qemu-system-riscv64
[ -x "$qemu" ] || {
    echo "error: $qemu not built; run scripts/build.sh" >&2
    exit 1
}
[ -r "$here/firmware/tramp/tramp.bin" ] || {
    echo "error: firmware/tramp/tramp.bin missing" >&2
    exit 1
}

logdir=${LOGDIR:-}
cleanup=""
if [ -z "$logdir" ]; then
    logdir=$(mktemp -d -t d1s-smoke.XXXXXX)
    cleanup=$logdir
fi
mkdir -p "$logdir"

console=$logdir/uart3.log
feeder=$logdir/feed.py

# The console is a real 16550; feeding a whole command in one write makes
# RT-Thread's RX ring buffer overflow, so send one character at a time.
cat > "$feeder" <<'PYEOF'
import sys
import time


def send(text):
    for ch in text:
        sys.stdout.buffer.write(ch.encode())
        sys.stdout.buffer.flush()
        time.sleep(0.05)
    sys.stdout.buffer.write(b"\r")
    sys.stdout.buffer.flush()


import os

idle = int(os.environ.get("IDLE", "0"))
lt = os.environ.get("LIST_THREAD", "0") == "1"


def round_():
    send("version")
    time.sleep(3)
    send("free")
    time.sleep(3)
    if lt:
        send("list thread")
        time.sleep(4)


time.sleep(10)
round_()
if idle:
    time.sleep(idle)
    round_()
time.sleep(2)
PYEOF

# A FIFO lets the Python feeder run concurrently with QEMU: the writer
# blocks until QEMU opens the read end, and QEMU sees a normal stdin.
fifo=$logdir/console.in
python3 - "$fifo" <<'MKFIFO'
import os, sys
try:
    os.unlink(sys.argv[1])
except FileNotFoundError:
    pass
os.mkfifo(sys.argv[1])
MKFIFO

IDLE=$idle LIST_THREAD=$list_thread python3 "$feeder" > "$fifo" 2>/dev/null &
feeder_pid=$!

timeout "$seconds" "$qemu" \
    -M d1s -cpu thead-c906 -m 64M -nographic -monitor none \
    -serial stdio -serial file:"$logdir/uart0.log" \
    -bios none \
    -device loader,file="$bsp/sbi.bin",addr=0x40000000,force-raw=on \
    -device loader,file="$bsp/u-boot.dtb",addr=0x40200000,force-raw=on \
    -device loader,file="$rtthread",addr=0x40400000,force-raw=on \
    -device loader,file="$here/firmware/tramp/tramp.bin",addr=0x40100000,force-raw=on \
    < "$fifo" > "$console" 2>&1
status=$?
wait "$feeder_pid" 2>/dev/null || true
echo "qemu exit: $status (a timeout exit is expected)"

# Strip ANSI colour codes so the assertions below do not depend on the
# RT-Thread log level colouring.
plain=$logdir/uart3.plain
sed -e 's/\x1b\[[0-9;]*m//g' "$console" > "$plain"

fail=0
check() {
    desc=$1
    pattern=$2
    if grep -q -- "$pattern" "$plain"; then
        echo "ok   : $desc"
    else
        echo "FAIL : $desc (no match for '$pattern')"
        fail=1
    fi
}

check "trampoline banner"        '\[d1s-qemu\] tramp -> OpenSBI fw_dynamic'
check "msh prompt"               'msh />'
check "version command output"   'build Oct'
check "free command output"      'total    :'
check "free available memory"    'available:'

rounds=1
[ "$idle" -gt 0 ] && rounds=2
count_ok() {
    desc=$1; pattern=$2; want=$3
    n=$(grep -c -- "$pattern" "$plain")
    if [ "$n" -ge "$want" ]; then
        echo "ok   : $desc ($n)"
    else
        echo "FAIL : $desc (want >= $want, got $n)"
        fail=1
    fi
}
count_ok "version banners"        'Thread Smart Operating System' $((rounds + 1))
count_ok "free outputs"           'total    :' "$rounds"
if [ "$list_thread" = 1 ]; then
    count_ok "list thread header" '^thread ' "$rounds"
    count_ok "list thread tshell" '^tshell ' "$rounds"
fi
if grep -q -i -e 'Exception' -e 'Execption' "$plain"; then
    echo "FAIL : CPU exception on console"
    fail=1
else
    echo "ok   : no CPU exception"
fi

if [ "$fail" -ne 0 ]; then
    echo "---- console tail ----"
    tail -40 "$plain"
    echo "FAIL"
    [ -n "$cleanup" ] && rm -rf "$cleanup"
    exit 1
fi

echo "PASS (console log: $console)"
[ -n "$cleanup" ] && rm -rf "$cleanup"
exit 0