# TD8 RISC-V v2 / v3.1 検証記録

## A. v3.1 Game Platform

### A.1 検証対象

- RTL top: `TD8_RISCV_GAME_TOP`
- device: `xc7a35tcpg236-1`（Basys 3）
- CPU: IF／ID／EX／MEM／WBの5段in-order RV32I pipeline
- memory: 16 KiB同期命令BRAM、16 KiB同期データBRAM、4 KiB dual-port tile/collision map
- video: 640×480 VGA timing、256×240論理画面、tile/sprite renderer
- software: `firmware/game.S`がゲーム状態、物理、衝突、敵、スコア、時間、カメラ、ゴールを更新

ゲーム専用のVerilog制御器でルールを実行せず、CPUがMMIOとtilemapを操作する構成を検証対象とした。任天堂のROM、画像、音楽、マップ、コードは使用していない。

### A.2 firmware検査

`firmware/build.ps1`は二段assembler、出力wordの独立decode、16 KiB容量検査、およびPythonのROM実行behavior testを連続実行する。checked-in imageは720 word（2880 byte）で、4096 wordへNOP paddingされている。`imem_game.hex`のSHA-256は`96c96cdf12613135857baca1472dd5b288d3d13368b847f4e34bc2d2afc85b73`である。

behavior testは次の9 scenario groupをPASSし、合計54,984命令をillegal instructionまたは未定義MMIO accessなしで実行した。

1. boot、tilemap構築、16 shadow sprite slot、最初のcommit要求
2. frame counterが変化しない間のCPU所有game state保持
3. player加速、jump、animation、およびCPU駆動enemy移動
4. enemy接触、踏み付け、bounce、score加算
5. camera追従・clampとVGA shadow register更新
6. 60 frame単位のcountdownとHUD更新
7. pit判定、死亡、残機減算、状態表示
8. action edgeによるrestart
9. goal tile衝突、win遷移、score/HUD更新

再実行command:

```powershell
powershell -ExecutionPolicy Bypass -File .\firmware\build.ps1
```

### A.3 v3.1自己検査RTL simulation

`scripts/run_v3_tests.ps1`からfirmware検査と6個のself-checking testbenchを連続実行し、全てPASSした。各testbenchは失敗時に`$fatal`または非0終了となる。

| testbench | 主な検証内容 | 結果 |
|---|---|:---:|
| `tb_v3_platform_io` | resetの非同期assert・2 edge同期解除、button debounce、PS/2 Set-2 make/break decode | PASS |
| `tb_v3_sync_memory` | 同期IMEM/DMEM待機、pipeline保持、load-use、branch、exact-once STORE、counter、precise breakpoint | PASS |
| `tb_v3_memory_subsystem` | MMIO access fault、W1C、RAM/tile byte lane、scene register禁止書込み、backpressure中のexact-once commit | PASS |
| `tb_v3_vga_timing` | 800×525 total、640×480 active、HSYNC/VSYNC幅、1 frameのpixel数 | PASS |
| `tb_v3_tile_renderer` | byte-write dual-port tilemap、shadow/active frame commit、tile/sprite renderer latency | PASS |
| `tb_v3_game_soc` | 実firmwareを同期BRAMからbootし、level構築、VGA commit、入力後のplayer移動、faultなし | PASS |

