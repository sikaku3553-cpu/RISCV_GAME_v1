# RV32I命令coverage

## Coverageの定義

v2は，非特権RV32I基本命令セットの40命令をRTLで実装する。ここでの「実装」は，命令encodingを識別し，必要なoperand，immediate，Program Counter，memoryおよびwrite-back動作を生成することを示す。testbenchのPASS，FPGA合成，配置配線およびofficial compliance testの完了を同じ意味にはしない。

命令数の内訳は，上位即値2，jump 2，branch 6，load 5，store 3，即値ALU 9，Register ALU 10，memory ordering 1，environment call 2の合計40である。

## 40命令一覧

| No. | 分類 | 命令 | 主な実装動作 | RTL対応 |
|---:|---|---|---|:---:|
| 1 | U | `LUI` | U-immediateを`rd`へ書込む | Yes |
| 2 | U | `AUIPC` | `PC + U-immediate`を`rd`へ書込む | Yes |
| 3 | J | `JAL` | `PC+4`を`rd`へ書き，PC-relative jump | Yes |
| 4 | J | `JALR` | `PC+4`を書き，`(rs1+imm)&~1`へjump | Yes |
| 5 | B | `BEQ` | equalならPC-relative branch | Yes |
| 6 | B | `BNE` | not equalならPC-relative branch | Yes |
| 7 | B | `BLT` | signed less-thanならbranch | Yes |
| 8 | B | `BGE` | signed greater-or-equalならbranch | Yes |
| 9 | B | `BLTU` | unsigned less-thanならbranch | Yes |
| 10 | B | `BGEU` | unsigned greater-or-equalならbranch | Yes |
| 11 | I/load | `LB` | byte load後にbit 7を符号拡張 | Yes |
| 12 | I/load | `LH` | halfword load後にbit 15を符号拡張 | Yes |
| 13 | I/load | `LW` | aligned 32bit load | Yes |
| 14 | I/load | `LBU` | byte load後にzero拡張 | Yes |
| 15 | I/load | `LHU` | halfword load後にzero拡張 | Yes |
| 16 | S | `SB` | selected byte laneだけを書換え | Yes |
| 17 | S | `SH` | selected two byte lanesを書換え | Yes |
| 18 | S | `SW` | aligned 4 byte laneを書換え | Yes |
| 19 | I/ALU | `ADDI` | `rs1 + sign-extended immediate` | Yes |
| 20 | I/ALU | `SLTI` | signed comparison結果を0/1で書込む | Yes |
| 21 | I/ALU | `SLTIU` | unsigned comparison結果を0/1で書込む | Yes |
| 22 | I/ALU | `XORI` | immediate XOR | Yes |
| 23 | I/ALU | `ORI` | immediate OR | Yes |
| 24 | I/ALU | `ANDI` | immediate AND | Yes |
| 25 | I/shift | `SLLI` | shamt[4:0]による左shift | Yes |
| 26 | I/shift | `SRLI` | shamt[4:0]による論理右shift | Yes |
| 27 | I/shift | `SRAI` | shamt[4:0]による算術右shift | Yes |
| 28 | R | `ADD` | Register加算 | Yes |
| 29 | R | `SUB` | Register減算 | Yes |
| 30 | R | `SLL` | `rs2[4:0]`による左shift | Yes |
| 31 | R | `SLT` | signed comparison | Yes |
| 32 | R | `SLTU` | unsigned comparison | Yes |
| 33 | R | `XOR` | Register XOR | Yes |
| 34 | R | `SRL` | `rs2[4:0]`による論理右shift | Yes |
| 35 | R | `SRA` | `rs2[4:0]`による算術右shift | Yes |
| 36 | R | `OR` | Register OR | Yes |
| 37 | R | `AND` | Register AND | Yes |
| 38 | MISC-MEM | `FENCE` | single-hart ordered systemではno-opとしてretire | Yes |
| 39 | SYSTEM | `ECALL` | legal decode後，cause 11のfatal indication | Yes |
| 40 | SYSTEM | `EBREAK` | legal decode後，cause 3のfatal indication | Yes |

## 命令分類ごとの確認点

### Uおよびjump

- `LUI`は下位12bitを0とし，instruction bit 31:12を保持する。
- `AUIPC`は当該命令のPCを基準に加算する。
- `JAL`および`JALR`のlink値はtargetではなく`PC+4`である。
- `JALR`は加算結果のbit 0を0にする。compressed instruction非対応のため，その後もbit 1が1ならinstruction-address-misalignedとなる。
- `rd=x0`のjumpではlink writeを抑止するが，jump自体は実行する。

### Branch

- signedの`BLT`／`BGE`とunsignedの`BLTU`／`BGEU`を，MSBが異なるoperandで対にして確認する。
- takenとnot-takenをそれぞれ確認する。
- 非整列targetのfaultはtaken時だけ発生する。
- branch instruction自身はRegister Fileやmemoryを書き換えない。

