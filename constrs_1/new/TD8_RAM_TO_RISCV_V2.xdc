## 100 MHz clock
set_property IOSTANDARD LVCMOS33 [get_ports clk]
set_property PACKAGE_PIN W5 [get_ports clk]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports clk]

## Asynchronous active-high reset
set_property IOSTANDARD LVCMOS33 [get_ports reset]
set_property PACKAGE_PIN U18 [get_ports reset]
set_property PULLDOWN true [get_ports reset]

## 8-bit switch input
set_property PACKAGE_PIN V17 [get_ports {in[0]}]
set_property PACKAGE_PIN V16 [get_ports {in[1]}]
set_property PACKAGE_PIN W16 [get_ports {in[2]}]
set_property PACKAGE_PIN W17 [get_ports {in[3]}]
set_property PACKAGE_PIN V15 [get_ports {in[4]}]
set_property PACKAGE_PIN W14 [get_ports {in[5]}]
set_property PACKAGE_PIN W13 [get_ports {in[6]}]
set_property PACKAGE_PIN V2  [get_ports {in[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {in[*]}]

## 8-bit LED output
set_property PACKAGE_PIN U16 [get_ports {out[0]}]
set_property PACKAGE_PIN E19 [get_ports {out[1]}]
set_property PACKAGE_PIN U19 [get_ports {out[2]}]
set_property PACKAGE_PIN V19 [get_ports {out[3]}]
set_property PACKAGE_PIN W18 [get_ports {out[4]}]
set_property PACKAGE_PIN U15 [get_ports {out[5]}]
set_property PACKAGE_PIN U14 [get_ports {out[6]}]
set_property PACKAGE_PIN V14 [get_ports {out[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {out[*]}]

## 1 Hz / 10 Hz selector
set_property IOSTANDARD LVCMOS33 [get_ports clksel]
set_property PACKAGE_PIN W15 [get_ports clksel]
set_property PULLDOWN true [get_ports clksel]

## Retired-instruction indicator LEDs
set_property PACKAGE_PIN P3 [get_ports {clk_ind[0]}]
set_property PACKAGE_PIN N3 [get_ports {clk_ind[1]}]
set_property PACKAGE_PIN P1 [get_ports {clk_ind[2]}]
set_property PACKAGE_PIN L1 [get_ports {clk_ind[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {clk_ind[*]}]

## Active-low seven-segment cathodes
set_property PACKAGE_PIN W7 [get_ports {seg[0]}]
set_property PACKAGE_PIN W6 [get_ports {seg[1]}]
set_property PACKAGE_PIN U8 [get_ports {seg[2]}]
set_property PACKAGE_PIN V8 [get_ports {seg[3]}]
set_property PACKAGE_PIN U5 [get_ports {seg[4]}]
set_property PACKAGE_PIN V5 [get_ports {seg[5]}]
set_property PACKAGE_PIN U7 [get_ports {seg[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {seg[*]}]

## Seven-segment anodes (rightmost digit enabled)
set_property PACKAGE_PIN U2 [get_ports {an[0]}]
set_property PACKAGE_PIN U4 [get_ports {an[1]}]
set_property PACKAGE_PIN V4 [get_ports {an[2]}]
set_property PACKAGE_PIN W4 [get_ports {an[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {an[*]}]

