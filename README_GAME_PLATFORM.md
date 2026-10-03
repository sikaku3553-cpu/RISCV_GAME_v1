# TD8 RISC-V v3.1 Game Platform

この追加実装は、卒業論文で示された「パイプライン CPU の次に VGA、VRAM、入力、タイマを独立検証し、その上でゲーム処理を RV32I ソフトウェアとして動かす」という段階構成に合わせたものです。論文中のテトリス案そのものは採用せず、地面、穴、ブロック、パイプ状の障害物、階段、敵、ゴールを持つ 1-1 風の横スクロール教材ゲームへ置き換えています。

任天堂の ROM、マップ、画像、音楽、コードは含みません。タイルとスプライトは、このプロジェクト用に Verilog の幾何パターンとして作成したオリジナル素材です。

## 設計上の要点

- CPU は既存の RV32I 5 段パイプラインを基にし、命令側・データ側を `request/ready` と応答信号を持つインターフェースへ変更しています。
- 同期 BRAM の 1 サイクル以上の応答待ちに対してパイプライン全段を保持し、未完了要求を記録します。STORE と MMIO の副作用は要求受理時に一度だけ発生します。
- CPU は 100 MHz 系クロックで常時実行し、旧 Board top の 1 Hz/10 Hz クロックイネーブルはゲーム処理に使いません。
- VGA は同じ 100 MHz クロック領域内の 25 MHz pixel-enable で走り、CPU の処理速度と表示フレーム周期を分離しています。
- リセットは非同期アサート・同期解除です。ボタンは同期化とデバウンス、スイッチは同期化、PS/2 は同期化・デジタルフィルタ・パリティ検査を行います。
- CPU がフレームカウンタをポーリングし、フレームごとにゲーム状態を 1 回更新します。VGA タイミングは CPU が待機または停止しても独立して進みます。
- 描画レジスタは shadow/active の二重化を行い、`VGA_FRAME_COMMIT` への書込み後、次のフレーム境界で一括反映します。途中更新の画面が見えることを避けるためです。

構成は概ね次のとおりです。

```text
100 MHz clk
  +-- reset synchronizer
  +-- RV32I pipeline CPU
  |     +-- synchronous instruction BRAM
  |     `-- data request/response interconnect
  |            +-- system/input/counter MMIO
  |            +-- VGA shadow registers + sprite descriptors
  |            +-- dual-port tile/collision map
  |            `-- synchronous game data RAM
  +-- button/switch/PS2 conditioning
  `-- VGA timing (25 MHz CE) --> tile/sprite renderer --> RGB444 + HS/VS
