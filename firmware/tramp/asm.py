#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 cms19859230182-lang
"""
Tiny RV64I assembler used to build the d1s trampoline.

The d1s-qemu repository ships a prebuilt firmware/tramp/tramp.bin that
was produced with this script; running it again is optional and only
requires Python 3, not a RISC-V cross toolchain.

The trampoline uses a handful of instructions (lui, addi, lw, sw, lbu,
sb, beq, bne, jal, andi, slli, add) which is exactly what this script
encodes.

Output bytes are compared against the SHA-256 recorded in tramp.SHA256
when --check is supplied, so a half-built trampoline never sneaks in.
"""

import argparse
import hashlib
import os
import struct
import sys


# RV64I register ABI names.
ABI = {
    "zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4,
    "t0": 5, "t1": 6, "t2": 7,
    "s0": 8, "s1": 9,
    "a0": 10, "a1": 11, "a2": 12, "a3": 13, "a4": 14, "a5": 15,
    "a6": 16, "a7": 17,
}


def reg(name):
    if isinstance(name, int):
        return name
    if name in ABI:
        return ABI[name]
    if name.isdigit():
        return int(name)
    raise ValueError("unknown register: " + str(name))


# Encoders --------------------------------------------------------
def enc_u(rd, imm, opcode=0x37):
    """LUI (opcode 0x37) or AUIPC (opcode 0x17)."""
    return ((imm & 0xFFFFF000) | (reg(rd) << 7) | opcode) & 0xFFFFFFFF


def enc_i(funct3, rd, rs1, imm, opcode=0x13):
    """OP-IMM (0x13) by default; pass opcode=0x03 for loads."""
    return ((imm & 0xFFF) << 20) | (reg(rs1) << 15) | (funct3 << 12) \
        | (reg(rd) << 7) | opcode


def enc_s(funct3, rs1, rs2, imm):
    imm &= 0xFFF
    return (((imm >> 5) << 25) | (reg(rs2) << 20) | (reg(rs1) << 15)
            | (funct3 << 12) | ((imm & 0x1F) << 7) | 0x23)


def enc_b(funct3, rs1, rs2, imm):
    imm &= 0x1FFE
    return ((((imm >> 12) & 1) << 31)
            | (((imm >> 5) & 0x3F) << 25)
            | (reg(rs2) << 20) | (reg(rs1) << 15)
            | (funct3 << 12)
            | (((imm >> 1) & 0xF) << 8)
            | (((imm >> 11) & 1) << 7)
            | 0x63)


def enc_j(rd, imm):
    """Encode a JAL (or J pseudo-op when rd == zero).

    imm is a byte offset that must be a multiple of 2.  RISC-V packs the
    21-bit immediate into four fields of the instruction word.
    """
    imm &= 0x1FFFFF
    return ((((imm >> 20) & 1) << 31)
            | (((imm >> 1) & 0x3FF) << 21)
            | (((imm >> 11) & 1) << 20)
            | (((imm >> 12) & 0xFF) << 12)
            | (reg(rd) << 7)
            | 0x6F)


