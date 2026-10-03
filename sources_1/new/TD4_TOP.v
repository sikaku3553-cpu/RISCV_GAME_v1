`timescale 1ns/1ps
`default_nettype none

// Compatibility wrapper retaining the original TD8 Vivado top-module name.
module TD4_TOP #(
    parameter integer CLOCK_HZ = 100_000_000
) (
    input  wire       clk,
    input  wire       reset,
    input  wire [7:0] in,
    input  wire       clksel,
    output wire [7:0] out,
    output wire [3:0] clk_ind,
    output wire [6:0] seg,
    output wire [3:0] an
);
    TD8_RAM_TO_RISCV_V2_TOP #(.CLOCK_HZ(CLOCK_HZ)) implementation (
        .clk(clk),
        .reset(reset),
        .in(in),
        .clksel(clksel),
        .out(out),
        .clk_ind(clk_ind),
        .seg(seg),
        .an(an)
    );
endmodule

`default_nettype wire

