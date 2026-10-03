`timescale 1ns/1ps
`default_nettype none

// Parameterized Harvard instruction ROM. The board configuration retains the
// 64-word v1.1 size; testbenches may select a larger value.
module InstructionMemoryV2 #(
    parameter integer WORDS = 64,
    parameter integer INIT_DEMO = 1,
    parameter INIT_FILE = ""
) (
    input  wire [31:0] address,
    output wire [31:0] instruction
);
    localparam [31:0] NOP = 32'h0000_0013;

    reg [31:0] memory [0:WORDS-1];
    integer i;

    initial begin
        for (i = 0; i < WORDS; i = i + 1)
            memory[i] = NOP;

        if (INIT_DEMO != 0 && WORDS >= 9) begin
            // TD8-visible v2 demo. New XORI, SLLI, SB, LBU and JAL paths are
            // exercised while retaining the switch/LED interaction.
            memory[0]  = 32'h1000_0093; // addi x1, x0, 0x100
            memory[1]  = 32'h1040_0113; // addi x2, x0, 0x104
            memory[2]  = 32'h0000_A183; // lw   x3, 0(x1)
            memory[3]  = 32'h05A1_C193; // xori x3, x3, 0x05a
            memory[4]  = 32'h0011_9193; // slli x3, x3, 1
            memory[5]  = 32'h0030_00A3; // sb   x3, 1(x0)
            memory[6]  = 32'h0010_4203; // lbu  x4, 1(x0)
            memory[7]  = 32'h0041_2023; // sw   x4, 0(x2)
            memory[8]  = 32'hFE9F_F06F; // jal  x0, -24 (back to lw)
        end

        if (INIT_FILE != "")
            $readmemh(INIT_FILE, memory);
    end

    assign instruction = (address[31:2] < WORDS)
                       ? memory[address[31:2]]
                       : NOP;
endmodule

`default_nettype wire

