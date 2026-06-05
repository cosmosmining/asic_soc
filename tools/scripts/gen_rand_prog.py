#!/usr/bin/env python3
"""gen_rand_prog.py <seed> [n_instr] > prog.hex

Emit a random *linear* RV32IM program (no branches/jumps) of register-register,
register-immediate, and M-extension ops, terminated by `jal x0, 0` (self-loop
halt). Linear + no memory keeps every run terminating and in-bounds, while the
random rd/rs1/rs2 choices create dense forwarding/hazard pressure and exercise
the multiplier and divider (including div-by-zero and signed-overflow corners,
since operands are unconstrained). Used by the golden-trace differential test.
"""
import random
import sys

OPC_OP, OPC_OPIMM = 0x33, 0x13

# (funct7, funct3) for R-type RV32I + RV32M
R_OPS = [
    (0x00, 0x0),  # add
    (0x20, 0x0),  # sub
    (0x00, 0x1),  # sll
    (0x00, 0x2),  # slt
    (0x00, 0x3),  # sltu
    (0x00, 0x4),  # xor
    (0x00, 0x5),  # srl
    (0x20, 0x5),  # sra
    (0x00, 0x6),  # or
    (0x00, 0x7),  # and
    (0x01, 0x0),  # mul
    (0x01, 0x1),  # mulh
    (0x01, 0x2),  # mulhsu
    (0x01, 0x3),  # mulhu
    (0x01, 0x4),  # div
    (0x01, 0x5),  # divu
    (0x01, 0x6),  # rem
    (0x01, 0x7),  # remu
]
# funct3 for I-type (immediate) ALU ops
I_OPS = [0x0, 0x2, 0x3, 0x4, 0x6, 0x7, 0x1, 0x5]  # addi slti sltiu xori ori andi slli srli/srai


def r_type(f7, f3, rd, rs1, rs2):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | OPC_OP


def i_type(f3, rd, rs1, imm):
    if f3 == 0x1:                      # slli: shamt + funct7=0
        imm = imm & 0x1F
    elif f3 == 0x5:                    # srli/srai: shamt + funct7 (0x00/0x20)
        imm = (random.choice([0x00, 0x20]) << 5) | (imm & 0x1F)
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | OPC_OPIMM


def main():
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 64
    random.seed(seed)

    words = []
    for _ in range(n):
        rd, rs1, rs2 = (random.randint(0, 31) for _ in range(3))
        if random.random() < 0.5:
            f7, f3 = random.choice(R_OPS)
            words.append(r_type(f7, f3, rd, rs1, rs2))
        else:
            f3 = random.choice(I_OPS)
            imm = random.randint(-2048, 2047) & 0xFFF
            words.append(i_type(f3, rd, rs1, imm))
    words.append(0x0000006F)           # jal x0, 0  (halt)

    for w in words:
        print(f"{w & 0xFFFFFFFF:08X}")


if __name__ == "__main__":
    main()
