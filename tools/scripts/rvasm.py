#!/usr/bin/env python3
"""rvasm.py - a tiny two-pass RV32IM assembler (no external toolchain needed).

Emits a word-per-line hex image (the format $readmemh and the cocotb loader
consume). Supports the RV32IM instruction set the cores implement, the Zicsr +
machine-mode privileged subset, the common pseudo-instructions, labels, and a
handful of directives. It is deliberately small and dependency-free so the repo
can build firmware without a RISC-V GCC install.

Usage:
    rvasm.py input.s -o output.hex          # assemble a file
    rvasm.py - -o out.hex < program.s        # assemble from stdin
    python3 -c "import rvasm; img = rvasm.assemble(text)"   # as a library

Directives:
    .org N        set the location counter (byte address)
    .word v[,v..] emit literal 32-bit words
    .equ NAME,V   define a symbol
    label:        define a label at the current address

The encoder functions are reused by the directed-test generators.
"""
import re
import sys

# ---------------------------------------------------------------- registers
_ABI = {
    'zero': 0, 'ra': 1, 'sp': 2, 'gp': 3, 'tp': 4, 't0': 5, 't1': 6, 't2': 7,
    'fp': 8, 's0': 8, 's1': 9, 'a0': 10, 'a1': 11, 'a2': 12, 'a3': 13,
    'a4': 14, 'a5': 15, 'a6': 16, 'a7': 17, 's2': 18, 's3': 19, 's4': 20,
    's5': 21, 's6': 22, 's7': 23, 's8': 24, 's9': 25, 's10': 26, 's11': 27,
    't3': 28, 't4': 29, 't5': 30, 't6': 31,
}
_CSR = {
    'mstatus': 0x300, 'misa': 0x301, 'mie': 0x304, 'mtvec': 0x305,
    'mscratch': 0x340, 'mepc': 0x341, 'mcause': 0x342, 'mtval': 0x343,
    'mip': 0x344, 'mcycle': 0xB00, 'minstret': 0xB02, 'mcycleh': 0xB80,
    'minstreth': 0xB82, 'mhartid': 0xF14,
}


def reg(tok):
    t = tok.strip().lower()
    if t in _ABI:
        return _ABI[t]
    if re.fullmatch(r'x(\d+)', t):
        n = int(t[1:])
        if 0 <= n < 32:
            return n
    raise ValueError(f"bad register '{tok}'")


# ---------------------------------------------------------------- encoders
def _r(f7, f3, rd, rs1, rs2, op):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def _i(f3, rd, rs1, imm, op):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def _s(f3, rs1, rs2, imm, op):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | \
           ((imm & 0x1F) << 7) | op


