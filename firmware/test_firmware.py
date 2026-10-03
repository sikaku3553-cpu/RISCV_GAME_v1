#!/usr/bin/env python3
"""Behavioral smoke test for the generated RV32I game ROM.

The interpreter is deliberately limited to the implemented RV32I integer
encodings.  It is not a timing model of the pipeline; it proves that the ROM
boots and that representative CPU-owned game transitions reach the documented
RAM/MMIO locations without relying on a host RISC-V toolchain.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


SYS_INPUT_LEVEL = 0x1004
SYS_FRAME_COUNT = 0x100C
VGA_SCROLL_X = 0x1104
VGA_FRAME_COMMIT = 0x110C
VGA_HUD_SCORE = 0x1114
VGA_HUD_TIME = 0x1118
VGA_GAME_STATUS = 0x111C
SPRITE_BASE = 0x1200
TILEMAP_BASE = 0x2000
DATA_BASE = 0x4000

ST_PLAYER_X = 0x00
ST_PLAYER_Y = 0x04
ST_PLAYER_VX = 0x08
ST_PLAYER_VY = 0x0C
ST_GROUNDED = 0x10
ST_PREV_INPUT = 0x14
ST_GAME_STATE = 0x18
ST_CAMERA_X = 0x1C
ST_SCORE = 0x20
ST_TIME = 0x24
ST_LIVES = 0x38
ENEMY0_X = 0x50
ENEMY0_Y = 0x54
ENEMY0_DIR = 0x58
ENEMY0_ACTIVE = 0x5C

INPUT_RIGHT = 0x02
INPUT_JUMP = 0x04
INPUT_ACTION = 0x10


def u32(value: int) -> int:
    return value & 0xFFFFFFFF


def signed(value: int, bits: int = 32) -> int:
    value &= (1 << bits) - 1
    sign = 1 << (bits - 1)
    return (value ^ sign) - sign


class RV32I:
    def __init__(self, words: list[int]):
        self.words = words
        self.reg = [0] * 32
        self.pc = 0
        self.data = bytearray(0x8000)
        self.mmio: dict[int, int] = {SYS_INPUT_LEVEL: 0, SYS_FRAME_COUNT: 0}
        self.steps = 0
        self.commits = 0

    def load8(self, address: int) -> int:
        if 0 <= address < len(self.data):
            return self.data[address]
        raise AssertionError(f"unmapped byte load 0x{address:08x}")

    def load16(self, address: int) -> int:
        return self.load8(address) | (self.load8(address + 1) << 8)

    def load32(self, address: int) -> int:
        if address in self.mmio:
            return self.mmio[address]
        if 0 <= address <= len(self.data) - 4:
            return int.from_bytes(self.data[address:address + 4], "little")
        raise AssertionError(f"unmapped word load 0x{address:08x}")

    def store8(self, address: int, value: int) -> None:
        if not 0 <= address < len(self.data):
            raise AssertionError(f"unmapped byte store 0x{address:08x}")
        self.data[address] = value & 0xFF

    def store16(self, address: int, value: int) -> None:
        self.store8(address, value)
        self.store8(address + 1, value >> 8)

    def store32(self, address: int, value: int) -> None:
        value = u32(value)
        if 0x1000 <= address <= 0x12FF:
            self.mmio[address] = value
            if address == VGA_FRAME_COMMIT and value & 1:
                self.commits += 1
            return
        if not 0 <= address <= len(self.data) - 4:
            raise AssertionError(f"unmapped word store 0x{address:08x}")
        self.data[address:address + 4] = value.to_bytes(4, "little")

    def set_reg(self, index: int, value: int) -> None:
        if index:
            self.reg[index] = u32(value)

    def step(self) -> None:
        assert self.pc & 3 == 0, f"unaligned PC 0x{self.pc:08x}"
        assert 0 <= self.pc // 4 < len(self.words), f"PC outside IMEM: 0x{self.pc:08x}"
        word = self.words[self.pc // 4]
        old_pc = self.pc
        next_pc = u32(old_pc + 4)
        opcode = word & 0x7F
        rd = (word >> 7) & 31
        funct3 = (word >> 12) & 7
        rs1 = (word >> 15) & 31
        rs2 = (word >> 20) & 31
        funct7 = (word >> 25) & 0x7F
        a, b = self.reg[rs1], self.reg[rs2]
        imm_i = signed(word >> 20, 12)

        if opcode == 0x37:  # LUI
            self.set_reg(rd, word & 0xFFFFF000)
        elif opcode == 0x17:  # AUIPC
            self.set_reg(rd, old_pc + (word & 0xFFFFF000))
        elif opcode == 0x6F:  # JAL
            imm = (((word >> 31) & 1) << 20) | (((word >> 12) & 0xFF) << 12) | (((word >> 20) & 1) << 11) | (((word >> 21) & 0x3FF) << 1)
            self.set_reg(rd, next_pc)
            next_pc = u32(old_pc + signed(imm, 21))
        elif opcode == 0x67 and funct3 == 0:  # JALR
            target = u32(a + imm_i) & ~1
            self.set_reg(rd, next_pc)
            next_pc = target
        elif opcode == 0x63:  # branches
            imm = (((word >> 31) & 1) << 12) | (((word >> 7) & 1) << 11) | (((word >> 25) & 0x3F) << 5) | (((word >> 8) & 0xF) << 1)
            conditions = {
                0: a == b,
                1: a != b,
                4: signed(a) < signed(b),
                5: signed(a) >= signed(b),
                6: a < b,
                7: a >= b,
            }
            assert funct3 in conditions, f"illegal branch funct3 {funct3}"
            if conditions[funct3]:
                next_pc = u32(old_pc + signed(imm, 13))
        elif opcode == 0x03:  # loads
            address = u32(a + imm_i)
            if funct3 == 0:
                value = signed(self.load8(address), 8)
            elif funct3 == 1:
                value = signed(self.load16(address), 16)
            elif funct3 == 2:
                value = self.load32(address)
            elif funct3 == 4:
                value = self.load8(address)
            elif funct3 == 5:
                value = self.load16(address)
            else:
                raise AssertionError(f"illegal load funct3 {funct3}")
            self.set_reg(rd, value)
        elif opcode == 0x23:  # stores
            imm = signed(((word >> 25) << 5) | ((word >> 7) & 31), 12)
            address = u32(a + imm)
            if funct3 == 0:
                self.store8(address, b)
            elif funct3 == 1:
                self.store16(address, b)
            elif funct3 == 2:
                self.store32(address, b)
            else:
                raise AssertionError(f"illegal store funct3 {funct3}")
        elif opcode == 0x13:  # immediate ALU
            if funct3 == 0:
                value = a + imm_i
            elif funct3 == 2:
                value = int(signed(a) < imm_i)
            elif funct3 == 3:
                value = int(a < u32(imm_i))
            elif funct3 == 4:
                value = a ^ u32(imm_i)
            elif funct3 == 6:
                value = a | u32(imm_i)
            elif funct3 == 7:
                value = a & u32(imm_i)
            elif funct3 == 1 and funct7 == 0:
                value = a << rs2
            elif funct3 == 5 and funct7 == 0:
                value = a >> rs2
            elif funct3 == 5 and funct7 == 0x20:
                value = signed(a) >> rs2
            else:
                raise AssertionError(f"illegal OP-IMM 0x{word:08x}")
            self.set_reg(rd, value)
        elif opcode == 0x33:  # register ALU
            key = (funct3, funct7)
            operations = {
                (0, 0): lambda: a + b,
                (0, 0x20): lambda: a - b,
                (1, 0): lambda: a << (b & 31),
                (2, 0): lambda: int(signed(a) < signed(b)),
                (3, 0): lambda: int(a < b),
                (4, 0): lambda: a ^ b,
                (5, 0): lambda: a >> (b & 31),
                (5, 0x20): lambda: signed(a) >> (b & 31),
                (6, 0): lambda: a | b,
                (7, 0): lambda: a & b,
            }
            assert key in operations, f"illegal OP 0x{word:08x}"
            self.set_reg(rd, operations[key]())
        elif opcode == 0x0F and funct3 == 0:  # FENCE
            pass
        elif word in (0x00000073, 0x00100073):
            raise AssertionError("firmware unexpectedly executed ECALL/EBREAK")
        else:
            raise AssertionError(f"illegal instruction 0x{word:08x} at 0x{old_pc:08x}")

        self.pc = next_pc
        self.reg[0] = 0
        self.steps += 1

    def run_until_pc(self, target: int, maximum: int) -> None:
        for _ in range(maximum):
            self.step()
            if self.pc == target:
                return
        raise AssertionError(f"did not reach PC 0x{target:08x} in {maximum} instructions")

    def run_frame(self, frame_wait: int, inputs: int = 0) -> None:
        assert self.pc == frame_wait
        self.mmio[SYS_INPUT_LEVEL] = inputs
        self.mmio[SYS_FRAME_COUNT] = u32(self.mmio[SYS_FRAME_COUNT] + 1)
        self.step()
        self.run_until_pc(frame_wait, 10000)

    def state(self, offset: int) -> int:
        return self.load32(DATA_BASE + offset)

    def set_state(self, offset: int, value: int) -> None:
        self.store32(DATA_BASE + offset, value)


def load_labels(path: Path) -> dict[str, int]:
    labels: dict[str, int] = {}
    in_labels = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line == "[code labels]":
            in_labels = True
            continue
        if line.startswith("["):
            in_labels = False
        if in_labels and line.startswith("0x"):
            address, name = line.split(maxsplit=1)
            labels[name] = int(address, 16)
    return labels


def run_test(build: Path) -> list[str]:
    words = [int(line, 16) for line in (build / "imem_game.hex").read_text(encoding="ascii").splitlines()]
    labels = load_labels(build / "game.map")
    frame_wait = labels["frame_wait"]
    cpu = RV32I(words)
    cpu.run_until_pc(frame_wait, 100000)
    results: list[str] = []

    # Boot/reset and CPU-authored level map.
    assert cpu.state(ST_PLAYER_X) == 32
    assert cpu.state(ST_PLAYER_Y) == 193
    assert cpu.state(ST_GAME_STATE) == 0
    assert cpu.state(ST_TIME) == 300
    assert cpu.data[TILEMAP_BASE + (13 << 8) + 0] == 0x41
    assert cpu.data[TILEMAP_BASE + (13 << 8) + 20] == 0x00
    assert cpu.data[TILEMAP_BASE + (10 << 8) + 28] == 0x46
    assert cpu.data[TILEMAP_BASE + (12 << 8) + 58] == 0x90
    assert cpu.data[TILEMAP_BASE + (5 << 8) + 90] == 0xCB
    assert cpu.mmio[SPRITE_BASE + 4] & 1
    assert cpu.mmio[SPRITE_BASE + (4 * 16) + 4] == (43 << 8) | 1
    for slot in range(5, 16):
        assert cpu.mmio[SPRITE_BASE + (slot * 16) + 4] == 0
    assert cpu.mmio[VGA_HUD_TIME] == 300
    assert cpu.commits == 1
    results.append("PASS boot, tilemap, all 16 shadow sprite slots, first vblank commit request")

    # With no new frame, the poll loop cannot mutate game state.
    snapshot = bytes(cpu.data[DATA_BASE:DATA_BASE + 0x98])
    commit_snapshot = cpu.commits
    for _ in range(500):
        cpu.step()
    assert cpu.pc == frame_wait or labels["frame_wait"] <= cpu.pc < labels["frame_nonplay"]
    assert bytes(cpu.data[DATA_BASE:DATA_BASE + 0x98]) == snapshot
    assert cpu.commits == commit_snapshot
    while cpu.pc != frame_wait:
        cpu.step()
    results.append("PASS frame polling holds all CPU-owned game state between frames")

    # Movement and rising-edge jump.
    for _ in range(8):
        cpu.run_frame(frame_wait, INPUT_RIGHT)
    assert cpu.state(ST_PLAYER_X) > 32
    assert cpu.state(ENEMY0_X) < 288
    y_before = cpu.state(ST_PLAYER_Y)
    cpu.run_frame(frame_wait, INPUT_RIGHT | INPUT_JUMP)
    assert signed(cpu.state(ST_PLAYER_VY)) < 0
    assert cpu.state(ST_PLAYER_Y) < y_before
    assert (cpu.mmio[VGA_GAME_STATUS] >> 8) & 0xFF == 34
    results.append("PASS player acceleration/jump/animation and CPU-driven enemy movement")

    # Arrange a descending overlap to exercise software stomp/score logic.
    cpu.set_state(ST_PLAYER_X, 100)
    cpu.set_state(ST_PLAYER_Y, 180)
    cpu.set_state(ST_PLAYER_VX, 0)
    cpu.set_state(ST_PLAYER_VY, 2)
    cpu.set_state(ST_GROUNDED, 0)
    cpu.set_state(ST_PREV_INPUT, 0)
    cpu.set_state(ENEMY0_X, 100)
    cpu.set_state(ENEMY0_Y, 193)
    cpu.set_state(ENEMY0_DIR, 1)
    cpu.set_state(ENEMY0_ACTIVE, 1)
    score_before_stomp = cpu.state(ST_SCORE)
    cpu.run_frame(frame_wait, 0)
    assert cpu.state(ENEMY0_ACTIVE) == 0
    assert signed(cpu.state(ST_PLAYER_VY)) == -5
    assert cpu.state(ST_SCORE) == score_before_stomp + 100
    results.append("PASS software enemy overlap, stomp, bounce, and score update")

    # Camera follows software state and reaches the shadow scroll register.
    cpu.set_state(ST_PLAYER_X, 400)
    cpu.set_state(ST_PLAYER_Y, 193)
    cpu.set_state(ST_PLAYER_VX, 0)
    cpu.set_state(ST_PLAYER_VY, 0)
    cpu.set_state(ST_GROUNDED, 1)
    cpu.set_state(ST_PREV_INPUT, 0)
    cpu.run_frame(frame_wait, 0)
    assert cpu.state(ST_CAMERA_X) == 304
    assert cpu.mmio[VGA_SCROLL_X] == 304
    results.append("PASS camera follow/clamp and VGA shadow scroll write")

    # Sixty observed frame changes, independent of CPU speed, are one second.
    time_before = cpu.state(ST_TIME)
    for _ in range(60):
        cpu.run_frame(frame_wait, 0)
    assert cpu.state(ST_TIME) == time_before - 1
    assert cpu.mmio[VGA_HUD_TIME] == time_before - 1
    results.append("PASS deterministic 60-frame countdown and HUD time write")

    # Drop the player into the first pit; software enters death and spends life.
    cpu.set_state(ST_PLAYER_X, 330)
    cpu.set_state(ST_PLAYER_Y, 230)
    cpu.set_state(ST_PLAYER_VX, 0)
    cpu.set_state(ST_PLAYER_VY, 6)
    cpu.set_state(ST_GROUNDED, 0)
    cpu.set_state(ST_GAME_STATE, 0)
    cpu.set_state(ST_PREV_INPUT, 0)
    lives_before = cpu.state(ST_LIVES)
    cpu.run_frame(frame_wait, 0)
    cpu.run_frame(frame_wait, 0)
    assert cpu.state(ST_GAME_STATE) == 1
    assert cpu.state(ST_LIVES) == lives_before - 1
    assert cpu.mmio[VGA_GAME_STATUS] & 0xFF == 1
    results.append("PASS pit detection, death state, life decrement, HUD status write")

    # Restart is edge-triggered and preserves remaining lives.
    remaining_lives = cpu.state(ST_LIVES)
    cpu.run_frame(frame_wait, INPUT_ACTION)
    assert cpu.state(ST_GAME_STATE) == 0
    assert cpu.state(ST_PLAYER_X) == 32
    assert cpu.state(ST_LIVES) == remaining_lives
    results.append("PASS action-edge restart")

    # Place the player just left of the CPU-authored special goal tiles.
    cpu.set_state(ST_PLAYER_X, 1428)
    cpu.set_state(ST_PLAYER_Y, 193)
    cpu.set_state(ST_PLAYER_VX, 3)
    cpu.set_state(ST_PLAYER_VY, 0)
    cpu.set_state(ST_GROUNDED, 1)
    cpu.set_state(ST_PREV_INPUT, 0)
    cpu.set_state(ST_GAME_STATE, 0)
    score_before = cpu.state(ST_SCORE)
    cpu.run_frame(frame_wait, INPUT_RIGHT)
    assert cpu.state(ST_GAME_STATE) == 2
    assert cpu.state(ST_SCORE) == score_before + 1000
    assert cpu.mmio[VGA_HUD_SCORE] == score_before + 1000
    assert cpu.mmio[VGA_GAME_STATUS] & 0xFF == 2
    results.append("PASS goal-tile collision, win transition, score/HUD write")

    results.append(f"PASS executed {cpu.steps} RV32I instructions with no illegal/unmapped access")
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=Path(__file__).parent / "build")
    args = parser.parse_args()
    results = run_test(args.build_dir)
    report = "\n".join(results) + "\n"
    report_path = args.build_dir / "integration_test.txt"
    report_path.write_text(report, encoding="utf-8", newline="\n")

    # The assembler creates the manifest before this behavioral test runs.
    # Extend that manifest here so every checked-in build result is covered by
    # the same deterministic size/hash record.
    manifest_path = args.build_dir / "build_manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    report_data = report_path.read_bytes()
    manifest["files"][report_path.name] = {
        "bytes": len(report_data),
        "sha256": hashlib.sha256(report_data).hexdigest(),
    }
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print(report, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
