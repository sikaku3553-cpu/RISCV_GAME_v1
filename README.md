# TD8 RISC-V CPU — v2 Core / v3.1 Game Platform

## 現行成果物: v3.1 Game Platform

このリポジトリの現行成果物は、v2の5段RV32IパイプラインCPUを、同期BRAM、待機可能な命令・データバス、VGA、入力回路、タイマ、性能カウンタ、およびCPU実行型の横スクロールゲームへ拡張した`v3.1 Game Platform`です。旧v2のRTL、テスト、設計記録も比較・回帰用として残しています。

- 設計、メモリマップ、操作、Vivado手順: [`README_GAME_PLATFORM.md`](README_GAME_PLATFORM.md)
- CPUが実行するRV32Iゲームプログラム: [`firmware/game.S`](firmware/game.S)
- firmwareの再生成方法とABI: [`firmware/README.md`](firmware/README.md)
- v2/v3.1の検証記録と未検証事項: [`VERIFICATION.md`](VERIFICATION.md)
- 最終bitstream、timing/DRC/利用率report: [`artifacts/vivado`](artifacts/vivado)
- Basys 3用top: `TD8_RISCV_GAME_TOP`

最短の再検証手順は次のとおりです。

```powershell
# firmware生成、命令セット検査、behavior test、v3.1 RTL test
powershell -ExecutionPolicy Bypass -File .\scripts\run_v3_tests.ps1

# 旧v2の回帰test
powershell -ExecutionPolicy Bypass -File .\scripts\run_tests.ps1

# Vivado synthesis/place/route/bitstream
vivado -mode batch -source scripts/build_game_vivado.tcl
```

v3.1のゲームルールは`firmware/game.S`で実行され、VGA回路はタイルとスプライトの描画に限定されています。任天堂のROM、マップ、画像、音楽、コードは含みません。配置配線後timingと実機確認の状態は、古い数値を流用せず[`VERIFICATION.md`](VERIFICATION.md)のv3.1欄を確認してください。

## v2パイプラインCPU（基準実装と履歴）

`TD8_To_RISCV_v1.1`を基準に、RV32I基本整数命令セット全40命令と5段パイプラインを実装したv2です。以下はv2単体についての記録であり、v3.1の同期BRAM・VGA・ゲーム機能の説明ではありません。

## 基準source

- Repository: `Gitratter/TD8_To_RISCV_v1.1`
- 基準commit: `27bebc9847ef0f8d192b80ecb6754cc1005dde61`
- 取得日: 2026-09-04
- 基準path: `sources_1/new`，`constrs_1/new`

## v1からv1.1への改善の継承

v1.1で行われた次の資源改善をv2でも維持しています。

- DataMemoryを4個の64×8bit配列から1個の64×32bit配列へ統合
- Register Fileのdata配列をresetせず，書込み済み状態を32bitのvalid maskで管理
- Register Fileを2個の1-read LUTRAM copyとして構成し，2 source operandを読出し
- 合成用topではRegister FileおよびDataMemoryのdebug readを無効化

ユーザー提供の同一条件による配置配線結果では，v1からv1.1への変更によりLUTは1438個から702個へ約51.2%，FFは2649個から126個へ約95.2%減少し，LUTRAMは0個から76個へ増加しました。WNSは-4.936 nsから-4.262 ns，TNSは-13377.653 nsから-1069.005 nsへ改善しましたが，100 MHz制約は未達です。

v2ではSBおよびSHを実装するため，単一の64×32bit DataMemory配列に4bitのbyte write strobeを追加しました。4個の独立した8bit配列には戻していません。ただし，v2でLUTRAM推論が維持されるかは新しいVivado synthesis／implementationで再確認が必要です。v1.1の数値をv2の結果として流用してはいけません。

## 実装範囲

RISC-V Unprivileged ISAのRV32I Base Integer Instruction Set Version 2.1に含まれる40命令を実装しています。

