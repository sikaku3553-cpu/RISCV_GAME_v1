# v1.1からv2への移行記録

## 1. 目的と版の定義

v2は，TD8由来の基板入出力とv1.1の分散RAM向け資源構造を維持しながら，対応命令をRV32Iサブセット12命令から非特権RV32I基本命令セットの40命令へ拡張し，IF／ID／EX／MEM／WBの5段pipelineへ移行した版である。本資料でいう「RV32I完全実装」は，後述する小規模な実行環境の中で，RV32I基本命令40命令のデコードと命令動作を実装したことを意味する。RISC-Vの全拡張，特権アーキテクチャ，OSを実行できる完全なplatformまでを意味しない。

移行の基準は次のcommitに固定する。

| 用途 | repository / branch | commit |
|---|---|---|
| v1.1移行元 | `Gitratter/TD8_To_RISCV_v1.1` / `main` | `27bebc9847ef0f8d192b80ecb6754cc1005dde61` |

v2の比較では，移行元commitのRTL，testbench，Vivado制約および実測reportを混在させない。特に，旧v1またはv1.1の既存`impl_1`を開いて生成したreportをv2の結果として使用してはならない。

## 2. v1.1から継承する資源最適化

v1では，DataMemoryの4個の64×8bit配列と，全要素をresetするRegister Fileが分散RAMとして推論されなかった。その結果，配置配線後にDataMemoryが2048 FF，Register Fileが480 FFを使用した。v1.1では，命令セットと実行cycleを変えず，DataMemoryを単一の64×32bit配列へ統合し，Register Fileの配列resetを廃止して32bitの有効bit列だけをresetする構成へ変更した。

v1.1のVivado 2025.2，`xc7a35tcpg236-1`，10 ns制約によるfresh route実測は次のとおりである。

| 項目 | v1 | v1.1 | 変化 |
|---|---:|---:|---:|
| Slice LUT | 1438 | 702 | -736（-51.18%） |
| Slice FF | 2649 | 126 | -2523（-95.24%） |
| LUTRAM | 0 | 76 | +76 |
| Block RAM | 0 | 0 | 0 |
| WNS | -4.936 ns | -4.262 ns | +0.674 ns |
| TNS | -13377.653 ns | -1069.005 ns | +12308.648 ns |

v1.1ではDataMemoryが`RAM64X1S` 32個，Register Fileが`RAM32M` 10個と`RAM32X1D` 4個へ写像された。これらはv1.1の実測値であり，v2の実測値ではない。v2は以下の構造を継承する。

- DataMemoryは1個の64×32bit配列とし，配列全体をresetしない。
- Register Fileは2 read portを得るため同内容の分散RAMを2個持ち，同時に書き込む。
- Register Fileのデータ配列をresetせず，32bitの`valid`だけをresetする。
- `x0`は配列内容や`valid`にかかわらず常に0を読み，`x0`への書込みを抑止する。
- 合成用トップではRegister FileとDataMemoryの追加debug read portを無効化する。
- DataMemoryのreadは非同期のままとし，MEM段でload dataを生成する。

一方，v2では`SB`と`SH`のためにDataMemoryへ4bitのbyte write strobeを追加した。この変更後も同じLUTRAM primitiveへ推論されるかは，v2をfresh synthesisおよびfresh routeして再確認する必要がある。

## 3. CPU構成とpipeline化

v2でも次の構成は変更しない。

