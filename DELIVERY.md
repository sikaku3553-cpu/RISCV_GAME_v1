# v3.1 Game Platform delivery

このディレクトリは、5段RV32I CPUを同期BRAM対応のゲーム基盤へ拡張し、
VGA表示とCPU実行型の1-1風横スクロールゲームを追加したローカル成果物です。
GitHubへの書込みは行っていません。

## 入口

- `README_GAME_PLATFORM.md`: 構成、メモリマップ、操作、build方法
- `VERIFICATION.md`: 検証結果と未実施項目
- `firmware/game.S`: CPUが実行するゲーム処理
- `sources_1/new/TD8_RISCV_GAME_TOP.v`: Basys 3 top
- `artifacts/vivado/TD8_RISCV_GAME_TOP.bit`: 生成済みbitstream

## 最終検証結果

- firmware behavior: 9 scenario group PASS、54,984命令
- Icarus Verilog v3: 6/6 PASS
- Vivado Simulator v3: 6/6 PASS
- legacy v2 regression: 12/12 PASS
- Vivado 2025.2 internal 100 MHz: WNS +0.155 ns、WHS +0.048 ns
- route DRC: error 0、critical warning 0、warning 0
- inferred BRAM: RAMB36E1 9個
- bitstream: 生成成功

## 注意

Basys 3へのprogramming、実VGA monitor、実button/switch/PS/2 keyboardでの
hardware validationは未実施です。また外部出力にoutput delayを指定していないため、
board-level I/O timingまで検証済みとは扱いません。

任天堂のROM、画像、音楽、マップ、コードは含みません。表示素材はこの教材用に
Verilogの幾何パターンとして作成したオリジナルです。
