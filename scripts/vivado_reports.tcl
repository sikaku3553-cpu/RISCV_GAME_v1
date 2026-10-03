# Run after synthesis and implementation have completed in the v2 Vivado project.
set expected_part "xc7a35tcpg236-1"
set actual_part [get_property PART [current_project]]
if {![string equal -nocase $actual_part $expected_part]} {
    error "Wrong Vivado project part: expected $expected_part, got $actual_part"
}

set source_files [get_files -of_objects [get_filesets sources_1]]
set has_v2_core 0
set old_v1_files {}
foreach source_file $source_files {
    set source_tail [file tail $source_file]
    if {$source_tail eq "TD8_RISCV_V2_Core.v"} {
        set has_v2_core 1
    }
    if {[string match "*V1*" $source_tail]} {
        lappend old_v1_files $source_tail
    }
}
if {!$has_v2_core} {
    error "TD8_RISCV_V2_Core.v is absent; refusing to report a non-v2 project"
}
if {[llength $old_v1_files] != 0} {
    error "Old v1 RTL is mixed into the v2 project: $old_v1_files"
}

set actual_top [get_property TOP [get_filesets sources_1]]
if {$actual_top ne "TD4_TOP"} {
    error "Wrong synthesis top: expected TD4_TOP, got $actual_top"
}

set report_dir [file normalize "reports/v2"]
file mkdir $report_dir

open_run synth_1
report_utilization -hierarchical -file [file join $report_dir utilization_synth_hierarchical.rpt]
report_ram_utilization -include_lutram -file [file join $report_dir ram_utilization_synth.rpt]

open_run impl_1
report_utilization -hierarchical -file [file join $report_dir utilization_impl_hierarchical.rpt]
report_ram_utilization -include_lutram -file [file join $report_dir ram_utilization_impl.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose \
    -max_paths 50 -input_pins -file [file join $report_dir timing_summary_impl.rpt]
report_pulse_width -file [file join $report_dir pulse_width_impl.rpt]
report_power -file [file join $report_dir power_impl.rpt]

puts "v2 reports written to $report_dir"