- FPGA入力clockは100 MHzであり，1 Hzまたは10 Hzのclock-enable pulseを選択する。内部に別の低速clock domainは作らない。
- IF／ID／EX／MEM／WBの5段in-order pipelineであり，定常時は1回の`cpu_enable`で最大1命令をretireする。
- `cpu_enable=0`ではProgram Counterを含む全pipeline段とarchitectural stateを保持する。
- EX/MEMおよびMEM/WBからEX段へforwardingし，WB書込みと同cycleのID読出しには明示的なWB-to-ID bypassを行う。
- load-use hazardではProgram CounterとIF/IDを保持し，ID/EXへ1 bubbleを挿入する。
- branch，JALおよびJALRはEX段で解決し，taken時にIF/IDとID/EXをflushする。
- `TD4_TOP`の`clk`，`reset`，`in`，`clksel`，`out`，`clk_ind`，`seg`，`an`を維持する。
- Program Counter，命令，データ，Register Fileは32bitである。
- 命令ROMとData RAMを分離したHarvard構成である。
- resetはactive-high asynchronous resetである。ただし，分散RAM配列そのものはresetしない。
- `clk_ind`はProgram Counterではなく，faultなしでretireした命令数の下位4bitを示す。
- 7セグメントLEDは`out[3:0]`を右端1桁にactive-lowで表示する。

したがって，v1.1とv2の性能差や資源差には，命令デコード，ALU機能，分岐・jump経路，byte/halfword load-store経路，fault情報に加え，pipeline register，forwarding muxおよびhazard制御の影響が含まれる。`clk_ind`はcycle数ではなくretire数を示すため，stallとflushによって増えない。

## 4. 命令セットの拡張

v1.1が実装していた命令は，`ADD`，`SUB`，`AND`，`OR`，`SLT`，`ADDI`，`ANDI`，`ORI`，`SLTI`，`LW`，`SW`，`BEQ`の12命令である。v2ではこれらを保持し，28命令を追加して合計40命令とした。

| 分類 | v1.1から保持 | v2で追加 |
|---|---|---|
| 上位即値 | ― | `LUI`, `AUIPC` |
| jump | ― | `JAL`, `JALR` |
| 条件分岐 | `BEQ` | `BNE`, `BLT`, `BGE`, `BLTU`, `BGEU` |
| load | `LW` | `LB`, `LH`, `LBU`, `LHU` |
| store | `SW` | `SB`, `SH` |
| 即値演算 | `ADDI`, `SLTI`, `ANDI`, `ORI` | `SLTIU`, `XORI`, `SLLI`, `SRLI`, `SRAI` |
| Register演算 | `ADD`, `SUB`, `SLT`, `AND`, `OR` | `SLL`, `SLTU`, `XOR`, `SRL`, `SRA` |
| memory ordering / environment | ― | `FENCE`, `ECALL`, `EBREAK` |

命令ごとの対応範囲は`docs/RV32I_COVERAGE.md`に示す。

### 4.1 ALUの変更

`ALUV1`を`ALUV2`へ置き換え，従来の加算，減算，論理積，論理和，符号付き比較に加えて，左shift，符号なし比較，排他的論理和，論理右shift，算術右shiftを追加した。RV32Iのshift量はoperandの下位5bitだけを使用する。符号付き比較および算術右shiftではVerilogの`signed`演算を明示し，符号なし比較および論理右shiftと分離した。

### 4.2 Decoderの変更

v1.1の`MainDecoderV1`と`ALUDecoderV1`を，命令語全体を検査する`DecoderV2`へ統合した。Decoderはopcodeだけでなく，必要な`funct3`，`funct7`およびSYSTEM命令全32bitを検査する。legalでない組合せではRegister File write，DataMemory write，MMIO writeを行わない安全なdefault制御値を出力する。

DecoderはALU入力Aの`rs1`／PC／zero選択，ALU入力Bの`rs2`／immediate選択，write-backのALU／memory／`PC+4`選択，load-store size，loadのsigned／unsigned，branch，jump，`JALR`，`FENCE`，`ECALL`および`EBREAK`を制御する。

### 4.3 Immediate Generatorの変更

`ImmGenV2`はI，S，B，U，Jの5形式を生成する。U形式では命令の上位20bitをbit 31:12へ配置する。B形式とJ形式では暗黙の最下位0を復元し，符号拡張する。`JALR`はI形式を用い，`rs1 + immediate`のbit 0を0にした後にjump targetとする。

### 4.4 Program Counter経路の変更

