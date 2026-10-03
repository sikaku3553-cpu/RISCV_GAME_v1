`timescale 1ns/1ps
`default_nettype none

// Basys 3 board top.  btnC is reset; the other buttons and a PS/2 keyboard
// are merged into the five-bit logical game input.  The CPU is deliberately
// tied on at the full board clock instead of the v2 1/10 Hz observation rate.
module TD8_RISCV_GAME_TOP #(
    parameter IMEM_INIT_FILE = "firmware/build/imem_game.hex",
    parameter integer DEBOUNCE_CYCLES = 100_000,
    parameter integer DEBOUNCE_BITS = 17
) (
    input  wire        clk,
    input  wire        btnC,
    input  wire        btnU,
    input  wire        btnD,
    input  wire        btnL,
    input  wire        btnR,
    input  wire [15:0] sw,
    input  wire        PS2Clk,
    input  wire        PS2Data,
    output wire [15:0] led,
    output wire [3:0]  vgaRed,
    output wire [3:0]  vgaGreen,
    output wire [3:0]  vgaBlue,
    output wire        Hsync,
    output wire        Vsync
);
    wire reset;
    ResetSynchronizerV3 reset_sync (
        .clk(clk),
        .async_reset(btnC),
        .reset(reset)
    );

    wire button_up;
    wire button_down;
    wire button_left;
    wire button_right;

    DebounceInputV3 #(
        .STABLE_CYCLES(DEBOUNCE_CYCLES),
        .COUNTER_BITS(DEBOUNCE_BITS)
    ) debounce_up (
        .clk(clk), .reset(reset), .async_input(btnU),
        .debounced(button_up)
    );
    DebounceInputV3 #(
        .STABLE_CYCLES(DEBOUNCE_CYCLES),
        .COUNTER_BITS(DEBOUNCE_BITS)
    ) debounce_down (
        .clk(clk), .reset(reset), .async_input(btnD),
        .debounced(button_down)
    );
    DebounceInputV3 #(
        .STABLE_CYCLES(DEBOUNCE_CYCLES),
        .COUNTER_BITS(DEBOUNCE_BITS)
    ) debounce_left (
        .clk(clk), .reset(reset), .async_input(btnL),
        .debounced(button_left)
    );
    DebounceInputV3 #(
        .STABLE_CYCLES(DEBOUNCE_CYCLES),
        .COUNTER_BITS(DEBOUNCE_BITS)
    ) debounce_right (
        .clk(clk), .reset(reset), .async_input(btnR),
        .debounced(button_right)
    );

    wire [15:0] synchronized_switches;
    InputSynchronizerV3 #(.WIDTH(16)) switch_sync (
        .clk(clk),
        .async_input(sw),
        .sync_output(synchronized_switches)
    );

    wire [4:0] ps2_keys;
    wire [7:0] last_scan_code;
    wire       scan_valid;
    wire       parity_error;
    PS2KeyboardV3 keyboard (
        .clk(clk),
        .reset(reset),
        .ps2_clk(PS2Clk),
        .ps2_data(PS2Data),
        .keys(ps2_keys),
        .last_scan_code(last_scan_code),
        .scan_valid(scan_valid),
        .parity_error(parity_error)
    );

    // bits 0..4: left, right, jump/up, down, action/restart.
    // sw[15] provides an action input when no keyboard is attached.
    wire [4:0] logical_game_input = {
        ps2_keys[4] | synchronized_switches[15],
        ps2_keys[3] | button_down,
        ps2_keys[2] | button_up,
        ps2_keys[1] | button_right,
        ps2_keys[0] | button_left
    };

    wire [15:0] firmware_leds;
    wire        cpu_fault;
    wire        unused_pipeline_stalled;
    wire [31:0] unused_debug_pc;
    wire [31:0] unused_debug_instruction;
    wire [4:0]  unused_debug_trap_cause;
    wire [31:0] unused_debug_trap_value;
    wire [31:0] unused_cycle_count;
    wire [31:0] unused_instret_count;
    wire [31:0] unused_stall_count;
    wire [31:0] unused_flush_count;
    wire [31:0] unused_frame_count;
    wire [31:0] unused_game_status;
    wire        unused_frame_tick;
    wire        unused_commit_pending;

    // Reserve the top LED as a sticky-visible CPU fault indicator while
    // retaining all firmware-controlled LEDs during normal operation.
    assign led = {firmware_leds[15] | cpu_fault, firmware_leds[14:0]};

    TD8_RISCV_GAME_SOC #(
        .IMEM_INIT_FILE(IMEM_INIT_FILE)
    ) game_soc (
        .clk(clk),
        .reset(reset),
        .cpu_enable(1'b1),
        .switch_state(synchronized_switches),
        .game_input_state(logical_game_input),
        .ps2_scan_code(last_scan_code),
        .ps2_scan_valid(scan_valid),
        .ps2_parity_error(parity_error),
        .led_output(firmware_leds),
        .vgaRed(vgaRed),
        .vgaGreen(vgaGreen),
        .vgaBlue(vgaBlue),
        .Hsync(Hsync),
        .Vsync(Vsync),
        .cpu_fault(cpu_fault),
        .pipeline_stalled(unused_pipeline_stalled),
        .debug_pc(unused_debug_pc),
        .debug_instruction(unused_debug_instruction),
        .debug_trap_cause(unused_debug_trap_cause),
        .debug_trap_value(unused_debug_trap_value),
        .cycle_count(unused_cycle_count),
        .instret_count(unused_instret_count),
        .stall_count(unused_stall_count),
        .flush_count(unused_flush_count),
        .frame_count(unused_frame_count),
        .active_game_status(unused_game_status),
        .frame_tick_out(unused_frame_tick),
        .commit_pending_out(unused_commit_pending)
    );
endmodule

`default_nettype wire