### Load／Store

- RAMの全4 byte laneについて`SB`後の非対象lane保持を確認する。
- address offset 0と2について`SH`を確認し，offset 1と3はmisalignedとする。
- `LB`／`LH`は負値を符号拡張し，`LBU`／`LHU`はzero拡張する。
- `LW`／`SW`は4 byte alignmentのみを許可する。
- RAM末尾ではbyte address `0xff`，halfword address `0xfe`，word address `0xfc`までを許可する。
- MMIOは`0x100`と`0x104`のexact-address word accessだけを許可し，subword MMIOはaccess faultとする。

### ALU

- shift量はimmediateまたは`rs2`の下位5bitだけを使用する。
- `SRL`／`SRLI`は0 fill，`SRA`／`SRAI`はsign fillである。
- `SLT`／`SLTI`と`SLTU`／`SLTIU`を負数operandで対にして確認する。
- overflowはtrapにせず，結果の下位32bitを使用する。
- `x0`をsourceとdestinationの双方で確認し，destination writeが無視されることを確認する。

### FENCEおよびSYSTEM

- `FENCE`はlegalであり，Program Counterを4進める以外のarchitectural stateを変更しない。
- `FENCE.I`はZifenceiであるためillegalとする。
- `ECALL`と`EBREAK`はillegal instructionではなく，それぞれ専用causeを出す。
- trap vectorを持たないため，`ECALL`と`EBREAK`はretireせず，resetまでfatal indicationを継続する。

## Strict decodeの対象

次のreservedまたは未実装encodingは`legal=0`とし，cause 2を出す。

- 定義されていないopcodeまたは`funct3`。
- R-typeで許可されていない`funct7`。
- shift-immediateで許可されていない上位bit pattern。
- `JALR`で`funct3 != 000`。
- LOAD／STORE／BRANCHでRV32Iに定義されていない`funct3`。
- MISC-MEMの`FENCE.I`および未対応encoding。
- `ECALL`と`EBREAK`以外のSYSTEM encoding。

illegal instructionをEX段で検出すると若い命令をflushし，illegal命令自身はretireせずside effectも発生しない。すでにMEM/WB段にある古い命令だけを完了した後，faultを確定する。board topのretire indicator（`clk_ind`）は実際にretireした古い命令だけを数える。

## 対象外extension

| 対象外 | 例 | v2での扱い |
|---|---|---|
| Zicsr | `CSRRW`, `CSRRS`, `CSRRC`と即値形 | illegal instruction |
| Zifencei | `FENCE.I` | illegal instruction |
| M | `MUL`, `DIV`, `REM` | illegal instruction |
| A | `LR`, `SC`, AMO | illegal instruction |
| F/D/Q | 浮動小数点命令 | illegal instruction |
| C | 16bit compressed instruction | 非対応，4 byte alignmentを要求 |
| B/V等 | bit manipulation，vector | illegal instruction |
| privileged architecture | CSR，trap return，page table等 | 実装なし |

RV32E，RV64IおよびRV128Iもv2の対象ではない。v2の`XLEN`は32，Register Fileは`x0`～`x31`の32本である。

## 実行環境による制約

- Board configurationのInstruction Memoryは64×32bitである。
- Data RAMは256 byteである。
- `IO_IN=0x100`，`IO_OUT=0x104`だけを実装する。
- misaligned load/storeのemulationは行わず，synchronous faultにする。
- interrupt，privilege mode，CSR，trap handlerは実装しない。
- `debug_trap_cause`と`debug_trap_value`は観測用portであり，architectural CSRではない。
- `FENCE`はcache，DMA，other hartを持たないstrictly ordered systemでno-opとする。

これらは実装platformの制約であり，40命令のencoding coverageとは分けて評価する。

## 検証記録の付け方

RTL対応表の`Yes`だけをもって検証完了とはしない。最終的なv2検証記録では，次の結果を別々に残す。

| 検証層 | 記録する内容 |
|---|---|
| Parse / elaboration | 使用tool/version，error数，warning数 |
| Unit simulation | 40命令，境界値，illegal encoding，fault side effect |
| Pipeline simulation | forwarding，load-use stall，control flush，precise trap，reset flush |
| Integration simulation | 既定ROM，MMIO，board wrapper，clock enable，retire count |
| Synthesis check | latch，multi-driver，undriven，memory inference |
| Vivado fresh route | LUT，FF，LUTRAM，BRAM，WNS，TNS，WHS |
| External compliance | 使用したsuite名，version，除外testと理由 |

official compliance suiteまたはriscv-formalを実行していない段階では，「40命令をRTL実装し，project testbenchで検証した」と記述し，「RISC-V certificationを取得した」または「全実装に対する形式的完全性を証明した」とは記述しない。