通常命令では`PC+4`へ進み，成立したbranch，`JAL`および`JALR`ではtransfer targetへ更新する。`JAL`と`JALR`は`PC+4`を`rd`へwrite backする。branch targetは`PC+immediate`，`JALR` targetは`(rs1+immediate)&~1`である。

本CPUはcompressed instructionを実装しないため`IALIGN=32`相当とし，命令addressは4 byte境界に限定する。成立したbranchまたはjumpのtargetが非整列なら，transfer命令自身でinstruction-address-misalignedを報告する。成立しないbranchでは，計算上のtargetが非整列でもfaultにしない。4 byte境界にあるROM範囲外targetへのtransferはretireし，次のfetchでinstruction access faultを報告する。

### 4.5 Load／Store経路の変更

`LB`，`LH`，`LBU`，`LHU`では，32bit RAM wordをbyte address下位2bitに応じて右shiftし，符号拡張またはzero拡張する。`SB`と`SH`では，store dataをaddress位置へ左shiftし，4bit write strobeで対象byte laneだけを書き換える。`LW`と`SW`の従来動作は維持する。

非整列load/storeをhardwareで分割実行せず，halfwordは2 byte境界，wordは4 byte境界でなければfaultとする。byte accessにはalignment制約を設けない。

### 4.6 FENCE，ECALL，EBREAK

本CPUはsingle-hart，in-orderで，cache，store bufferおよびDMAを持たない。そのため`FENCE`はlegal instructionとしてdecodeし，architectural stateを変更せずretireするno-opとして扱う。`FENCE.I`はRV32I本体ではなくZifenceiに属するため実装しない。

`ECALL`と`EBREAK`はlegalなRV32I命令としてdecodeするが，本版にはtrap vectorやhandlerがないため，それぞれcause 11とcause 3を出力してfatal fault状態になる。これは命令をillegalと判定する動作とは区別する。

## 5. Module構成の変更

| v1.1 | v2 | 変更内容 |
|---|---|---|
| `TD4_TOP.v` | `TD4_TOP.v` | 外部port互換を維持し，v2 topをinstance化 |
| `TD8_RAM_TO_RISCV_V1_TOP.v` | `TD8_RAM_TO_RISCV_V2_TOP.v` | v2 core接続，trap debug wire追加 |
| `TD8_RISCV_V1_Core.v` | `TD8_RISCV_V2_Core.v` | 全40命令，5段pipeline，hazard処理，jump，subword memory，precise trap，retire interfaceを追加 |
| `MainDecoderV1.v` + `ALUDecoderV1.v` | `DecoderV2.v` | strict decodeを1 moduleへ統合 |
| `ALUV1.v` | `ALUV2.v` | shift，XOR，unsigned compareを追加 |
| `ImmGenV1.v` | `ImmGenV2.v` | U形式，J形式，JALRを追加 |
| `InstructionMemoryV1.v` | `InstructionMemoryV2.v` | word数とinit fileをparameter化，v2 demoへ変更 |
| `DataMemoryV1.v` | `DataMemoryV2.v` | 64×32bit単一配列を維持しbyte write strobeを追加 |
| `RegisterFileV1.v` | `RegisterFileV2.v` | v1.1の分散RAM＋valid mask方式を維持 |
| `ProgramCounterV1.v` | `ProgramCounterV2.v` | next-PC入力方式を維持 |
| `ClockEnableV1.v` | `ClockEnableV2.v` | 1 Hz／10 Hz enable方式を維持 |
| `SEG7V1.v` | `SEG7V2.v` | active-low 16進表示を維持 |

## 6. MemoryおよびMMIO仕様

### 6.1 Instruction Memory

Instruction Memoryは32bit word単位のHarvard ROMである。board topでは64 word，すなわち256 byteを使用する。未使用locationはcanonical NOPである`ADDI x0,x0,0`で初期化する。`IMEM_INIT_FILE`を指定した場合は`$readmemh`で上書きできる。