| 分類 | 命令 |
|---|---|
| Upper immediate | LUI, AUIPC |
| Jump | JAL, JALR |
| Branch | BEQ, BNE, BLT, BGE, BLTU, BGEU |
| Load | LB, LH, LW, LBU, LHU |
| Store | SB, SH, SW |
| OP-IMM | ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI |
| OP | ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND |
| Memory ordering | FENCE |
| Environment | ECALL, EBREAK |

FENCEは，single-hart，in-order，cache／store bufferなしでmemory operationを発行順に完了する本構成ではNOPとして実装しています。ECALLおよびEBREAKはlegalなSYSTEM命令としてdecodeし，それぞれ異なるfatal trap causeを出力します。

次の機能はRV32I基本40命令には含まれないため，v2の対象外です。

- ZifenceiのFENCE.I
- ZicsrのCSR命令
- privileged architectureのCSR，trap vector，interruptおよびreturn命令
- M，A，F，D，C，B，Vなどのoptional extension
- cache，VGA，PS/2およびgame logic

したがって，v2は「RV32I基本整数命令40命令を実装したcore」であり，「全てのRISC-V extensionとprivileged systemを実装したCPU」ではありません。

## microarchitecture

- 32bit Program Counter，byte-addressed，`PC+4`
- 32×32bit Register File，x0は常時0
- I／S／B／U／J immediate
- 32bit ALUとsigned／unsigned branch comparator
- 5段in-order pipeline（IF／ID／EX／MEM／WB），最大1命令／`cpu_enable`
- EX/MEMおよびMEM/WB forwarding，WB-to-ID bypass
- load-use hazardに対する1 cycle stall
- EX段でのbranch／JAL／JALR解決とIF/ID・ID/EX flush
- WB段で確定するprecise fatal trapと若い命令のsquash
- `cpu_enable=0`で全段を保持し，`retire_valid`で完了命令を通知
- Harvard構成
- Instruction Memoryは標準64 word，parameterで変更可能
- Data Memoryは256 byte，single 64×32bit distributed-memory array
- little-endian
- 100 MHz単一clockと1 Hz／10 Hz clock-enable
- TD8互換のswitch，LED，7 segmentおよび`TD4_TOP` port

## memory map

| Address | access | 内容 |
|---|---|---|
| `0x00000000`–`0x000000ff` | R/W | 256-byte Data RAM。LB/LH/LW/LBU/LHU/SB/SH/SWに対応 |
| `0x00000100` | R | 8bit switchを0拡張した32bit input register。aligned LWのみ |
| `0x00000104` | R/W | 8bit LED output/readback register。aligned LW/SWのみ |
| その他 | ― | access fault |

RAMの自然alignmentは，byte accessが任意address，halfword accessが2-byte境界，word accessが4-byte境界です。misaligned accessは本実行環境ではfatal trapになります。

Data RAM配列にはresetを与えていないため，CPU reset後も物理内容を保持します。Register Fileは配列をresetせずvalid maskをclearするので，reset後はx1–x31を論理的に0として読み出します。PC，output portおよび`clk_ind`はresetされます。

## trap interface

`fault=1`はWB段へ到達したfatal synchronous trapを示します。例外は命令とともにpipeline内をin-orderで進み，EX段で検出した時点から若い命令をsquashしてfetchを止めます。先行する古い命令だけを完了させた後にfaultを確定するため，faulting命令とそれより若い命令はRegister File，Data RAMおよびoutput portを更新しません。`debug_trap_cause`と`debug_trap_value`をsimulation/debug用に出力します。

| cause | 意味 |
|---:|---|
| 0 | instruction address misaligned |
| 1 | instruction access fault |
| 2 | illegal instruction |
| 3 | breakpoint (EBREAK) |
| 4 | load address misaligned |
| 5 | load access fault |
| 6 | store address misaligned |
| 7 | store access fault |
| 11 | environment call |

cause番号は標準の同期exception番号に合わせていますが，これらはproject-local debug signalであり，`mcause` CSRではありません。v2はtrap vector，CSR保存およびtrap returnを実装せず，resetまでfaulting stateで停止します。

