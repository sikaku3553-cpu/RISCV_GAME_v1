`timescale 1ns/1ps
`default_nettype none

// Exhaustive instruction-name coverage plus representative reserved/extension
// encodings. End-to-end behavior is checked by the other testbenches.
module tb_v2_decoder;
    reg  [31:0] instruction;
    wire        legal;
    wire [3:0]  alu_control;
    wire [1:0]  alu_a_select;
    wire        alu_b_immediate;
    wire        reg_write;
    wire [1:0]  result_select;
    wire        mem_read;
    wire        mem_write;
    wire [1:0]  mem_size;
    wire        load_unsigned;
    wire        branch;
    wire [2:0]  branch_funct3;
    wire        jump;
    wire        jalr;
    wire        fence;
    wire        ecall;
    wire        ebreak;
    integer legal_count;

    `include "rv32i_encode.vh"

    DecoderV2 dut (
        .instruction(instruction), .legal(legal), .alu_control(alu_control),
        .alu_a_select(alu_a_select), .alu_b_immediate(alu_b_immediate),
        .reg_write(reg_write), .result_select(result_select),
        .mem_read(mem_read), .mem_write(mem_write), .mem_size(mem_size),
        .load_unsigned(load_unsigned), .branch(branch),
        .branch_funct3(branch_funct3), .jump(jump), .jalr(jalr),
        .fence(fence), .ecall(ecall), .ebreak(ebreak)
    );

    task automatic expect_legal;
        input [31:0] value;
        input [8*24-1:0] name;
        begin
            instruction = value;
            #1;
            if (legal !== 1'b1)
                $fatal(1, "%0s was rejected: %08x", name, value);
            legal_count = legal_count + 1;
        end
    endtask

    task automatic expect_illegal;
        input [31:0] value;
        input [8*32-1:0] name;
        begin
            instruction = value;
            #1;
            if (legal !== 1'b0)
                $fatal(1, "%0s was accepted: %08x", name, value);
            if (reg_write || mem_read || mem_write || branch || jump || fence || ecall || ebreak)
                $fatal(1, "%0s produced a side-effect control", name);
        end
    endtask

    initial begin
        legal_count = 0;

        // 2 upper-immediate instructions.
        expect_legal(rv32_u(20'h12345, 5'd1, RV32_OPCODE_LUI), "LUI");
        expect_legal(rv32_u(20'h12345, 5'd1, RV32_OPCODE_AUIPC), "AUIPC");

        // 2 jumps.
        expect_legal(rv32_j(32'd8, 5'd1, RV32_OPCODE_JAL), "JAL");
        expect_legal(rv32_i(32'd0, 5'd1, 3'b000, 5'd1, RV32_OPCODE_JALR), "JALR");

        // 6 branches.
        expect_legal(rv32_b(32'd4, 5'd2, 5'd1, 3'b000, RV32_OPCODE_BRANCH), "BEQ");
        expect_legal(rv32_b(32'd4, 5'd2, 5'd1, 3'b001, RV32_OPCODE_BRANCH), "BNE");
        expect_legal(rv32_b(32'd4, 5'd2, 5'd1, 3'b100, RV32_OPCODE_BRANCH), "BLT");
        expect_legal(rv32_b(32'd4, 5'd2, 5'd1, 3'b101, RV32_OPCODE_BRANCH), "BGE");
        expect_legal(rv32_b(32'd4, 5'd2, 5'd1, 3'b110, RV32_OPCODE_BRANCH), "BLTU");
        expect_legal(rv32_b(32'd4, 5'd2, 5'd1, 3'b111, RV32_OPCODE_BRANCH), "BGEU");

        // 5 loads and 3 stores.
        expect_legal(rv32_i(0, 5'd1, 3'b000, 5'd2, RV32_OPCODE_LOAD), "LB");
        expect_legal(rv32_i(0, 5'd1, 3'b001, 5'd2, RV32_OPCODE_LOAD), "LH");
        expect_legal(rv32_i(0, 5'd1, 3'b010, 5'd2, RV32_OPCODE_LOAD), "LW");
        expect_legal(rv32_i(0, 5'd1, 3'b100, 5'd2, RV32_OPCODE_LOAD), "LBU");
        expect_legal(rv32_i(0, 5'd1, 3'b101, 5'd2, RV32_OPCODE_LOAD), "LHU");
        expect_legal(rv32_s(0, 5'd2, 5'd1, 3'b000, RV32_OPCODE_STORE), "SB");
        expect_legal(rv32_s(0, 5'd2, 5'd1, 3'b001, RV32_OPCODE_STORE), "SH");
        expect_legal(rv32_s(0, 5'd2, 5'd1, 3'b010, RV32_OPCODE_STORE), "SW");

        // 9 OP-IMM instructions.
        expect_legal(rv32_i(1, 5'd1, 3'b000, 5'd2, RV32_OPCODE_OP_IMM), "ADDI");
        expect_legal(rv32_i(1, 5'd1, 3'b010, 5'd2, RV32_OPCODE_OP_IMM), "SLTI");
        expect_legal(rv32_i(1, 5'd1, 3'b011, 5'd2, RV32_OPCODE_OP_IMM), "SLTIU");
        expect_legal(rv32_i(1, 5'd1, 3'b100, 5'd2, RV32_OPCODE_OP_IMM), "XORI");
        expect_legal(rv32_i(1, 5'd1, 3'b110, 5'd2, RV32_OPCODE_OP_IMM), "ORI");
        expect_legal(rv32_i(1, 5'd1, 3'b111, 5'd2, RV32_OPCODE_OP_IMM), "ANDI");
        expect_legal(rv32_i(12'h01f, 5'd1, 3'b001, 5'd2, RV32_OPCODE_OP_IMM), "SLLI");
        expect_legal(rv32_i(12'h01f, 5'd1, 3'b101, 5'd2, RV32_OPCODE_OP_IMM), "SRLI");
        expect_legal(rv32_i(12'h41f, 5'd1, 3'b101, 5'd2, RV32_OPCODE_OP_IMM), "SRAI");

        // 10 OP instructions.
        expect_legal(rv32_r(7'h00, 2, 1, 3'b000, 3, RV32_OPCODE_OP), "ADD");
        expect_legal(rv32_r(7'h20, 2, 1, 3'b000, 3, RV32_OPCODE_OP), "SUB");
        expect_legal(rv32_r(7'h00, 2, 1, 3'b001, 3, RV32_OPCODE_OP), "SLL");
        expect_legal(rv32_r(7'h00, 2, 1, 3'b010, 3, RV32_OPCODE_OP), "SLT");
        expect_legal(rv32_r(7'h00, 2, 1, 3'b011, 3, RV32_OPCODE_OP), "SLTU");
        expect_legal(rv32_r(7'h00, 2, 1, 3'b100, 3, RV32_OPCODE_OP), "XOR");
        expect_legal(rv32_r(7'h00, 2, 1, 3'b101, 3, RV32_OPCODE_OP), "SRL");
        expect_legal(rv32_r(7'h20, 2, 1, 3'b101, 3, RV32_OPCODE_OP), "SRA");
        expect_legal(rv32_r(7'h00, 2, 1, 3'b110, 3, RV32_OPCODE_OP), "OR");
        expect_legal(rv32_r(7'h00, 2, 1, 3'b111, 3, RV32_OPCODE_OP), "AND");

        // FENCE must ignore reserved rs1/rd/fm fields. SYSTEM stays exact.
        expect_legal(32'hffff_8f8f, "FENCE reserved fields");
        expect_legal(32'h0000_0073, "ECALL");
        expect_legal(32'h0010_0073, "EBREAK");

        if (legal_count != 40)
            $fatal(1, "RV32I legal coverage count=%0d, expected 40", legal_count);

        // Representative invalid and extension encodings.
        expect_illegal(rv32_r(7'h01, 2, 1, 3'b000, 3, RV32_OPCODE_OP), "MUL (M extension)");
        expect_illegal(rv32_r(7'h10, 2, 1, 3'b000, 3, RV32_OPCODE_OP), "OP reserved funct7");
        expect_illegal(rv32_i(12'h020, 1, 3'b001, 2, RV32_OPCODE_OP_IMM), "SLLI bad upper bits");
        expect_illegal(rv32_i(12'h21f, 1, 3'b101, 2, RV32_OPCODE_OP_IMM), "right shift bad upper bits");
        expect_illegal(rv32_b(4, 2, 1, 3'b010, RV32_OPCODE_BRANCH), "BRANCH reserved funct3 010");
        expect_illegal(rv32_b(4, 2, 1, 3'b011, RV32_OPCODE_BRANCH), "BRANCH reserved funct3 011");
        expect_illegal(rv32_i(0, 1, 3'b011, 2, RV32_OPCODE_LOAD), "LOAD reserved funct3");
        expect_illegal(rv32_s(0, 2, 1, 3'b011, RV32_OPCODE_STORE), "STORE reserved funct3");
        expect_illegal(rv32_i(0, 1, 3'b001, 2, RV32_OPCODE_JALR), "JALR bad funct3");
        expect_illegal(32'h0000_100f, "FENCE.I (Zifencei)");
        expect_illegal(32'h0000_2073, "CSRRS (Zicsr)");
        expect_illegal(32'h0020_0073, "reserved SYSTEM immediate");
        expect_illegal(32'hffff_ffff, "unknown opcode");

        $display("PASS: tb_v2_decoder (40 RV32I names + strict extension/reserved rejection)");
        $finish;
    end
endmodule

`default_nettype wire

