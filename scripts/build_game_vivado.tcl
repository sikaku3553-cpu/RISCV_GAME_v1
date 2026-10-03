# Vivado batch build for TD8_RISCV_GAME_TOP on a Digilent Basys 3.
#
# Run from any directory:
#   vivado -mode batch -source scripts/build_game_vivado.tcl
#
# This script performs synthesis, implementation, bitstream generation, and
# writes timing/utilization reports.  A generated report is evidence from that
# particular Vivado/device run; this script itself is not a timing guarantee.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set build_dir  [file join $repo_root build game_vivado]
set report_dir [file join $build_dir reports]
file mkdir $build_dir
file mkdir $report_dir
cd $repo_root

set part_name xc7a35tcpg236-1
set top_name TD8_RISCV_GAME_TOP
set xdc_file [file join $repo_root constrs_1 new TD8_RISCV_GAME_TOP.xdc]
set firmware_hex [file join $repo_root firmware build imem_game.hex]
set rtl_files [lsort [glob -nocomplain [file join $repo_root sources_1 new *.v]]]

if {[llength $rtl_files] == 0} {
    error "No Verilog sources found under sources_1/new"
}
if {![file exists $xdc_file]} {
    error "Missing constraints file: $xdc_file"
}
if {![file exists $firmware_hex]} {
    error "Missing firmware image: $firmware_hex (run firmware/build.ps1 first)"
}

# Use an in-process, non-project flow.  Besides being reproducible, this avoids
# Vivado's run-manager helper process and keeps every output below build/.
# The top-level default IMEM_INIT_FILE is relative to repo_root, which is why
# this script changes to that directory before synthesis.
read_verilog $rtl_files
synth_design -top $top_name -part $part_name
read_xdc $xdc_file

write_checkpoint -force [file join $build_dir TD8_RISCV_GAME_TOP_synth.dcp]
report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $report_dir post_synth_timing_summary.rpt]
report_utilization -hierarchical \
    -file [file join $report_dir post_synth_utilization.rpt]
report_ram_utilization \
    -file [file join $report_dir post_synth_ram_utilization.rpt]
report_cdc -details \
    -file [file join $report_dir post_synth_cdc.rpt]

opt_design
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $report_dir post_route_timing_summary.rpt]
report_timing -delay_type max -sort_by slack -max_paths 20 \
    -file [file join $report_dir post_route_timing_max20.rpt]
report_utilization -hierarchical \
    -file [file join $report_dir post_route_utilization.rpt]
report_clock_utilization \
    -file [file join $report_dir post_route_clock_utilization.rpt]
report_ram_utilization \
    -file [file join $report_dir post_route_ram_utilization.rpt]
report_drc -file [file join $report_dir post_route_drc.rpt]
report_methodology -file [file join $report_dir post_route_methodology.rpt]
write_checkpoint -force [file join $build_dir TD8_RISCV_GAME_TOP_routed.dcp]
write_bitstream -force [file join $build_dir ${top_name}.bit]

puts "Build complete. Inspect post_route_timing_summary.rpt and"
puts "post_route_timing_max20.rpt before claiming 100 MHz timing closure."
