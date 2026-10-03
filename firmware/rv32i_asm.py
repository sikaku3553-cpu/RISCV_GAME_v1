#!/usr/bin/env python3
"""Small, deterministic RV32I assembler used by the game firmware.

This intentionally has no third-party dependencies.  It accepts the small
GNU-like syntax used by game.S, expands a few readability pseudos, emits a
4096-word readmemh image, and then decodes every emitted instruction again.
The decoder's legal set matches docs/RV32I_COVERAGE.md (40 RV32I instructions).
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path


IMEM_WORDS = 4096
NOP = 0x00000013

REGISTERS = {f"x{i}": i for i in range(32)}
REGISTERS.update(
    {
        "zero": 0,
        "ra": 1,
        "sp": 2,
        "gp": 3,
        "tp": 4,
        "t0": 5,
        "t1": 6,
        "t2": 7,
        "s0": 8,
        "fp": 8,
        "s1": 9,
        "a0": 10,
        "a1": 11,
        "a2": 12,
        "a3": 13,
        "a4": 14,
        "a5": 15,
        "a6": 16,
        "a7": 17,
        "s2": 18,
        "s3": 19,
        "s4": 20,
        "s5": 21,
        "s6": 22,
        "s7": 23,
        "s8": 24,
        "s9": 25,
        "s10": 26,
        "s11": 27,
        "t3": 28,
        "t4": 29,
        "t5": 30,
        "t6": 31,
    }
)

BASE_INSTRUCTIONS = {
    "lui", "auipc", "jal", "jalr",
    "beq", "bne", "blt", "bge", "bltu", "bgeu",
    "lb", "lh", "lw", "lbu", "lhu",
    "sb", "sh", "sw",
    "addi", "slti", "sltiu", "xori", "ori", "andi",
    "slli", "srli", "srai",
    "add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and",
    "fence", "ecall", "ebreak",
}


@dataclass(frozen=True)
class SourceLine:
    path: Path
    number: int
    text: str


@dataclass(frozen=True)
class Emitted:
    address: int
    word: int
    source: SourceLine
    expanded: str


class AssemblyError(Exception):
    pass


def fail(line: SourceLine, message: str) -> AssemblyError:
    return AssemblyError(f"{line.path}:{line.number}: {message}\n    {line.text.rstrip()}")


def read_with_includes(path: Path, stack: tuple[Path, ...] = ()) -> list[SourceLine]:
    path = path.resolve()
    if path in stack:
        raise AssemblyError(f"recursive include: {' -> '.join(map(str, stack + (path,)))}")
    result: list[SourceLine] = []
    for number, text in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = re.match(r'^\s*\.include\s+"([^"]+)"\s*(?:#.*)?$', text)
        if match:
            result.extend(read_with_includes(path.parent / match.group(1), stack + (path,)))
        else:
            result.append(SourceLine(path, number, text))
    return result


def clean(text: str) -> str:
    return text.split("#", 1)[0].split("//", 1)[0].strip()


class Expr(ast.NodeVisitor):
    def __init__(self, symbols: dict[str, int]):
        self.symbols = symbols

    def evaluate(self, text: str) -> int:
        try:
            return int(self.visit(ast.parse(text.strip(), mode="eval").body))
        except (SyntaxError, KeyError, ValueError, TypeError, ZeroDivisionError) as exc:
            raise AssemblyError(f"invalid expression {text!r}: {exc}") from exc

    def visit_Constant(self, node: ast.Constant) -> int:
        if isinstance(node.value, int):
            return node.value
        raise ValueError("only integer constants are allowed")

    def visit_Name(self, node: ast.Name) -> int:
        return self.symbols[node.id]

    def visit_UnaryOp(self, node: ast.UnaryOp) -> int:
        value = self.visit(node.operand)
        if isinstance(node.op, ast.USub):
            return -value
        if isinstance(node.op, ast.UAdd):
            return value
        if isinstance(node.op, ast.Invert):
            return ~value
        raise ValueError("unsupported unary operator")

    def visit_BinOp(self, node: ast.BinOp) -> int:
        left, right = self.visit(node.left), self.visit(node.right)
        operations = {
            ast.Add: lambda: left + right,
            ast.Sub: lambda: left - right,
            ast.Mult: lambda: left * right,
            ast.FloorDiv: lambda: left // right,
            ast.Mod: lambda: left % right,
            ast.LShift: lambda: left << right,
            ast.RShift: lambda: left >> right,
            ast.BitOr: lambda: left | right,
            ast.BitAnd: lambda: left & right,
            ast.BitXor: lambda: left ^ right,
        }
        for kind, operation in operations.items():
            if isinstance(node.op, kind):
                return operation()
        raise ValueError("unsupported binary operator")

    def generic_visit(self, node: ast.AST) -> int:
        raise ValueError(f"unsupported expression node {type(node).__name__}")


def reg(token: str, line: SourceLine) -> int:
    key = token.strip().lower()
    if key not in REGISTERS:
        raise fail(line, f"unknown register {token!r}")
    return REGISTERS[key]


def operands(text: str) -> list[str]:
    return [part.strip() for part in text.split(",") if part.strip()]


def signed_range(value: int, bits: int, what: str) -> None:
    if not (-(1 << (bits - 1)) <= value < (1 << (bits - 1))):
        raise AssemblyError(f"{what} {value} does not fit signed {bits} bits")


def parse_mem(token: str, symbols: dict[str, int], line: SourceLine) -> tuple[int, int]:
    match = re.match(r"^(.+)\(([^()]+)\)$", token.replace(" ", ""))
    if not match:
        raise fail(line, f"expected offset(register), got {token!r}")
    return Expr(symbols).evaluate(match.group(1)), reg(match.group(2), line)


def r_type(funct7: int, rs2: int, rs1: int, funct3: int, rd: int, opcode: int = 0x33) -> int:
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def i_type(imm: int, rs1: int, funct3: int, rd: int, opcode: int) -> int:
    signed_range(imm, 12, "immediate")
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def s_type(imm: int, rs2: int, rs1: int, funct3: int) -> int:
    signed_range(imm, 12, "store immediate")
    value = imm & 0xFFF
    return ((value >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | ((value & 0x1F) << 7) | 0x23


def b_type(offset: int, rs2: int, rs1: int, funct3: int) -> int:
    if offset & 1:
        raise AssemblyError(f"branch offset {offset} is not 2-byte aligned")
    signed_range(offset, 13, "branch offset")
    value = offset & 0x1FFF
    return (((value >> 12) & 1) << 31) | (((value >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (((value >> 1) & 0xF) << 8) | (((value >> 11) & 1) << 7) | 0x63


def u_type(value: int, rd: int, opcode: int) -> int:
    # Accept either a 20-bit field (GNU syntax) or an already shifted value.
    field = (value >> 12) if (value > 0xFFFFF or value < -0x80000) and (value & 0xFFF) == 0 else value
    if not (-(1 << 19) <= field < (1 << 20)):
        raise AssemblyError(f"upper immediate {value} does not fit 20 bits")
    return ((field & 0xFFFFF) << 12) | (rd << 7) | opcode


def j_type(offset: int, rd: int) -> int:
    if offset & 1:
        raise AssemblyError(f"jump offset {offset} is not 2-byte aligned")
    signed_range(offset, 21, "jump offset")
    value = offset & 0x1FFFFF
    return (((value >> 20) & 1) << 31) | (((value >> 1) & 0x3FF) << 21) | (((value >> 11) & 1) << 20) | (((value >> 12) & 0xFF) << 12) | (rd << 7) | 0x6F


def instruction_size(statement: str, symbols: dict[str, int], line: SourceLine) -> int:
    mnemonic, _, argument_text = statement.partition(" ")
    mnemonic = mnemonic.lower()
    if mnemonic == "li":
        args = operands(argument_text)
        if len(args) != 2:
            raise fail(line, "li expects two operands")
        value = Expr(symbols).evaluate(args[1])
        return 4 if -2048 <= value <= 2047 else 8
    return 4


def encode(statement: str, pc: int, symbols: dict[str, int], line: SourceLine) -> list[tuple[int, str]]:
    mnemonic, _, argument_text = statement.partition(" ")
    mnemonic = mnemonic.lower()
    args = operands(argument_text)
    expr = Expr(symbols)

    # Fixed-size readability pseudos.  Every result is a supported RV32I word.
    if mnemonic == "nop":
        mnemonic, args = "addi", ["x0", "x0", "0"]
    elif mnemonic == "mv":
        mnemonic, args = "addi", [args[0], args[1], "0"]
    elif mnemonic == "neg":
        mnemonic, args = "sub", [args[0], "x0", args[1]]
    elif mnemonic == "j":
        mnemonic, args = "jal", ["x0", args[0]]
    elif mnemonic == "call":
        mnemonic, args = "jal", ["ra", args[0]]
    elif mnemonic == "ret":
        mnemonic, args = "jalr", ["x0", "0(ra)"]
    elif mnemonic == "beqz":
        mnemonic, args = "beq", [args[0], "x0", args[1]]
    elif mnemonic == "bnez":
        mnemonic, args = "bne", [args[0], "x0", args[1]]
    elif mnemonic == "bltz":
        mnemonic, args = "blt", [args[0], "x0", args[1]]
    elif mnemonic == "bgez":
        mnemonic, args = "bge", [args[0], "x0", args[1]]
    elif mnemonic == "bgtz":
        mnemonic, args = "blt", ["x0", args[0], args[1]]
    elif mnemonic == "blez":
        mnemonic, args = "bge", ["x0", args[0], args[1]]
    elif mnemonic in ("bgt", "ble", "bgtu", "bleu"):
        swaps = {"bgt": "blt", "ble": "bge", "bgtu": "bltu", "bleu": "bgeu"}
        mnemonic, args = swaps[mnemonic], [args[1], args[0], args[2]]
    elif mnemonic == "li":
        if len(args) != 2:
            raise fail(line, "li expects two operands")
        rd = reg(args[0], line)
        value = expr.evaluate(args[1])
        value32 = value & 0xFFFFFFFF
        signed_value = value32 if value32 < 0x80000000 else value32 - 0x100000000
        if -2048 <= signed_value <= 2047:
            return [(i_type(signed_value, 0, 0, rd, 0x13), f"addi {args[0]}, zero, {signed_value}")]
        upper = (signed_value + 0x800) >> 12
        lower = signed_value - (upper << 12)
        return [
            (u_type(upper, rd, 0x37), f"lui {args[0]}, {upper}"),
            (i_type(lower, rd, 0, rd, 0x13), f"addi {args[0]}, {args[0]}, {lower}"),
        ]

    try:
        if mnemonic in ("lui", "auipc"):
            if len(args) != 2:
                raise AssemblyError(f"{mnemonic} expects two operands")
            return [(u_type(expr.evaluate(args[1]), reg(args[0], line), 0x37 if mnemonic == "lui" else 0x17), statement)]
        if mnemonic == "jal":
            if len(args) == 1:
                args = ["ra", args[0]]
            target = expr.evaluate(args[1])
            return [(j_type(target - pc, reg(args[0], line)), statement)]
        if mnemonic == "jalr":
            if len(args) == 2 and "(" in args[1]:
                imm, rs1 = parse_mem(args[1], symbols, line)
                rd = reg(args[0], line)
            elif len(args) == 3:
                rd, rs1, imm = reg(args[0], line), reg(args[1], line), expr.evaluate(args[2])
            else:
                raise AssemblyError("jalr expects rd, offset(rs1) or rd, rs1, immediate")
            return [(i_type(imm, rs1, 0, rd, 0x67), statement)]
        if mnemonic in ("beq", "bne", "blt", "bge", "bltu", "bgeu"):
            if len(args) != 3:
                raise AssemblyError(f"{mnemonic} expects three operands")
            funct3 = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}[mnemonic]
            return [(b_type(expr.evaluate(args[2]) - pc, reg(args[1], line), reg(args[0], line), funct3), statement)]
        if mnemonic in ("lb", "lh", "lw", "lbu", "lhu"):
            if len(args) != 2:
                raise AssemblyError(f"{mnemonic} expects two operands")
            imm, rs1 = parse_mem(args[1], symbols, line)
            funct3 = {"lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5}[mnemonic]
            return [(i_type(imm, rs1, funct3, reg(args[0], line), 0x03), statement)]
        if mnemonic in ("sb", "sh", "sw"):
            if len(args) != 2:
                raise AssemblyError(f"{mnemonic} expects two operands")
            imm, rs1 = parse_mem(args[1], symbols, line)
            funct3 = {"sb": 0, "sh": 1, "sw": 2}[mnemonic]
            return [(s_type(imm, reg(args[0], line), rs1, funct3), statement)]
        if mnemonic in ("addi", "slti", "sltiu", "xori", "ori", "andi"):
            if len(args) != 3:
                raise AssemblyError(f"{mnemonic} expects three operands")
            funct3 = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}[mnemonic]
            return [(i_type(expr.evaluate(args[2]), reg(args[1], line), funct3, reg(args[0], line), 0x13), statement)]
        if mnemonic in ("slli", "srli", "srai"):
            if len(args) != 3:
                raise AssemblyError(f"{mnemonic} expects three operands")
            shamt = expr.evaluate(args[2])
            if not 0 <= shamt <= 31:
                raise AssemblyError(f"shift amount {shamt} is outside 0..31")
            funct3 = 1 if mnemonic == "slli" else 5
            funct7 = 0x20 if mnemonic == "srai" else 0
            return [(r_type(funct7, shamt, reg(args[1], line), funct3, reg(args[0], line), 0x13), statement)]
        if mnemonic in ("add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"):
            if len(args) != 3:
                raise AssemblyError(f"{mnemonic} expects three operands")
            funct3 = {"add": 0, "sub": 0, "sll": 1, "slt": 2, "sltu": 3, "xor": 4, "srl": 5, "sra": 5, "or": 6, "and": 7}[mnemonic]
            funct7 = 0x20 if mnemonic in ("sub", "sra") else 0
            return [(r_type(funct7, reg(args[2], line), reg(args[1], line), funct3, reg(args[0], line)), statement)]
        if mnemonic == "fence":
            return [(0x0000000F, statement)]
        if mnemonic == "ecall":
            return [(0x00000073, statement)]
        if mnemonic == "ebreak":
            return [(0x00100073, statement)]
    except AssemblyError as exc:
        raise fail(line, str(exc)) from exc
    if mnemonic not in BASE_INSTRUCTIONS:
        raise fail(line, f"unsupported instruction or pseudo {mnemonic!r}")
    raise fail(line, f"could not encode {statement!r}")


def split_labels(statement: str) -> tuple[list[str], str]:
    labels: list[str] = []
    rest = statement
    while True:
        match = re.match(r"^([A-Za-z_.$][\w.$]*):\s*(.*)$", rest)
        if not match:
            return labels, rest
        labels.append(match.group(1))
        rest = match.group(2).strip()


def assemble(lines: list[SourceLine]) -> tuple[list[Emitted], dict[str, int], dict[str, int]]:
    labels: dict[str, int] = {}
    constants: dict[str, int] = {}
    pc = 0
    parsed: list[tuple[SourceLine, str, int]] = []

    for line in lines:
        statement = clean(line.text)
        if not statement:
            continue
        new_labels, statement = split_labels(statement)
        for label in new_labels:
            if label in labels or label in constants:
                raise fail(line, f"duplicate symbol {label}")
            labels[label] = pc
        if not statement:
            continue
        if statement.startswith(".equ") or statement.startswith(".set"):
            _, _, body = statement.partition(" ")
            parts = operands(body)
            if len(parts) != 2:
                raise fail(line, ".equ expects name, expression")
            symbols = constants | labels
            if parts[0] in symbols:
                raise fail(line, f"duplicate symbol {parts[0]}")
            try:
                constants[parts[0]] = Expr(symbols).evaluate(parts[1])
            except AssemblyError as exc:
                raise fail(line, str(exc)) from exc
            continue
        if statement.startswith(".section") or statement in (".text", ".globl _start") or statement.startswith(".globl"):
            continue
        symbols = constants | labels
        if statement.startswith(".org"):
            try:
                pc = Expr(symbols).evaluate(statement.split(None, 1)[1])
            except AssemblyError as exc:
                raise fail(line, str(exc)) from exc
            if pc & 3:
                raise fail(line, ".org must be word aligned")
            continue
        if statement.startswith(".align"):
            power = Expr(symbols).evaluate(statement.split(None, 1)[1])
            alignment = 1 << power
            pc = (pc + alignment - 1) & -alignment
            continue
        if statement.startswith(".word"):
            parsed.append((line, statement, pc))
            pc += 4
            continue
        try:
            size = instruction_size(statement, symbols, line)
        except AssemblyError as exc:
            if str(exc).startswith(str(line.path)):
                raise
            raise fail(line, str(exc)) from exc
        parsed.append((line, statement, pc))
        pc += size

    if pc > IMEM_WORDS * 4:
        raise AssemblyError(f"program is {pc} bytes; instruction BRAM is {IMEM_WORDS * 4} bytes")

    all_symbols = constants | labels
    emitted: list[Emitted] = []
    for line, statement, address in parsed:
        if statement.startswith(".word"):
            try:
                word = Expr(all_symbols).evaluate(statement.split(None, 1)[1]) & 0xFFFFFFFF
            except AssemblyError as exc:
                raise fail(line, str(exc)) from exc
            emitted.append(Emitted(address, word, line, statement))
            continue
        words = encode(statement, address, all_symbols, line)
        for index, (word, expanded) in enumerate(words):
            emitted.append(Emitted(address + 4 * index, word & 0xFFFFFFFF, line, expanded))
    return emitted, labels, constants


def sext(value: int, bits: int) -> int:
    sign = 1 << (bits - 1)
    return (value ^ sign) - sign


def rname(number: int) -> str:
    return f"x{number}"


def decode(word: int, pc: int) -> tuple[str, str]:
    opcode = word & 0x7F
    rd = (word >> 7) & 0x1F
    funct3 = (word >> 12) & 7
    rs1 = (word >> 15) & 0x1F
    rs2 = (word >> 20) & 0x1F
    funct7 = (word >> 25) & 0x7F
    imm_i = sext(word >> 20, 12)
    if opcode == 0x37:
        return "lui", f"{rname(rd)}, 0x{word >> 12:05x}"
    if opcode == 0x17:
        return "auipc", f"{rname(rd)}, 0x{word >> 12:05x}"
    if opcode == 0x6F:
        imm = (((word >> 31) & 1) << 20) | (((word >> 12) & 0xFF) << 12) | (((word >> 20) & 1) << 11) | (((word >> 21) & 0x3FF) << 1)
        imm = sext(imm, 21)
        return "jal", f"{rname(rd)}, 0x{(pc + imm) & 0xffffffff:08x}"
    if opcode == 0x67 and funct3 == 0:
        return "jalr", f"{rname(rd)}, {imm_i}({rname(rs1)})"
    if opcode == 0x63 and funct3 in (0, 1, 4, 5, 6, 7):
        name = {0: "beq", 1: "bne", 4: "blt", 5: "bge", 6: "bltu", 7: "bgeu"}[funct3]
        imm = (((word >> 31) & 1) << 12) | (((word >> 7) & 1) << 11) | (((word >> 25) & 0x3F) << 5) | (((word >> 8) & 0xF) << 1)
        return name, f"{rname(rs1)}, {rname(rs2)}, 0x{(pc + sext(imm, 13)) & 0xffffffff:08x}"
    if opcode == 0x03 and funct3 in (0, 1, 2, 4, 5):
        name = {0: "lb", 1: "lh", 2: "lw", 4: "lbu", 5: "lhu"}[funct3]
        return name, f"{rname(rd)}, {imm_i}({rname(rs1)})"
    if opcode == 0x23 and funct3 in (0, 1, 2):
        name = {0: "sb", 1: "sh", 2: "sw"}[funct3]
        imm = sext(((word >> 25) << 5) | ((word >> 7) & 0x1F), 12)
        return name, f"{rname(rs2)}, {imm}({rname(rs1)})"
    if opcode == 0x13:
        if funct3 in (0, 2, 3, 4, 6, 7):
            name = {0: "addi", 2: "slti", 3: "sltiu", 4: "xori", 6: "ori", 7: "andi"}[funct3]
            return name, f"{rname(rd)}, {rname(rs1)}, {imm_i}"
        if funct3 == 1 and funct7 == 0:
            return "slli", f"{rname(rd)}, {rname(rs1)}, {rs2}"
        if funct3 == 5 and funct7 in (0, 0x20):
            return ("srai" if funct7 else "srli"), f"{rname(rd)}, {rname(rs1)}, {rs2}"
    if opcode == 0x33:
        table = {
            (0, 0): "add", (0, 0x20): "sub", (1, 0): "sll", (2, 0): "slt",
            (3, 0): "sltu", (4, 0): "xor", (5, 0): "srl", (5, 0x20): "sra",
            (6, 0): "or", (7, 0): "and",
        }
        name = table.get((funct3, funct7))
        if name:
            return name, f"{rname(rd)}, {rname(rs1)}, {rname(rs2)}"
    if opcode == 0x0F and funct3 == 0:
        return "fence", ""
    if word == 0x00000073:
        return "ecall", ""
    if word == 0x00100073:
        return "ebreak", ""
    raise AssemblyError(f"0x{pc:08x}: 0x{word:08x} is not one of the implemented 40 RV32I instructions")


def write_outputs(source: Path, output_dir: Path, emitted: list[Emitted], labels: dict[str, int], constants: dict[str, int]) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    if len({item.address for item in emitted}) != len(emitted):
        raise AssemblyError("overlapping output addresses")
    memory = [NOP] * IMEM_WORDS
    used: set[str] = set()
    disassembly: list[str] = []
    listing: list[str] = []
    for item in sorted(emitted, key=lambda value: value.address):
        if item.address & 3 or not 0 <= item.address < IMEM_WORDS * 4:
            raise AssemblyError(f"invalid output address 0x{item.address:x}")
        memory[item.address // 4] = item.word
        mnemonic, args = decode(item.word, item.address)
        if mnemonic not in BASE_INSTRUCTIONS:
            raise AssemblyError(f"internal validator rejected mnemonic {mnemonic}")
        used.add(mnemonic)
        disassembly.append(f"{item.address:08x}: {item.word:08x}  {mnemonic:<7} {args}".rstrip())
        location = f"{item.source.path.name}:{item.source.number}"
        listing.append(f"{item.address:08x}  {item.word:08x}  {item.expanded:<34} ; {location} | {clean(item.source.text)}")

    # Validate the entire physical image, not just source-emitted words.  The
    # remaining BRAM locations contain canonical ADDI x0,x0,0 instructions.
    for index, word in enumerate(memory):
        mnemonic, _ = decode(word, index * 4)
        if mnemonic not in BASE_INSTRUCTIONS:
            raise AssemblyError(f"internal validator rejected mnemonic {mnemonic}")
        used.add(mnemonic)

    hex_path = output_dir / "imem_game.hex"
    hex_path.write_text("".join(f"{word:08x}\n" for word in memory), encoding="ascii", newline="\n")
    (output_dir / "game.lst").write_text("\n".join(listing) + "\n", encoding="utf-8", newline="\n")
    (output_dir / "game.disasm").write_text("\n".join(disassembly) + "\n", encoding="utf-8", newline="\n")

    label_lines = ["RV32I game firmware symbol map", "", "[code labels]"]
    label_lines.extend(f"0x{value:08x} {name}" for name, value in sorted(labels.items(), key=lambda pair: (pair[1], pair[0])))
    label_lines.extend(("", "[constants]"))
    label_lines.extend(f"0x{value & 0xffffffff:08x} {name}" for name, value in sorted(constants.items()))
    (output_dir / "game.map").write_text("\n".join(label_lines) + "\n", encoding="utf-8", newline="\n")

    validation = [
        "PASS: all 4096 IMEM words decode as one of the CPU's 40 implemented RV32I instructions.",
        f"Program words: {len(emitted)}",
        f"Program bytes: {len(emitted) * 4}",
        f"Instruction BRAM: {IMEM_WORDS * 4} bytes",
        f"Highest used address: 0x{max((item.address for item in emitted), default=0):08x}",
        "Used base instructions: " + ", ".join(sorted(used)),
        "Forbidden extensions checked: no compressed, M, A, F, D, CSR, or privileged instruction encoding.",
    ]
    (output_dir / "rv32i_validation.txt").write_text("\n".join(validation) + "\n", encoding="utf-8", newline="\n")

    generated = ["imem_game.hex", "game.lst", "game.disasm", "game.map", "rv32i_validation.txt"]
    manifest = {
        "format": 1,
        "assembler": "firmware/rv32i_asm.py",
        "source": source.name,
        "imem_words": IMEM_WORDS,
        "program_words": len(emitted),
        "files": {},
    }
    for name in generated:
        data = (output_dir / name).read_bytes()
        manifest["files"][name] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    (output_dir / "build_manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output-dir", type=Path, default=Path("build"))
    args = parser.parse_args()
    try:
        lines = read_with_includes(args.source)
        emitted, labels, constants = assemble(lines)
        write_outputs(args.source, args.output_dir, emitted, labels, constants)
    except (AssemblyError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(f"assembled {len(emitted)} RV32I words -> {args.output_dir / 'imem_game.hex'}")
    print(f"validation PASS -> {args.output_dir / 'rv32i_validation.txt'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