class Asm:
    """Two-pass assembler: emits code first, patches branches in resolve()."""

    def __init__(self):
        self.words = []
        self.labels = {}
        self.pending = []    # (idx, label, kind, funct3_or_None)

    # ---- bookkeeping -------------------------------------------
    def here(self):
        return len(self.words) * 4

    def label(self, name):
        if name in self.labels:
            raise ValueError("duplicate label: " + name)
        self.labels[name] = self.here()

    def emit(self, w):
        self.words.append(w & 0xFFFFFFFF)

    def align(self, n):
        while self.here() & (n - 1):
            self.nop()

    # ---- pseudo-ops --------------------------------------------
    def nop(self):
        self.emit(0x00000013)

    def li(self, rd, imm):
        """Load a 64-bit immediate via LUI + ADDI.

        ADDI sign-extends its 12-bit immediate, so the upper half has to be
        rounded up whenever the low half has bit 11 set; otherwise
        0x02500c00 turns into 0x024ffc00.
        """
        imm &= 0xFFFFFFFFFFFFFFFF
        if imm >= 0x80000000:
            # Represent as a signed value so the sign extension works out.
            val = imm - (1 << 32)
            if -2048 <= val <= 2047:
                self.emit(enc_i(0x0, rd, "zero", val & 0xFFF))
                return
        elif -2048 <= imm <= 2047:
            self.emit(enc_i(0x0, rd, "zero", imm & 0xFFF))
            return

        hi = ((imm + 0x800) >> 12) & 0xFFFFF
        lo = imm - (hi << 12)
        self.emit(enc_u(rd, hi << 12))
        if lo:
            self.emit(enc_i(0x0, rd, rd, lo & 0xFFF))

    def mv(self, rd, rs):
        self.emit(enc_i(0x0, rd, rs, 0))

    def lw(self, rd, rs1, off):
        self.emit(enc_i(0x2, rd, rs1, off, opcode=0x03))

    def sw(self, rs2, rs1, off):
        self.emit(enc_s(0x2, rs1, rs2, off))

    def lbu(self, rd, rs1, off):
        self.emit(enc_i(0x4, rd, rs1, off, opcode=0x03))

    def sb(self, rs2, rs1, off):
        self.emit(enc_s(0x0, rs1, rs2, off))

    def andi(self, rd, rs1, imm):
        self.emit(enc_i(0x7, rd, rs1, imm))

    def addi(self, rd, rs1, imm):
        self.emit(enc_i(0x0, rd, rs1, imm))

    def or_(self, rd, rs1, rs2):
        # or rd, rs1, rs2
        self.emit((0x0 << 25) | (reg(rs2) << 20) | (reg(rs1) << 15)
                  | (0x6 << 12) | (reg(rd) << 7) | 0x33)


    def beq(self, rs1, rs2, label):
        self.emit(enc_b(0x0, rs1, rs2, 0))
        self.pending.append((len(self.words) - 1, label, "b", 0x0))

    def bne(self, rs1, rs2, label):
        self.emit(enc_b(0x1, rs1, rs2, 0))
        self.pending.append((len(self.words) - 1, label, "b", 0x1))

    def beqz(self, rs, label):
        self.beq(rs, "zero", label)

    def j(self, label):
        self.emit(enc_j("zero", 0))
        self.pending.append((len(self.words) - 1, label, "j", None))

    def fence_iorw(self):
        # fence iorw, iorw
        self.emit(0x0FF0000F)

    def la(self, rd, label):
        """Load the address of @label with AUIPC + ADDI (PC-relative).

        The offset is patched in resolve() once the label's byte offset is
        known; here both instructions are emitted as zero-immediate
        placeholders so their length is final.
        """
        base = len(self.words)
        self.emit(0x00000017 | (reg(rd) << 7))        # auipc rd, 0
        self.emit(enc_i(0x0, rd, rd, 0))              # addi  rd, rd, 0
        self.pending.append((base, label, "pc_rel", reg(rd)))

    # ---- patch -------------------------------------------------
    def resolve(self):
        for idx, label, kind, meta in self.pending:
            target = self.labels[label]
            if kind == "j":
                # JAL immediate is relative to the instruction itself.
                self.words[idx] = enc_j("zero", target - idx * 4)
            elif kind == "b":
                w = self.words[idx]
                rs1 = (w >> 15) & 0x1F
                rs2 = (w >> 20) & 0x1F
                funct3 = (w >> 12) & 0x7
                self.words[idx] = enc_b(funct3, rs1, rs2,
                                        target - idx * 4)
            elif kind == "pc_rel":
                # AUIPC at slot @idx computes PC + hi20 << 12; the ADDI in
                # the next slot then adds the low half.  Both halves come
                # from the same delta, measured from the AUIPC's own PC.
                rd = meta
                delta = target - idx * 4
                hi = ((delta + 0x800) >> 12) & 0xFFFFF
                lo = delta - (hi << 12)
                self.words[idx] = enc_u(rd, hi << 12, opcode=0x17)
                self.words[idx + 1] = enc_i(0x0, rd, rd, lo & 0xFFF)


# --------------------------------------------------------------
# Build the trampoline.  Register use is fixed so the result
# stays auditable against the original A2 reference: t0, t1, t2
# as scratch, s0 for hartid, s1 for the UART3 base.
# --------------------------------------------------------------