再実行command:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_v3_tests.ps1
```

同じsource treeで旧v2の`scripts/run_tests.ps1`も12/12 PASSし、v3.1追加後に基準CPUの回帰がないことを確認した。

Vivado Simulator 2025.2でも`scripts/run_v3_xsim.ps1 -AllTests -SkipFirmware`を実行し、同じ6 testbenchが6/6 PASSした。full SoC testの終了時counterは`cycles=73927`、`instret=15596`、`stalls=49357`、`flushes=4485`で、入力後の`player_x=33`を確認した。

### A.4 Vivado implementation

`scripts/build_game_vivado.tcl`はnon-project flowでsynthesis、place、physical optimization、route、timing/DRC/利用率report、およびbitstreamを生成する。100 MHz合格条件は、最終source snapshotのpost-route WNSが0 ns以上、timing errorとDRC errorが0、意図したBRAM推論が成立し、bitstream生成が完了することである。

| 項目 | 最終source結果 |
|---|---:|
| Vivado version / device | 2025.2 Build 6299465 / `xc7a35tcpg236-1` |
| synthesis / place / route | PASS / PASS / PASS |
| post-route WNS / TNS | `+0.155 ns` / `0.000 ns` |
| post-route WHS / THS | `+0.048 ns` / `0.000 ns` |
| setup・hold failing endpoint | `0` / `0` |
| internal unconstrained path | `0` |
| total LUT / FF | `3001` / `3385` |
| RAMB36E1 / RAMB18E1 / DSP | `9` / `0` / `0` |
| route DRC error / critical warning / warning | `0` / `0` / `0` |
| bitstream | PASS、2,192,142 byte、SHA-256 `3bfe42a79381db42f0b4c00e9a01e57b834400ae807de006bc2cd975271955ee` |
| Icarus v3 / legacy v2 | `6/6 PASS` / `12/12 PASS` |
| XSim final-source | `6/6 PASS` |

reportと生成物の標準出力先は`build/game_vivado`である。

`report_methodology`の39 warningは、BRAM出力register未mergeの`SYNTH-6`が9件と、外部出力portにoutput delayがない`TIMING-18`が30件である。前者を含むpost-route内部timingは上表のとおり合格している。後者により、VGA、LEDを含む外部出力pinのboard-level timingを検証済みとは扱わない。`report_cdc`は同期器を認識したInfoのみで、warning/critical warningはない。

### A.5 未実施項目と判定上の注意

- Basys 3へのbitstream書込みと電源投入時boot
- 実VGA monitorでの同期、RGB444、frame commit、長時間表示
- 実button/switch/PS/2 keyboardでの全操作とnoise耐性
- board上の100 MHz連続play、death/restart、goal到達
- RISC-V architectural test suiteまたはformal verification

simulationがPASSしても、配置配線後100 MHzや実周辺機器の動作を単独では証明しない。Vivado結果が合格しても、実機検証が完了するまでは「Basys 3で完成」と判定しない。

---

## B. v2パイプラインCPU（基準実装）

### B.1 検証対象

- v1.1取得元: `Gitratter/TD8_To_RISCV_v1.1` / `main`
- v1.1基準commit: `27bebc9847ef0f8d192b80ecb6754cc1005dde61`
- pipeline実装・検証日: 2026-09-05
- RTL top: `TD4_TOP`
- ISA範囲: 非特権RV32I基本40命令
- pipeline: IF／ID／EX／MEM／WBの5段in-order

GitHub上のrepositoryには書き込まず，取得した`Gitratter/TD8_To_RISCV_v2`の`main`を基準としてローカル変更だけを検証した。

### B.2 使用tool

| tool | version / option |
|---|---|
| Icarus Verilog | 14.0 (devel) |
| RTL mode | `-g2012 -Wall` |
| test形式 | self-checking SystemVerilog，失敗時`$fatal` |
| Yosys | 0.68，`synth_xilinx -family xc7` |

### B.3 Parse／elaboration

`sources_1/new`の全Verilog sourceを対象に，次の条件でboard topをelaborationした。

```powershell
$rtl = (Get-ChildItem -LiteralPath ./sources_1/new -Filter *.v | Sort-Object Name).FullName
& iverilog -g2012 -Wall -s TD4_TOP -tnull $rtl
```

結果はPASSであり，errorおよびIcarusが報告するwarningは0件であった。

### B.4 自己検査simulation

`scripts/run_tests.ps1`から12個のtestbenchを連続実行した結果，全てPASSした。

| testbench | 主な検証内容 | 結果 |
|---|---|:---:|
| `tb_v2_decoder` | RV32Iの40命令名を各1 encoding以上decodeし，legal countが40であること。MUL，予約`funct`，不正shift，FENCE.I，CSR等13 encodingを拒否し，副作用制御が0であること | PASS |
| `tb_v2_immediates` | I／S／B／U／J immediateの正負encoding範囲端と符号拡張 | PASS |
| `tb_v2_integer` | OP 10種，OP-IMM 9種，LUI，AUIPC，FENCE。signed／unsigned比較，shift量31および`rs2[4:0]`，即値符号拡張，`x0`書込み抑止 | PASS |
| `tb_v2_boundaries` | ADD／SUB／ADDIのmodulo-2^32 overflow，I-immediate両端，FENCE rw,rw，`JALR rd=rs1` | PASS |
| `tb_v2_control_flow` | 6種のbranchのtaken／not-taken，forward／backward branch，JAL，negative-offset JAL，JALR，link値 | PASS |
| `tb_v2_memory` | LB，LH，LW，LBU，LHU，SB，SH，SW，全byte lane，両halfword lane，little-endian，符号／zero拡張 | PASS |
| `tb_v2_memory_boundaries` | 負のload/store offset，RAM末端のbyte `0xff`，halfword `0xfe`，word `0xfc` | PASS |
| `tb_v2_mmio` | input MMIOのLWと8bit値のzero拡張，output MMIOのSW，output registerのLW readback | PASS |
| `tb_v2_faults` | 20 case。illegal，ECALL，EBREAK，fetch／target／load／storeのalignmentおよびaccess fault，`load rd=x0`，word-only MMIO，fault時のPC／RF／RAM／output副作用抑止 | PASS |
| `tb_v2_lutram_reset` | Data RAM内容のreset跨ぎ保持，Register File物理配列の非reset，valid maskだけのreset，reset中の全commit抑止 | PASS |
| `tb_v2_pipeline` | EX/MEM・MEM/WB forwardingと同一rdの最新値優先，WB-to-ID bypass，ALU／branch／JALR／store-dataを含む5種のload-use，taken branch／JAL／JALR flush，誤経路のtrap／RAM／MMIO副作用抑止，MEM段storeを含む`cpu_enable`全段freeze，precise trap，pipeline途中reset，retire PC／命令 | PASS |
| `tb_v2_board` | 既定ROM，switch入力`0x05`からLED出力`0xbe`，7 segment `E`，anode `1110`，retire count `8`，faultなし | PASS |

実行commandは次のとおりである。

```powershell
./scripts/run_tests.ps1
```

各testbenchは，対象命令の最終Register値，Program Counter，memory lane，trap cause/valueまたはboard portを期待値と比較する。単にwaveformを目視した結果ではない。

### B.5 v1.1資源最適化の機能回帰

v2のDataMemoryは引き続き単一の`reg [31:0] memory [0:63]`であり，clocked processにreset分岐を持たない。Register Fileは2 read operandのため同内容の32×32bit配列を2個持つが，両配列にもreset代入を行わず，32bitの`valid`だけをresetする。

`tb_v2_lutram_reset`では，Register FileとData RAMへ値を書いた後にresetをassertし，次を確認した。

- x1の物理RAM内容は`0x55`のままである。
- `valid`は0へclearされるため，architecturalなx1 readは0になる。
- Data RAM word 0は`0x55`のままである。
- reset中にPC=0へstore命令を置き`cpu_enable=1`としても，pipeline valid bitとmemory write enableが0のためRAMは変化しない。

これはreset semanticsと副作用抑止のsimulation確認である。Vivadoが実際にLUTRAM primitiveへ推論したことの証明ではない。

### B.6 Yosysによる汎用合成check

`TD4_TOP`を対象にYosys 0.68の`check -assert`および`Xilinx 7-series`向けgeneric synthesisを実行し，PASSした。再実行用scriptは`scripts/yosys_synth_check.ys`である。

| 項目 | Yosys 0.68結果 |
|---|---:|
| design problems (`check -assert`) | 0 |
| DataMemory `RAM64X1S` | 32 |
| Register File `RAM32M` | 12 |
| `RAMB18E1` / `RAMB36E1` | 0 / 0 |
| FDCE | 720 |
| estimated logic cells | 1631 |

この結果から，production topでDataMemoryとRegister FileがFF配列へ全面展開されず，Yosysではdistributed-RAM primitiveへ写像されることを確認した。ただしprimitive packing，logic最適化および資源数は合成toolに依存する。Yosysの`1631 estimated logic cells`やprimitive数を，VivadoのSlice LUT／LUTRAM値または配置配線後結果として流用してはならない。

実行commandは次のとおりである。

```powershell
./scripts/run_yosys_check.ps1
```

### B.7 未実施項目と判定上の注意

本成果物では次を未実施とした。

- Vivado synthesis／implementation／bitstream生成
- Vivado `report_ram_utilization`によるRAM64／RAM32 primitiveの確認
- VivadoによるLUT，FF，LUTRAM，BRAM，WNS，TNS，WHSおよびWPWSのv2実測
- 実機Basys 3での動作確認
- RISC-V architectural test suiteまたはformal verification

したがって，v1.1の`LUT=702`，`FF=126`，`LUTRAM=76`およびtiming値をpipeline版v2の結果として扱ってはならない。現時点で主張できるのは，「RV32I基本40命令と5段pipelineをRTLへ実装し，付属project testbenchが全てPASSし，Yosys generic synthesisでdistributed-RAM構造を確認した」ことまでである。

Vivadoでは旧runを流用せず，`TD4_TOP`をtop，`xc7a35tcpg236-1`をpart，XDCのclock periodを10 nsとしてfresh synthesis／implementationを行う。完了後，open project内で`scripts/vivado_reports.tcl`をsourceすると，階層別資源，RAM推論，timingおよびpower reportを`reports/v2`へ保存できる。