```

## CPU と描画回路の責務

ゲーム状態を変える処理は `firmware/game.S` の RV32I プログラムが担当します。

- プレイヤーの左右移動、加速、摩擦
- ジャンプ、重力、床・壁・天井との衝突
- 穴・ハザードへの落下、死亡、再開、残機
- 敵の移動、壁・崖判定、接触、踏み付け
- スコア、残り時間、アニメーション
- カメラ追従、ゴール判定、クリア状態
- タイルマップ構築とスプライト記述子更新

VGA 側は、CPU が書いたタイルと記述子を走査して表示するだけです。ゲームルールを実行する専用 Verilog ステートマシンはありません。この区分により、「RISC-V CPU がゲームを実行する」という評価対象を明確にしています。

## 表示方式

- 出力: 640 x 480、RGB444、負極性 HSYNC/VSYNC
- pixel-enable: 100 MHz の 4 分周相当、25.000 MHz
- 論理画面: 256 x 240、縦横 2 倍で 512 x 480 として表示
- 左右の 64 画素: backdrop 色
- タイル: 16 x 16 論理画素、64 種類まで
- タイルマップ: 256 x 16 byte。各 byte はタイル ID と衝突属性を共用
- スプライト記述子: 16 スロット。現在の描画パイプラインが合成する可視スロットは 0～4
- HUD: スコア、時間、状態をハードウェア文字で重ね合わせ

25.000 MHz は一般的な 640 x 480 VGA の公称 25.175 MHz に近い値ですが、全ディスプレイでの互換性を保証するものではありません。実機で同期しない場合はクロッキング構成の再検討が必要です。

## メモリマップ

### 命令・データ領域

| アドレス | 大きさ | 内容 |
|---|---:|---|
| `0x0000_0000-0x0000_3fff` | 16 KiB | 命令 BRAM、Harvard 命令ポートからのみ fetch |
| `0x0000_1000-0x0000_10ff` | 256 B aperture | システム MMIO |
| `0x0000_1100-0x0000_11ff` | 256 B aperture | VGA 制御 |
| `0x0000_1200-0x0000_12ff` | 256 B aperture | スプライト記述子 |
| `0x0000_2000-0x0000_2fff` | 4 KiB | タイル兼衝突マップ |
| `0x0000_4000-0x0000_7fff` | 16 KiB | ゲーム用データ RAM、`sp` 初期値は `0x8000` |

命令アドレスとデータアドレスは Harvard 構成であるため、数値上は一部重なっています。データバスから命令 BRAM を読む構成ではありません。

### システム MMIO

| アドレス | アクセス | 内容 |
|---|---|---|
| `0x1000` | R | 同期済みスイッチ `sw[15:0]` |
| `0x1004` | R | 論理入力 level `[4:0]` |
| `0x1008` | R/W1C | 論理入力の立上りラッチ |
| `0x100c` | R | VGA frame counter |
| `0x1010` | R | 100 MHz wall-clock counter 下位 32 bit |
| `0x1014`, `0x1018` | R | cycle の現在値（下位 32 bit）、上位予約値 0 |
| `0x101c`, `0x1020` | R | instret の現在値（下位 32 bit）、上位予約値 0 |
| `0x1024`, `0x1028` | R | stall の現在値（下位 32 bit）、上位予約値 0 |
| `0x102c`, `0x1030` | R | flush の現在値（下位 32 bit）、上位予約値 0 |
| `0x1034`, `0x1038` | R | 将来の memory-wait counter 用予約。現在は両方 0 |
| `0x103c` | R/W | 将来の counter 制御用予約。read は 0、write は受理するが現在は動作なし |
| `0x1040` | R/W | debug LEDs |
| `0x1044` | R | PS/2。scan code `[7:0]`、valid bit 16、parity error bit 17 |

未定義アドレス、禁止書込み、または不正なアクセスは bus error として CPU の access-fault に伝わります。

### VGA とスプライト

| アドレス | アクセス | 内容 |
|---|---|---|
| `0x1100` | R | active/vblank/commit status |
| `0x1104` | R/W shadow | camera X、論理画素単位 |
| `0x1108` | R/W shadow | backdrop RGB444 |
| `0x110c` | R/W | read は commit pending bit 0、bit 0=`1` の write で次フレームへの commit を要求 |
| `0x1110` | R/W shadow | layer enable/debug control |
| `0x1114` | R/W shadow | HUD score |
| `0x1118` | R/W shadow | HUD remaining time |
| `0x111c` | R/W shadow | state `[7:0]`、animation `[15:8]`、lives `[23:16]` |
| `0x1200-0x12ff` | R/W shadow | 16 個の 16-byte sprite descriptor |

各 sprite descriptor は次の 4 word です。

| offset | 内容 |
|---:|---|
| `+0x0` | signed X `[15:0]`、signed Y `[31:16]` |
| `+0x4` | enable bit 0、hflip bit 1、vflip bit 2、priority `[5:4]`、tile ID `[13:8]` |
| `+0x8` | firmware animation/debug tag |
| `+0xc` | 予約。read は 0、write は access fault |

タイルマップの 1 byte は、graphic ID `[5:0]` と collision class `[7:6]` です。衝突 class は `00` empty、`01` solid、`10` hazard、`11` goal/special です。CPU と VGA は同じ dual-port map を参照するため、見えている地形と当たり判定の食い違いを避けられます。

## 操作

| 動作 | Basys 3 | PS/2 Set-2 keyboard |
|---|---|---|
| 左 | `btnL` | 左矢印 または `A` |
| 右 | `btnR` | 右矢印 または `D` |
| ジャンプ | `btnU` | 上矢印、`W`、または Space |
| 下 | `btnD` | 下矢印 または `S` |
| action/restart | `sw[15]`。ジャンプでも死亡後再開可能 | `R` または Enter |
| hardware reset | `btnC` | ― |

PS/2 は受信専用です。ホスト向けコマンド送信やキーボード LED 制御は実装していません。

## firmware の再生成

依存性のない二段 RV32I assembler が同梱されています。リポジトリのルートで次を実行します。

```powershell
powershell -ExecutionPolicy Bypass -File .\firmware\build.ps1
```

生成される `firmware/build/imem_game.hex` は 4096 word の BRAM 初期化ファイルです。assembler は出力語を再 decode し、この CPU が実装する RV32I 命令以外が含まれないことと 16 KiB 内に収まることを検査します。詳細は `firmware/README.md` を参照してください。

## simulation

旧 v2 回帰テスト:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_tests.ps1
```

