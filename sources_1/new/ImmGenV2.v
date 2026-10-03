`timescale 1ns/1ps
`default_nettype none

// Immediate generator for all five RV32I immediate encodings.
module ImmGenV2 (
    input  wire [31:0] instruction,
    output reg  [31:0] immediate
);
    wire [6:0] opcode = instruction[6:0];

    always @(*) begin
        case (opcode)
            7'b0010011, // OP-IMM
            7'b0000011, // LOAD
            7'b1100111: // JALR
                immediate = {{20{instruction[31]}}, instruction[31:20]};

            7'b0100011: // STORE
                immediate = {{20{instruction[31]}}, instruction[31:25], instruction[11:7]};

            7'b1100011: // BRANCH
                immediate = {{19{instruction[31]}}, instruction[31], instruction[7],
                             instruction[30:25], instruction[11:8], 1'b0};

            7'b0110111, // LUI
            7'b0010111: // AUIPC
                immediate = {instruction[31:12], 12'd0};

            7'b1101111: // JAL
                immediate = {{11{instruction[31]}}, instruction[31], instruction[19:12],
                             instruction[20], instruction[30:21], 1'b0};

            default:
                immediate = 32'd0;
        endcase
    end
endmodule

`default_nettype wire