Program Counterが4 byte境界でない場合はcause 0，`PC >= IMEM_WORDS*4`の場合はcause 1とする。ROM moduleが範囲外でNOPを返しても，core側の範囲検査により範囲外NOPをretireしない。

### 6.2 Data RAM

Data RAMの容量はTD8およびv1.1と同じ256 byteであり，byte address `0x00000000`～`0x000000ff`を割り当てる。内部構成は64×32bitの単一配列である。

| access | 許可alignment | 有効な先頭addressの最大値 |
|---|---|---:|
| `LB`, `LBU`, `SB` | 制約なし | `0x0ff` |
| `LH`, `LHU`, `SH` | 2 byte境界 | `0x0fe` |
| `LW`, `SW` | 4 byte境界 | `0x0fc` |

DataMemory配列はCPU resetでclearしない。simulationおよびFPGA初期化用の`initial`値は0である。Register Fileと異なりData RAMにvalid bitは持たないため，一度書き込んだData RAMの内容はCPU reset後も保持される。プログラムはreset後のRAM消去を必要とする場合，softwareで明示的に行う。

### 6.3 MMIO

| byte address | 名称 | 許可操作 | 値 |
|---:|---|---|---|
| `0x00000100` | `IO_IN` | aligned `LW`のみ | `{24'b0, in[7:0]}` |
| `0x00000104` | `IO_OUT` | aligned `LW`, `SW` | readは`{24'b0, out[7:0]}`，writeは`rs2[7:0]`を出力 |

MMIOはexact-addressのword accessのみを許可する。`LB`や`SB`で`0x100`または`0x104`へアクセスすること，`0x101`～`0x103`や`0x105`～`0x107`へアクセスすること，`IO_IN`へstoreすることはaccess faultになる。`0x108`以上はv2では未割当である。

## 7. Fault／trap indication仕様

v2の`fault`はRISC-V CSRではなく，WB段へ到達したfatal synchronous trap tokenを示す。例外をEX段で検出するとIF/IDとID/EXをflushし，新しいfetchを止める。例外より古いMEM/WB命令だけを完了させ，faulting命令と若い命令のside effectを抑止した後，例外tokenがWBへ到達したcycleからresetまで`fault`，causeおよびvalueを保持する。fault中はProgram Counter，pipeline register，Register File，Data RAM，output portおよび`clk_ind`を更新しない。

| cause | 条件 | `debug_trap_value` |
|---:|---|---|
| 0 | instruction address misaligned，または成立した非整列branch/jump target | PCまたはtarget address |
| 1 | instruction fetchがROM範囲外 | PC |
| 2 | illegal instruction encoding | instruction word |
| 3 | `EBREAK` | PC |
| 4 | load address misaligned | effective address |
| 5 | load access fault | effective address |
| 6 | store address misaligned | effective address |
| 7 | store access fault | effective address |
| 11 | `ECALL` | 0 |

cause番号は標準のsynchronous exception codeに合わせたproject-visible debug値であり，`mcause` CSRではない。v2には`mepc`，`mtval`，`mtvec`，privilege mode，trap handlerおよびinterruptがない。複数条件が同時に成立した場合のpriorityは，fetch alignment，fetch access，illegal，`EBREAK`，load alignment，load access，store alignment，store access，`ECALL`，transfer-target alignmentの順である。

## 8. Board demo program

既定ROMは，v2で追加した`XORI`，`SLLI`，`SB`，`LBU`および`JAL`を基板入出力とともに確認する。

| PC | machine code | instruction | 役割 |
|---:|---:|---|---|
| `0x00` | `10000093` | `addi x1,x0,0x100` | input MMIO address |
| `0x04` | `10400113` | `addi x2,x0,0x104` | output MMIO address |
| `0x08` | `0000a183` | `lw x3,0(x1)` | switch input読出し |
| `0x0c` | `05a1c193` | `xori x3,x3,0x05a` | XOR演算 |
| `0x10` | `00119193` | `slli x3,x3,1` | 左shift |
| `0x14` | `003000a3` | `sb x3,1(x0)` | RAM byte address 1へ保存 |
| `0x18` | `00104203` | `lbu x4,1(x0)` | zero-extended byte load |
| `0x1c` | `00412023` | `sw x4,0(x2)` | LED outputへword store |
| `0x20` | `fe9ff06f` | `jal x0,-24` | `0x08`へ戻る |