def build():
    a = Asm()
    banner = (b"\r\n[d1s-qemu] tramp -> OpenSBI fw_dynamic\r\n"
              + b"\x00" * 3)                              # round up to 4 bytes

    # mv s0, a0  -- save hartid passed in a0
    a.mv("s0", "a0")

    # ----- 1. Ungate UART3 bus clock ---------------------------
    # t2 = load(CCU_BUS_CLK_GATE3); t2 |= 1 << 19; store back.
    a.li("t0", 0x02001900)
    a.li("t1", 1)
    a.emit(enc_i(0x1, "t1", "t1", 19))                     # slli t1, t1, 19
    a.lw("t2", "t0", 0x0c)
    a.or_("t2", "t2", "t1")
    a.sw("t2", "t0", 0x0c)

    # ----- 2. PB pin mux to UART3 ------------------------------
    a.li("t0", 0x02000000)
    a.li("t1", 0x55)
    a.sw("t1", "t0", 0x124)

    # ----- 3. Bring up UART3 -----------------------------------
    a.li("s1", 0x02500c00)
    a.li("t0", 0x83)                                       # LCR = 8N1, DLAB
    a.sw("t0", "s1", 0x0c)
    a.li("t0", 3)                                          # DLL
    a.sw("t0", "s1", 0x00)
    a.sw("zero", "s1", 0x04)                               # DLH
    a.li("t0", 0x07)                                       # FCR
    a.sw("t0", "s1", 0x08)
    a.li("t0", 0x03)                                       # LCR = 8N1, DLAB off
    a.sw("t0", "s1", 0x0c)

    # ----- 4. Print banner one byte at a time ------------------
    a.la("a2", "banner")
    a.label("lp_top")
    a.lbu("a3", "a2", 0)
    a.beqz("a3", "lp_end")
    a.label("lp_wait")
    a.lw("a4", "s1", 0x14)                                 # LSR
    a.andi("a4", "a4", 0x20)                               # THRE
    a.beqz("a4", "lp_wait")
    a.sb("a3", "s1", 0x00)                                 # THR
    a.addi("a2", "a2", 1)
    a.j("lp_top")
    a.label("lp_end")

    # ----- 5. Set up the OpenSBI fw_dynamic handover -----------
    # OpenSBI's fw_dynamic entry takes:
    #   a0 = hartid
    #   a1 = address of the device tree
    #   a2 = address of a struct fw_dynamic_info
    # The struct lives inside this image (see fw_dynamic_info below), so
    # the trampoline only has to hand over its address.
    a.la("a2", "fw_dynamic_info")

    # ----- 6. fence and hand over ------------------------------
    a.fence_iorw()
    a.mv("a0", "s0")                     # hartid
    a.li("a1", 0x40200000)               # device tree
    a.li("t0", 0x40000000)               # OpenSBI entry
    # jr t0: jalr zero, 0(t0)
    a.emit((reg("t0") << 15) | (reg("zero") << 7) | 0x67)

    # Data area: banner string, then the fw_dynamic_info struct.  Both are
    # part of the image and are addressed PC-relatively, so their offsets
    # are known only after the code is complete.  Reserve the space first so
    # the code's size -- and therefore every branch -- is final.
    a.align(4)
    a.label("banner")
    banner_off = a.here()
    for _ in range((len(banner) + 3) // 4):
        a.emit(0)
    a.align(8)
    a.label("fw_dynamic_info")
    info_off = a.here()
    info = struct.pack("<QQQQQQ",
                       0x4942534F,             # magic "OSBI"
                       2,                       # version
                       0x40400000,              # next_addr
                       1,                       # next_mode (S-mode)
                       0,                       # options
                       0xFFFFFFFFFFFFFFFF)     # boot_hart: not specified
    for _ in range(len(info) // 4):
        a.emit(0)

    a.resolve()

    data = b"".join(struct.pack("<I", w) for w in a.words)
    if len(data) != info_off + len(info):
        raise AssertionError("unexpected image size: %d (expected %d)"
                             % (len(data), info_off + len(info)))

    # Patch the data area in place; sizes match so nothing shifts.
    data = bytearray(data)
    data[banner_off:banner_off + len(banner)] = banner
    data[info_off:info_off + len(info)] = info
    return bytes(data)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    p.add_argument("--check", default=None,
                   help="Compare SHA-256 against this file's recorded value.")
    args = p.parse_args()

    data = build()
    if len(data) & 3:
        data += b"\x00" * (4 - (len(data) & 3))

    digest = hashlib.sha256(data).hexdigest()

    if args.check:
        want = open(args.check).read().split()[0]
        if digest != want:
            sys.stderr.write("sha256 mismatch: %s vs %s\n" % (digest, want))
            sys.exit(1)
        print("sha256 ok: %s" % digest)

    with open(args.out, "wb") as f:
        f.write(data)

    print("wrote %s (%d bytes, sha256 %s)" % (args.out, len(data), digest))


if __name__ == "__main__":
    main()