JAL，JALRおよびtaken branchのtargetが4-byte境界でなければ，control-transfer命令自身でinstruction-address-misaligned trapを発生させ，link registerを含む副作用を抑止します。整列しているがInstruction Memory範囲外のtargetへはcontrol transferを完了し，次のfetchでinstruction access faultを発生させます。not-taken branchは未選択targetのmisalignmentを報告しません。

## default FPGA demo

既定ROMはv2で追加したXORI，SLLI，SB，LBUおよびJALを通る短いloopです。

```text
x3 = zero_extend(IO_IN)
x3 = x3 XOR 0x5a
x3 = x3 << 1
RAM byte[1] = x3[7:0]
x4 = zero_extend(RAM byte[1])
IO_OUT = x4
loop
```

switch入力が`0x05`の場合，LED出力は`0xbe`となり，7 segmentには下位nibbleの`E`が表示されます。

## directory

```text
TD8_To_RISCV_v2/
├─ sources_1/new/       synthesizable RTL
├─ constrs_1/new/       Basys 3 XDC
├─ sim_1/new/           self-checking testbenches
├─ scripts/             simulation，Yosys synthesis，Vivado report helpers
└─ docs/                migration and instruction coverage records
```

Vivadoのtop moduleは`TD4_TOP`です。

## simulation

Icarus VerilogがPATHにある場合は，PowerShellで次を実行します。

```powershell
./scripts/run_tests.ps1
```

portable Icarusを使用する場合は，実行fileとbackend directoryを指定できます。

```powershell
./scripts/run_tests.ps1 `
  -Iverilog C:\path\to\iverilog.exe `
  -Vvp C:\path\to\vvp.exe `
  -IverilogBase C:\path\to\lib\ivl
```

全12 testbenchは自己検査型で，失敗時に非0で終了し，成功時に`PASS`を表示します。RV32I 40命令，strict decode，即値／演算／memoryの境界，MMIO／fault，v1.1のLUTRAM向けreset方式，pipeline hazard／flush／precise trapおよびboard demoを検査します。実行済み結果は`VERIFICATION.md`を参照してください。

## Yosys synthesis check

Yosys 0.68がPATHにある場合，Xilinx 7-series向けgeneric synthesisとLUTRAM primitive assertionを実行できます。

```powershell
./scripts/run_yosys_check.ps1
```

pipeline実装後のYosys 0.68結果はDataMemoryが`RAM64X1S` 32個，Register Fileが`RAM32M` 12個，Block RAMが0個です。このprimitive構成はYosys用の回帰signatureであり，Vivadoの配置配線後資源値ではありません。

## Vivadoで必ず再確認する項目

v2のsourceとXDCを新しいprojectへ追加し，`TD4_TOP`をtopとしてsynthesisおよびimplementationを行います。`scripts/vivado_reports.tcl`はprojectのpart，top，v2 sourceおよび旧v1 source混在を検査した後，synthesis／implementation reportを出力する補助scriptです。

特に次を確認してください。

- DataMemoryが64×32bitのDISTRIBUTED RAMとして推論されたこと
- Register Fileの2 bankが32×32bitのDISTRIBUTED RAMとして推論されたこと
- DataMemory配下にRAM64系，Register File配下にRAM32系primitiveが存在すること
- memory本体が大量のFDREへ戻っていないこと
- synthesis topではdebug memory copyが存在しないこと
- Block RAMが0であること
- LUTRAM，LUT，FF，WNSおよびTNSのv1.1との差

5段pipelineにより命令実行経路は段分割されましたが，100 MHzのtiming closureはgeneric synthesisだけでは保証されません。新しいVivado projectでfresh synthesis／implementationを行い，forwarding mux，ALU，memory accessおよびclock-enable経路を含むWNS/TNSを確認してください。

## 参照仕様

- RISC-V International, RV32I Base Integer Instruction Set, Version 2.1: <https://docs.riscv.org/reference/isa/v20260120/unpriv/rv32.html>