入力`in=0x05`では，`(0x05 XOR 0x5a) << 1 = 0xbe`となる。`tb_v2_board`は出力`0xbe`，7セグメント表示`E`，anode`1110`，retire count`8`およびcore fault非assertを確認する。

## 9. v2で対象外とする機能

以下はv2へ含めない。

- ZicsrのCSR命令
- Zifenceiの`FENCE.I`
- M，A，F，D，Q，C，B，V等のoptional extension
- privileged architecture，virtual memory，OS support
- interrupt controller，trap vector，trap return
- misaligned data accessのhardware分割実行
- instruction/data cacheおよびBlock RAM向け同期memory pipeline
- VGA，Video RAM，PS/2，timerおよびTetris game

これらを除外しても，RV32I基本命令40命令の対応範囲とは矛盾しない。ただし，論文や資料ではv2を単に「RISC-V完全実装」と表現せず，「本研究で定義した実行環境における非特権RV32I基本40命令の実装」と表現する。

## 10. 検証とVivado再実装の要件

v2の完了判定では，少なくとも次を分けて記録する。

1. 全RTLと全testbenchのparseおよびelaboration。
2. 40命令の正常系とstrict decodeの自己検査simulation。
3. signed／unsigned比較，shift境界，subword laneおよび符号拡張の境界試験。
4. branch/jump link address，taken/not-takenおよびalignmentの試験。
5. forwarding，load-use stall，branch/jump flushおよび誤経路side effect抑止の試験。
6. illegal，ECALL，EBREAK，fetch，load，store fault時のpreciseなside effect抑止。
7. `cpu_enable`停止とpipeline途中resetによる全段保持／flushの試験。
8. `TD4_TOP`を用いたboard-level demo試験。
9. synthesis前のmulti-driver，latch，幅不一致およびunconnected signal検査。
10. Vivado 2025.2で旧runを再利用しないfresh synthesis／implementation／route。

本成果物の作成時点では，Icarus Verilogによる12個の自己検査testbenchが全てPASSし，Yosys 0.68のXilinx 7-series向けgeneric synthesisでも`check -assert`がPASSした。専用pipeline testはforwardingと最新値優先，5種のload-use，control-flow flush，誤経路side effect抑止，MEM段storeを含むclock-enable freeze，precise trap，pipeline途中resetおよびretire interfaceを検査する。YosysではDataMemoryが`RAM64X1S` 32個，Register Fileが`RAM32M` 12個へ写像され，Block RAMは0個であった。これはRTL構造の回帰確認であり，Vivadoの資源量およびtiming実測の代用ではない。詳細は`VERIFICATION.md`に記録する。

v1.1の`LUT=702`，`FF=126`，`LUTRAM=76`はv2の予測値として転記しない。v2ではDecoder，ALU，jump経路およびsubword memory経路が増えるためLUT数とcritical pathが変化する。またbyte write strobeによってDataMemoryの推論形態が変わる可能性がある。v2のfresh route後に次を確認する。

- `report_ram_utilization`でDataMemoryとRegister FileがLUTRAMへ写像されている。
- DataMemoryが再び2048 FFへ展開されていない。
- production topでdebug memory copyが生成されていない。
- Block RAM使用数，LUT，FF，LUTRAMをv1.1と同じdevice／constraintで記録する。
- WNS，TNS，setup violation endpoints，WHSおよびpulse widthを記録する。
- report内に旧v1の`byte0_reg`または旧単一Register File配列`registers_reg`が残っていない。

100 MHzのtiming closureはgeneric synthesisでは判定せず，fresh Vivado implementationの数値をpipeline版v2の基準として保存する。
