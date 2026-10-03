// RV32I instruction encoders shared by the v2 self-checking testbenches.
//
// Include this file inside a SystemVerilog module.  The immediate arguments
// are byte offsets for B/J formats and unshifted 32-bit values for I/S
// formats.  Each encoder keeps only the architectural immediate bits.

localparam [6:0] RV32_OPCODE_LOAD   = 7'b0000011;
localparam [6:0] RV32_OPCODE_MISC   = 7'b0001111;
localparam [6:0] RV32_OPCODE_OP_IMM = 7'b0010011;
localparam [6:0] RV32_OPCODE_AUIPC  = 7'b0010111;
localparam [6:0] RV32_OPCODE_STORE  = 7'b0100011;
localparam [6:0] RV32_OPCODE_OP     = 7'b0110011;
localparam [6:0] RV32_OPCODE_LUI    = 7'b0110111;
localparam [6:0] RV32_OPCODE_BRANCH = 7'b1100011;
localparam [6:0] RV32_OPCODE_JALR   = 7'b1100111;
localparam [6:0] RV32_OPCODE_JAL    = 7'b1101111;
localparam [6:0] RV32_OPCODE_SYSTEM = 7'b1110011;

localparam [31:0] RV32_NOP = 32'h0000_0013;

function automatic [31:0] rv32_r;
    input [6:0] funct7;
    input [4:0] rs2;
    input [4:0] rs1;
    input [2:0] funct3;
    input [4:0] rd;
    input [6:0] opcode;
    begin
        rv32_r = {funct7, rs2, rs1, funct3, rd, opcode};
    end
endfunction

function automatic [31:0] rv32_i;
    input [31:0] immediate;
    input [4:0] rs1;
    input [2:0] funct3;
    input [4:0] rd;
    input [6:0] opcode;
    begin
        rv32_i = {immediate[11:0], rs1, funct3, rd, opcode};
    end
endfunction

function automatic [31:0] rv32_s;
    input [31:0] immediate;
    input [4:0] rs2;
    input [4:0] rs1;
    input [2:0] funct3;
    input [6:0] opcode;
    begin
        rv32_s = {immediate[11:5], rs2, rs1, funct3,
                  immediate[4:0], opcode};
    end
endfunction

function automatic [31:0] rv32_b;
    input [31:0] byte_offset;
    input [4:0] rs2;
    input [4:0] rs1;
    input [2:0] funct3;
    input [6:0] opcode;
    begin
        rv32_b = {byte_offset[12], byte_offset[10:5], rs2, rs1,
                  funct3, byte_offset[4:1], byte_offset[11], opcode};
    end
endfunction

function automatic [31:0] rv32_u;
    input [19:0] immediate_upper;
    input [4:0] rd;
    input [6:0] opcode;
    begin
        rv32_u = {immediate_upper, rd, opcode};
    end
endfunction

function automatic [31:0] rv32_j;
    input [31:0] byte_offset;
    input [4:0] rd;
    input [6:0] opcode;
    begin
        rv32_j = {byte_offset[20], byte_offset[10:1], byte_offset[11],
                  byte_offset[19:12], rd, opcode};
    end
endfunction

