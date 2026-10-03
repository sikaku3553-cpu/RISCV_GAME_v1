`timescale 1ns/1ps
`default_nettype none

// Board-facing v2 top. External ports remain compatible with the TD8 design.
module TD8_RAM_TO_RISCV_V2_TOP #(
    parameter integer CLOCK_HZ = 100_000_000
) (
    input  wire       clk,
    input  wire       reset,
    input  wire [7:0] in,
    input  wire       clksel,
    output wire [7:0] out,
    output reg  [3:0] clk_ind,
    output wire [6:0] seg,
    output wire [3:0] an
);
    wire enable_1hz;
    wire enable_10hz;
    wire enable_cpu;
    wire [31:0] unused_pc;
    wire [31:0] unused_instruction;
    wire [31:0] unused_reg_data;
    wire [31:0] unused_mem_word0;
    wire [4:0]  unused_trap_cause;
    wire [31:0] unused_trap_value;
    wire core_fault;
    wire core_retire_valid;
    wire [31:0] unused_retire_pc;
    wire [31:0] unused_retire_instruction;

    ClockEnableV2 #(.DIVISOR(CLOCK_HZ / 1)) enable_slow (
        .clk(clk),
        .reset(reset),
        .enable_pulse(enable_1hz)
    );

    ClockEnableV2 #(.DIVISOR(CLOCK_HZ / 10)) enable_fast (
        .clk(clk),
        .reset(reset),
        .enable_pulse(enable_10hz)
    );

    assign enable_cpu = clksel ? enable_10hz : enable_1hz;
    assign an = 4'b1110;

    TD8_RISCV_V2_Core #(
        .IMEM_WORDS(64),
        .INIT_DEMO(1),
        .ENABLE_RF_DEBUG(0),
        .ENABLE_MEM_DEBUG(0)
    ) cpu (
        .clk(clk),
        .reset(reset),
        .cpu_enable(enable_cpu),
        .input_port(in),
        .debug_reg_addr(5'd3),
        .output_port(out),
        .debug_pc(unused_pc),
        .debug_instruction(unused_instruction),
        .debug_reg_data(unused_reg_data),
        .debug_mem_word0(unused_mem_word0),
        .debug_trap_cause(unused_trap_cause),
        .debug_trap_value(unused_trap_value),
        .fault(core_fault),
        .retire_valid(core_retire_valid),
        .retire_pc(unused_retire_pc),
        .retire_instruction(unused_retire_instruction)
    );

    SEG7V2 seven_segment (
        .data(out[3:0]),
        .seg(seg)
    );

    always @(posedge clk or posedge reset) begin
        if (reset)
            clk_ind <= 4'd0;
        else if (core_retire_valid)
            clk_ind <= clk_ind + 4'd1;
    end
endmodule

`default_nettype wire