v3 の同期メモリ、exact-once STORE、VGA timing、PS/2・入力、tile/sprite renderer、および game platform のテストは次で実行します。

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_v3_tests.ps1
```

Vivado Simulator でも同じ 6 個の self-checking testbench を実行できます。

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_v3_xsim.ps1 -AllTests
```

`iverilog` と `vvp` が `PATH` にない場合は、runner の `-Iverilog`、`-Vvp`、`-IverilogBase`、`-VvpModulePath` 引数で場所を指定できます。テスト結果は生成ログの `PASS`/`FAIL` を確認してください。実行済みのテスト内容と結果は[`VERIFICATION.md`](VERIFICATION.md)に記録しています。simulation の成功だけで、配置配線後の 100 MHz 動作や実機 VGA/PS2 動作が証明されるわけではありません。

## Vivado / Basys 3 build

対象デバイスは `xc7a35tcpg236-1`、top は `TD8_RISCV_GAME_TOP` です。先に firmware を生成してから、Vivado Tcl shell またはコマンドプロンプトで実行します。

```powershell
vivado -mode batch -source scripts/build_game_vivado.tcl
```

スクリプトは synthesis、place、route、bitstream generation を行い、`build/game_vivado` 以下へ次を出力します。

- `TD8_RISCV_GAME_TOP.bit`
- `TD8_RISCV_GAME_TOP_routed.dcp`
- `reports/post_route_timing_summary.rpt`
- `reports/post_route_timing_max20.rpt`
- utilization、clock utilization、DRC reports

100 MHz 合格の判定には、少なくとも post-route timing summary の WNS が 0 ns 以上であること、`post_route_timing_max20.rpt` の最悪経路が設計意図と一致すること、unconstrained path がないことを確認してください。

## 現時点で保証していないこと

- Vivado 2025.2 による最終 source の配置配線は、内部 100 MHz 制約に対して WNS `+0.155 ns`、TNS `0.000 ns`、WHS `+0.048 ns`、THS `0.000 ns` で合格しました。内部 unconstrained path と route DRC check はともに 0、bitstream も生成済みです。これは当該 tool/device run の結果であり、基板上での動作保証とは区別します。
- methodology report には、9 個の BRAM に出力 register が merge されていないという警告と、外部出力 30 本に output delay がないという警告が残ります。前者を含む配置配線後 timing は合格しています。後者のため、VGA/LED pin の外部 I/O timing を検証済みとは扱いません。
- Basys 3 実機、VGA monitor、PS/2 keyboard を組み合わせた hardware validation は未実施です。
- XDC は公式 Basys 3 pin assignment に合わせていますが、使用する基板 revision と周辺機器を接続前に再確認してください。
- 音源、HDMI、USB keyboard、SD card は実装対象外です。
- これは教育用の 1-1 風ゲームであり、市販ゲームの完全再現ではありません。

完成判定では simulation、Vivado timing、DRC、bitstream programming、実画面、全入力、長時間実行を別々に記録してください。特に「RTL が compile した」ことを「100 MHz 実機動作保証」と読み替えないでください。
