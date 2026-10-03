# RV32I side-scroller firmware

This directory contains an original, CPU-driven educational side-scroller for
the v3.1 game platform.  It uses no Nintendo ROM, map, graphic, music, or code
data.  The recognizable genre elements (ground, pits, blocks, pipes, stairs,
walking enemies, and a goal) are constructed from project-created tile IDs.

The firmware is hand-written RV32I assembly.  Every player/enemy position,
velocity, collision decision, death, restart, score, timer, animation, camera,
and win transition occurs in `game.S`.  VGA hardware is only a renderer.  If
the CPU is paused, the VGA timing continues but game state and sprite
descriptors do not advance.

## Reproducible build

From the repository root on Windows:

```powershell
powershell -ExecutionPolicy Bypass -File firmware/build.ps1
```

`rv32i_asm.py` is a dependency-free two-pass assembler, so a GNU RISC-V
toolchain is not required.  Its final step decodes every emitted word and
rejects any encoding outside the 40 instructions implemented by
`DecoderV2.v`.  It also rejects an image larger than the 16 KiB instruction
BRAM.  The checked-in outputs are:

- `build/imem_game.hex`: 4096 little-endian CPU words in `$readmemh` text
  form; unused words are canonical `addi x0,x0,0` NOPs.
- `build/game.lst`: source-correlated assembler listing.
- `build/game.disasm`: independent decode of emitted machine words.
- `build/game.map`: code labels and constants.
- `build/rv32i_validation.txt`: instruction-set and capacity result.
- `build/integration_test.txt`: ROM-execution behavior-test result.  This is
  produced after assembly and is not currently included in the manifest.
- `build/build_manifest.json`: deterministic sizes and SHA-256 hashes for the
  five assembler-produced artifacts (`imem_game.hex`, listing, disassembly,
  map, and ISA/capacity validation report).

No data-memory initialization file is needed.  Reset code initializes all
state in `0x4000-0x7fff` and constructs the collision/render tilemap through
byte stores to `0x2000-0x2fff`.

## Frame algorithm and controls

The CPU runs at full platform speed and polls `SYS_FRAME_COUNT`.  Exactly one
update is executed for each newly observed frame value:

1. sample synchronized/debounced input and derive rising edges;
2. apply horizontal acceleration/friction and edge-triggered jump;
3. apply gravity and resolve horizontal/vertical tile collisions;
4. update all enemy movement, ledge/wall checks, overlap, and stomps;
5. process hazards, pits, countdown, death/restart, and goal state;
6. choose animation and clamped camera position;
7. write the complete shadow display state and request a vblank commit.

Logical input bits are left=`0x01`, right=`0x02`, jump/up=`0x04`,
down=`0x08`, and action/start=`0x10`.  Action or jump restarts after death;
it starts a new game after winning.

## Firmware-visible memory map

| Address/range | Access | Firmware use |
|---|---|---|
| `0x0000-0x3fff` | fetch | 16 KiB instruction BRAM |
| `0x1000` | R | synchronized switches |
| `0x1004` | R | logical button/keyboard level bitmap |
| `0x1008` | R/W1C | latched input rising edges (diagnostic) |
| `0x100c` | R | VGA frame counter polled by the game loop |
| `0x1010` | R | 100 MHz timer low word |
| `0x1014/18` | R | live cycle low word / reserved zero high word |
| `0x101c/20` | R | live instret low word / reserved zero high word |
| `0x1024/28` | R | live stall low word / reserved zero high word |
| `0x102c/30` | R | live flush low word / reserved zero high word |
| `0x1034/38` | R | reserved memory-wait low/high; both currently read zero |
| `0x103c` | R/W | reserved counter control; reads zero and writes have no effect |
| `0x1040` | R/W | debug LEDs |
| `0x1044` | R | PS/2 byte/status |
| `0x1100` | R | active/vblank/commit status |
| `0x1104` | R/W shadow | camera X in logical pixels |
| `0x1108` | R/W shadow | RGB444 backdrop |
| `0x110c` | R/W | read returns pending in bit 0; writing bit 0 requests a vblank commit |
| `0x1110` | R/W | layer enables/debug control |
| `0x1114` | R/W shadow | HUD score |
| `0x1118` | R/W shadow | HUD remaining time in seconds |
| `0x111c` | R/W shadow | state `[7:0]`, animation `[15:8]`, lives `[23:16]` |
| `0x1200-0x12ff` | R/W shadow | sixteen 16-byte sprite descriptors |
| `0x2000-0x2fff` | R/W | 256x16 byte tile/collision map |
| `0x4000-0x7fff` | R/W | 16 KiB game data RAM; stack begins at `0x8000` |

A sprite descriptor contains packed signed `x/y` at `+0`, attributes at
`+4`, an animation/debug tag at `+8`, and zero/reserved at `+12`; the reserved
word reads as zero and a write to it raises an access fault.  Attribute
bit 0 enables the sprite, bits 1/2 flip it, bits 5:4 are priority, and bits
13:8 select one of 64 tiles.  The tilemap byte uses graphic ID `[5:0]` and
collision class `[7:6]`: empty, solid, hazard, or goal/special.

The register aperture provides sixteen descriptors.  The current renderer
composites active slots 0 through 4; slots 5 through 15 remain software-visible
shadow/active storage reserved for a later renderer expansion.

`platform.inc` is the assembly contract and `platform.h` is an exact C-facing
mirror for RTL integration tests or future freestanding C code.
