# Vivado 2025.2 final artifacts

これらは `TD8_RISCV_GAME_TOP` を `xc7a35tcpg236-1` 向けに、
`scripts/build_game_vivado.tcl` で最終 source から生成した成果物です。

- internal clock constraint: 100 MHz
- post-route WNS / TNS: +0.155 ns / 0.000 ns
- post-route WHS / THS: +0.048 ns / 0.000 ns
- route DRC checks: 0
- internal unconstrained paths: 0
- bitstream SHA-256: `3bfe42a79381db42f0b4c00e9a01e57b834400ae807de006bc2cd975271955ee`

`TD8_RISCV_GAME_TOP.bit` は生成済みですが、Basys 3 実機への書込み、
VGA monitor、button/switch、PS/2 keyboardを組み合わせた検証は未実施です。
外部出力にoutput delayを指定していないため、board-level I/O timingの
検証済み成果物としては扱わないでください。

各ファイルの内容確認用hashは `SHA256SUMS.txt` にあります。
