#!/usr/bin/env python3
"""gen_csr_test.py > csr_test.hex

Emit a directed machine-mode CSR/trap test program. Exercises every Zicsr op
(CSRRW/S/C and *I forms), the performance counter minstret, and all the
synchronous traps the core implements (ECALL, illegal instruction, and
load/store/instruction address-misaligned), each routed through a single
trap handler that advances mepc past the faulting instruction and MRETs.

The golden ISS computes the expected retire trace, so the differential test
(tb_riscv_trace) checks the DUT against it -- no values are hand-computed here.
"""

OP_IMM, OP, LOAD, STORE, JALR, JAL, SYSTEM = 0x13, 0x33, 0x03, 0x23, 0x67, 0x6F, 0x73

def i(f3, rd, rs1, imm):   return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | OP_IMM
def addi(rd, rs1, imm):    return i(0x0, rd, rs1, imm)
def load(f3, rd, rs1, imm):return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | LOAD
def store(f3, rs1, rs2, imm):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | STORE
def jalr(rd, rs1, imm):    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | JALR
def csr(f3, rd, rs1, addr):return ((addr & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | SYSTEM
# CSR forms
def csrrw(rd, rs1, a):  return csr(0x1, rd, rs1, a)
def csrrs(rd, rs1, a):  return csr(0x2, rd, rs1, a)
def csrrc(rd, rs1, a):  return csr(0x3, rd, rs1, a)
def csrrwi(rd, z, a):   return csr(0x5, rd, z, a)
def csrrsi(rd, z, a):   return csr(0x6, rd, z, a)
def csrrci(rd, z, a):   return csr(0x7, rd, z, a)
def ecall():            return csr(0x0, 0, 0, 0x000)
def mret():             return csr(0x0, 0, 0, 0x302)
def jal(rd, imm):       # only used for the self-loop halt (imm=0)
    imm &= 0x1FFFFF
    b20, b101, b11, b1912 = (imm>>20)&1, (imm>>1)&0x3FF, (imm>>11)&1, (imm>>12)&0xFF
    return (b20<<31)|(b101<<21)|(b11<<20)|(b1912<<12)|(rd<<7)|JAL

# CSR addresses
MSTATUS, MISA, MTVEC = 0x300, 0x301, 0x305
MSCRATCH, MEPC, MCAUSE = 0x340, 0x341, 0x342
MINSTRET = 0xB02

HANDLER = 0x44   # byte address of the trap handler (see layout below)

prog = [
    addi (1, 0, HANDLER),       # 0x00 x1 = handler address
    csrrw(0, 1, MTVEC),         # 0x04 mtvec = handler
    addi (2, 0, 0x123),         # 0x08 x2 = 0x123
    csrrw(3, 2, MSCRATCH),      # 0x0C x3=old(0), mscratch=0x123
    csrrs(4, 0, MSCRATCH),      # 0x10 x4=0x123
    csrrwi(5, 5, MSCRATCH),     # 0x14 x5=0x123, mscratch=5
    csrrsi(6, 2, MSCRATCH),     # 0x18 x6=5,     mscratch=7
    csrrci(7, 1, MSCRATCH),     # 0x1C x7=7,     mscratch=6
    csrrs(8, 0, MINSTRET),      # 0x20 x8 = retired-instruction count (=8)
    csrrs(9, 0, MISA),          # 0x24 x9 = 0x40001100
    ecall(),                    # 0x28 ECALL          (cause 11)
    0x00000000,                 # 0x2C illegal insn   (cause 2)
    load(0x2, 10, 0, 1),        # 0x30 LW  x10,1(x0)  load-misaligned  (cause 4)
    store(0x1, 0, 11, 1),       # 0x34 SH  x11,1(x0)  store-misaligned (cause 6)
    jalr (0, 0, 2),             # 0x38 JALR ->addr 2  insn-misaligned  (cause 0)
    addi (12, 0, 0xAA),         # 0x3C x12 = 0xAA     (post-trap marker)
    jal  (0, 0),                # 0x40 halt (self-loop)
    # ---- trap handler @ 0x44 ----
    csrrs(20, 0, MEPC),         # 0x44 x20 = mepc
    addi (20, 20, 4),           # 0x48 x20 += 4  (skip the faulting instruction)
    csrrw(0, 20, MEPC),         # 0x4C mepc = x20
    csrrs(21, 0, MCAUSE),       # 0x50 x21 = mcause
    mret(),                     # 0x54 return to mepc
]

assert HANDLER == 4 * 17, "handler offset must match its index in the layout"
for w in prog:
    print(f"{w & 0xFFFFFFFF:08X}")