def _b(f3, rs1, rs2, imm, op):
    imm &= 0x1FFF
    b12, b105, b41, b11 = (imm >> 12) & 1, (imm >> 5) & 0x3F, (imm >> 1) & 0xF, (imm >> 11) & 1
    return (b12 << 31) | (b105 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | \
           (b41 << 8) | (b11 << 7) | op


def _u(rd, imm, op):
    return ((imm & 0xFFFFF) << 12) | (rd << 7) | op


def _j(rd, imm, op):
    imm &= 0x1FFFFF
    b20, b101, b11, b1912 = (imm >> 20) & 1, (imm >> 1) & 0x3FF, (imm >> 11) & 1, (imm >> 12) & 0xFF
    return (b20 << 31) | (b101 << 21) | (b11 << 20) | (b1912 << 12) | (rd << 7) | op


OP_IMM, OP, LOAD, STORE, BRANCH = 0x13, 0x33, 0x03, 0x23, 0x63
JALR, JAL, LUI, AUIPC, SYSTEM, FENCE = 0x67, 0x6F, 0x37, 0x17, 0x73, 0x0F

# mnemonic -> (kind, f3, f7/op-detail)
_RTYPE = {
    'add': (0x00, 0x0), 'sub': (0x20, 0x0), 'sll': (0x00, 0x1), 'slt': (0x00, 0x2),
    'sltu': (0x00, 0x3), 'xor': (0x00, 0x4), 'srl': (0x00, 0x5), 'sra': (0x20, 0x5),
    'or': (0x00, 0x6), 'and': (0x00, 0x7),
    'mul': (0x01, 0x0), 'mulh': (0x01, 0x1), 'mulhsu': (0x01, 0x2), 'mulhu': (0x01, 0x3),
    'div': (0x01, 0x4), 'divu': (0x01, 0x5), 'rem': (0x01, 0x6), 'remu': (0x01, 0x7),
}
_ITYPE = {'addi': 0x0, 'slti': 0x2, 'sltiu': 0x3, 'xori': 0x4, 'ori': 0x6, 'andi': 0x7}
_SHIFTI = {'slli': (0x1, 0x00), 'srli': (0x5, 0x00), 'srai': (0x5, 0x20)}
_LOAD = {'lb': 0x0, 'lh': 0x1, 'lw': 0x2, 'lbu': 0x4, 'lhu': 0x5}
_STORE = {'sb': 0x0, 'sh': 0x1, 'sw': 0x2}
_BRANCH = {'beq': 0x0, 'bne': 0x1, 'blt': 0x4, 'bge': 0x5, 'bltu': 0x6, 'bgeu': 0x7}
_CSROP = {'csrrw': 0x1, 'csrrs': 0x2, 'csrrc': 0x3, 'csrrwi': 0x5, 'csrrsi': 0x6, 'csrrci': 0x7}


class AsmError(Exception):
    pass


def _imm(tok, syms, pc=None, rel=False):
    """Resolve an immediate/symbol token to an int."""
    t = tok.strip()
    if t in syms:
        v = syms[t]
    else:
        try:
            v = int(t, 0)
        except ValueError:
            raise AsmError(f"undefined symbol or bad immediate '{tok}'")
    return (v - pc) if rel else v


_MEM_RE = re.compile(r'^(-?\w+|-?0x[0-9a-fA-F]+|[A-Za-z_.$][\w.$]*)\(\s*(\w+)\s*\)$')


def assemble(text, base=0):
    """Assemble source text -> list of 32-bit ints (the image, word 0 == addr base)."""
    # ---- tokenize lines, stripping comments ----
    raw = []
    for ln in text.splitlines():
        ln = ln.split('#', 1)[0].split('//', 1)[0]
        if ';' in ln and not _MEM_RE.search(ln):
            ln = ln.split(';', 1)[0]
        ln = ln.strip()
        if ln:
            raw.append(ln)

    syms = {}

    # ---- pass 1: place labels / compute addresses ----
    def split_labels(line):
        labels = []
        while True:
            m = re.match(r'^([A-Za-z_.$][\w.$]*)\s*:\s*(.*)$', line)
            if not m:
                break
            labels.append(m.group(1))
            line = m.group(2).strip()
        return labels, line

    prog = []  # (addr, mnemonic, args)
    pc = base
    for line in raw:
        labels, rest = split_labels(line)
        for lb in labels:
            syms[lb] = pc
        if not rest:
            continue
        parts = rest.split(None, 1)
        mn = parts[0].lower()
        args = parts[1].strip() if len(parts) > 1 else ''
        if mn == '.org':
            pc = int(args, 0)
            continue
        if mn == '.equ':
            name, val = [a.strip() for a in args.split(',', 1)]
            syms[name] = int(val, 0)
            continue
        if mn == '.word':
            words = [a for a in args.split(',') if a.strip()]
            prog.append((pc, '.word', args))
            pc += 4 * len(words)
            continue
        if mn in ('.ascii', '.asciz', '.string', '.byte'):
            data = _data_bytes(mn, args)
            prog.append((pc, mn, args))
            pc += 4 * len(_pack_words(data))     # rounded up to a word boundary
            continue
        if mn == '.align':                        # .align N -> align to 2**N bytes
            n = int(args, 0)
            step = 1 << n
            pc = (pc + step - 1) & ~(step - 1)
            continue
        prog.append((pc, mn, args))
        pc += 4 * _isize(mn, args)

    # ---- pass 2: encode ----
    image = {}
    for addr, mn, args in prog:
        for off, word in enumerate(_encode(mn, args, addr, syms)):
            image[addr + 4 * off] = word & 0xFFFFFFFF

    if not image:
        return []
    top = max(image)
    out = []
    a = base
    while a <= top:
        out.append(image.get(a, 0))
        a += 4
    return out


def _li_short(operand):
    """True iff `li rd, operand` fits in a single addi. Depends ONLY on the
    operand string (not on symbol values), so pass 1 (sizing) and pass 2
    (encoding) always agree -- a symbol is treated as long even if it resolves
    small, which keeps every later address stable."""
    try:
        iv = int(operand.strip(), 0)
    except ValueError:
        return False                  # a symbol -> always lui+addi (2 words)
    return -2048 <= iv < 2048


def _isize(mn, args):
    """Number of 32-bit words a (pseudo)instruction expands to."""
    if mn == 'li':
        _, v = [a.strip() for a in args.split(',', 1)]
        return 1 if _li_short(v) else 2
    if mn in ('la', 'call'):
        return 2
    return 1


_ESCAPES = {'n': 10, 't': 9, 'r': 13, '0': 0, '\\': 92, '"': 34, "'": 39}


def _parse_string(tok):
    """Parse a double-quoted string literal (with \\n \\t \\0 \\\\ \\" escapes)."""
    s = tok.strip()
    if len(s) < 2 or s[0] != '"' or s[-1] != '"':
        raise AsmError(f"expected a quoted string, got {tok!r}")
    out = bytearray()
    i = 1
    while i < len(s) - 1:
        c = s[i]
        if c == '\\':
            i += 1
            out.append(_ESCAPES.get(s[i], ord(s[i])))
        else:
            out.append(ord(c))
        i += 1
    return bytes(out)


def _data_bytes(mn, args):
    if mn == '.byte':
        vals = [int(x.strip(), 0) & 0xFF for x in args.split(',') if x.strip()]
        return bytes(vals)
    b = _parse_string(args)
    if mn in ('.asciz', '.string'):
        b = b + b'\x00'
    return b


def _pack_words(data):
    words = []
    for i in range(0, len(data), 4):
        chunk = data[i:i + 4]
        w = 0
        for j, byte in enumerate(chunk):
            w |= byte << (8 * j)            # little-endian
        words.append(w & 0xFFFFFFFF)
    return words


def _encode(mn, args, pc, syms):
    a = [x.strip() for x in args.split(',')] if args else []

    if mn == '.word':
        return [_imm(x, syms) for x in a]
    if mn in ('.ascii', '.asciz', '.string', '.byte'):
        return _pack_words(_data_bytes(mn, args))

    # ---- pseudo-instructions ----
    if mn == 'nop':
        return [_i(0x0, 0, 0, 0, OP_IMM)]
    if mn == 'li':
        rd = reg(a[0])
        if _li_short(a[1]):                       # 1-word form: addi rd, x0, imm
            return [_i(0x0, rd, 0, _imm(a[1], syms), OP_IMM)]
        v = _imm(a[1], syms) & 0xFFFFFFFF         # 2-word form: lui + addi
        lo = v & 0xFFF
        hi = (v + (0x1000 if (lo & 0x800) else 0)) >> 12
        return [_u(rd, hi, LUI), _i(0x0, rd, rd, lo, OP_IMM)]
    if mn == 'la':
        rd = reg(a[0]); v = _imm(a[1], syms)
        lo = v & 0xFFF
        hi = (v + (0x1000 if (lo & 0x800) else 0)) >> 12
        return [_u(rd, hi, LUI), _i(0x0, rd, rd, lo, OP_IMM)]
    if mn == 'mv':
        return [_i(0x0, reg(a[0]), reg(a[1]), 0, OP_IMM)]
    if mn == 'not':
        return [_i(0x4, reg(a[0]), reg(a[1]), -1, OP_IMM)]
    if mn == 'neg':
        return [_r(0x20, 0x0, reg(a[0]), 0, reg(a[1]), OP)]
    if mn == 'seqz':
        return [_i(0x3, reg(a[0]), reg(a[1]), 1, OP_IMM)]
    if mn == 'snez':
        return [_r(0x00, 0x3, reg(a[0]), 0, reg(a[1]), OP)]
    if mn == 'j':
        return [_j(0, _imm(a[0], syms, pc, rel=True), JAL)]
    if mn == 'jr':
        return [_i(0x0, 0, reg(a[0]), 0, JALR)]
    if mn == 'ret':
        return [_i(0x0, 0, 1, 0, JALR)]
    if mn == 'call':
        off = _imm(a[0], syms, pc, rel=True)
        lo = off & 0xFFF
        hi = (off + (0x1000 if (lo & 0x800) else 0)) >> 12
        return [_u(1, hi, AUIPC), _i(0x0, 1, 1, lo, JALR)]
    if mn in ('beqz', 'bnez', 'bltz', 'bgez'):
        base_mn = {'beqz': 'beq', 'bnez': 'bne', 'bltz': 'blt', 'bgez': 'bge'}[mn]
        f3 = _BRANCH[base_mn]
        return [_b(f3, reg(a[0]), 0, _imm(a[1], syms, pc, rel=True), BRANCH)]

    # ---- privileged / system ----
    if mn == 'ecall':
        return [_i(0x0, 0, 0, 0x000, SYSTEM)]
    if mn == 'ebreak':
        return [_i(0x0, 0, 0, 0x001, SYSTEM)]
    if mn == 'mret':
        return [_i(0x0, 0, 0, 0x302, SYSTEM)]
    if mn == 'wfi':
        return [_i(0x0, 0, 0, 0x105, SYSTEM)]
    if mn == 'fence':
        return [_i(0x0, 0, 0, 0, FENCE)]
    if mn == 'csrr':                                   # csrr rd, csr  == csrrs rd,csr,x0
        return [_csr_enc('csrrs', reg(a[0]), 'zero', a[1], syms)]
    if mn == 'csrw':                                   # csrw csr, rs  == csrrw x0,csr,rs
        return [_csr_enc('csrrw', 0, a[1], a[0], syms)]
    if mn == 'csrs':                                   # csrs csr, rs  == csrrs x0,csr,rs
        return [_csr_enc('csrrs', 0, a[1], a[0], syms)]
    if mn == 'csrc':                                   # csrc csr, rs  == csrrc x0,csr,rs
        return [_csr_enc('csrrc', 0, a[1], a[0], syms)]
    if mn in _CSROP:
        rd = reg(a[0]); csr_t = a[1]; src = a[2]
        return [_csr_enc(mn, rd, src, csr_t, syms)]

    # ---- base ISA ----
    if mn in _RTYPE:
        f7, f3 = _RTYPE[mn]
        return [_r(f7, f3, reg(a[0]), reg(a[1]), reg(a[2]), OP)]
    if mn in _ITYPE:
        return [_i(_ITYPE[mn], reg(a[0]), reg(a[1]), _imm(a[2], syms), OP_IMM)]
    if mn in _SHIFTI:
        f3, f7 = _SHIFTI[mn]
        sh = _imm(a[2], syms) & 0x1F
        return [_r(f7, f3, reg(a[0]), reg(a[1]), sh, OP_IMM)]
    if mn in _LOAD:
        rd = reg(a[0]); off, rs1 = _memref(a[1], syms)
        return [_i(_LOAD[mn], rd, rs1, off, LOAD)]
    if mn in _STORE:
        rs2 = reg(a[0]); off, rs1 = _memref(a[1], syms)
        return [_s(_STORE[mn], rs1, rs2, off, STORE)]
    if mn in _BRANCH:
        return [_b(_BRANCH[mn], reg(a[0]), reg(a[1]), _imm(a[2], syms, pc, rel=True), BRANCH)]
    if mn == 'jal':
        if len(a) == 1:
            return [_j(1, _imm(a[0], syms, pc, rel=True), JAL)]
        return [_j(reg(a[0]), _imm(a[1], syms, pc, rel=True), JAL)]
    if mn == 'jalr':
        if len(a) == 1:
            return [_i(0x0, 1, reg(a[0]), 0, JALR)]
        off, rs1 = _memref(a[2], syms) if '(' in a[2] else (_imm(a[2], syms), reg(a[1]))
        return [_i(0x0, reg(a[0]), rs1, off, JALR)]
    if mn == 'lui':
        return [_u(reg(a[0]), _imm(a[1], syms), LUI)]
    if mn == 'auipc':
        return [_u(reg(a[0]), _imm(a[1], syms), AUIPC)]
    raise AsmError(f"unknown mnemonic '{mn}'")


def _csr_enc(mn, rd, src, csr_tok, syms):
    f3 = _CSROP[mn]
    csr_t = csr_tok.strip().lower()
    addr = _CSR[csr_t] if csr_t in _CSR else _imm(csr_tok, syms)
    if mn.endswith('i'):
        z = _imm(src, syms) & 0x1F if not isinstance(src, int) else src & 0x1F
        return _i(f3, rd, z, addr, SYSTEM)
    rs1 = src if isinstance(src, int) else reg(src)
    return _i(f3, rd, rs1, addr, SYSTEM)


def _memref(tok, syms):
    m = _MEM_RE.match(tok.strip())
    if not m:
        raise AsmError(f"bad memory operand '{tok}' (want imm(reg))")
    return _imm(m.group(1), syms), reg(m.group(2))


def main(argv):
    out = None
    src = None
    i = 1
    while i < len(argv):
        if argv[i] == '-o':
            out = argv[i + 1]; i += 2
        else:
            src = argv[i]; i += 1
    text = sys.stdin.read() if (src is None or src == '-') else open(src).read()
    img = assemble(text)
    lines = '\n'.join(f"{w:08X}" for w in img) + '\n'
    if out:
        open(out, 'w').write(lines)
    else:
        sys.stdout.write(lines)


if __name__ == '__main__':
    main(sys.argv)
