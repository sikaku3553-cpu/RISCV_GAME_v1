`timescale 1ns/1ps
`default_nettype none

// Direct ImmGen boundary checks for every RV32I immediate layout.
module tb_v2_immediates;
    reg  [31:0] instruction;
    wire [31:0] immediate;

    `include "rv32i_encode.vh"

    ImmGenV2 dut (
        .instruction(instruction),
        .immediate(immediate)
    );

    task automatic expect_immediate;
        input [31:0] encoded;
        input [31:0] expected;
        input [8*32-1:0] description;
        begin
            instruction = encoded;
            #1;
            if (immediate !== expected)
                $fatal(1, "%0s: expected=%08x actual=%08x instruction=%08x",
                       description, expected, immediate, instruction);
        end
    endtask

    initial begin
        expect_immediate(rv32_i(32'd2047, 5'd1, 3'b000, 5'd2, RV32_OPCODE_OP_IMM),
                         32'h0000_07ff, "I positive maximum");
        expect_immediate(rv32_i(-32'sd2048, 5'd1, 3'b000, 5'd2, RV32_OPCODE_OP_IMM),
                         32'hffff_f800, "I negative minimum");
        expect_immediate(rv32_i(-32'sd2048, 5'd1, 3'b000, 5'd2, RV32_OPCODE_JALR),
                         32'hffff_f800, "JALR I negative minimum");

        expect_immediate(rv32_s(32'd2047, 5'd2, 5'd1, 3'b010, RV32_OPCODE_STORE),
                         32'h0000_07ff, "S positive maximum");
        expect_immediate(rv32_s(-32'sd2048, 5'd2, 5'd1, 3'b010, RV32_OPCODE_STORE),
                         32'hffff_f800, "S negative minimum");

        expect_immediate(rv32_b(32'd4094, 5'd2, 5'd1, 3'b000, RV32_OPCODE_BRANCH),
                         32'h0000_0ffe, "B positive maximum");
        expect_immediate(rv32_b(-32'sd4096, 5'd2, 5'd1, 3'b000, RV32_OPCODE_BRANCH),
                         32'hffff_f000, "B negative minimum");

        expect_immediate(rv32_u(20'h80000, 5'd1, RV32_OPCODE_LUI),
                         32'h8000_0000, "U high sign bit");
        expect_immediate(rv32_u(20'hfffff, 5'd1, RV32_OPCODE_AUIPC),
                         32'hffff_f000, "U all immediate bits");

        expect_immediate(rv32_j(32'd1048574, 5'd1, RV32_OPCODE_JAL),
                         32'h000f_fffe, "J positive maximum");
        expect_immediate(rv32_j(-32'sd1048576, 5'd1, RV32_OPCODE_JAL),
                         32'hfff0_0000, "J negative minimum");

        $display("PASS: tb_v2_immediates (I/S/B/U/J encoded range boundaries)");
        $finish;
    end
endmodule

`default_nettype wire

