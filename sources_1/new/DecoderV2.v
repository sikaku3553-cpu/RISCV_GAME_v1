`timescale 1ns/1ps
`default_nettype none

// Strict decoder for the complete unprivileged RV32I base instruction set.
// Zicsr, Zifencei and every optional extension are intentionally excluded.
module DecoderV2 (
    input  wire [31:0] instruction,
    output reg         legal,
    output reg  [3:0]  alu_control,
    output reg  [1:0]  alu_a_select,
    output reg         alu_b_immediate,
    output reg         reg_write,
    output reg  [1:0]  result_select,
    output reg         mem_read,
    output reg         mem_write,
    output reg  [1:0]  mem_size,
    output reg         load_unsigned,
    output reg         branch,
    output reg  [2:0]  branch_funct3,
    output reg         jump,
    output reg         jalr,
    output reg         fence,
    output reg         ecall,
    output reg         ebreak
);
    localparam [3:0] ALU_ADD  = 4'd0;
    localparam [3:0] ALU_SUB  = 4'd1;
    localparam [3:0] ALU_SLL  = 4'd2;
    localparam [3:0] ALU_SLT  = 4'd3;
    localparam [3:0] ALU_SLTU = 4'd4;
    localparam [3:0] ALU_XOR  = 4'd5;
    localparam [3:0] ALU_SRL  = 4'd6;
    localparam [3:0] ALU_SRA  = 4'd7;
    localparam [3:0] ALU_OR   = 4'd8;
    localparam [3:0] ALU_AND  = 4'd9;

    localparam [1:0] ALU_A_RS1  = 2'd0;
    localparam [1:0] ALU_A_PC   = 2'd1;
    localparam [1:0] ALU_A_ZERO = 2'd2;

    localparam [1:0] RESULT_ALU = 2'd0;
    localparam [1:0] RESULT_MEM = 2'd1;
    localparam [1:0] RESULT_PC4 = 2'd2;

    localparam [1:0] SIZE_BYTE = 2'd0;
    localparam [1:0] SIZE_HALF = 2'd1;
    localparam [1:0] SIZE_WORD = 2'd2;

    wire [6:0] opcode = instruction[6:0];
    wire [2:0] funct3 = instruction[14:12];
    wire [6:0] funct7 = instruction[31:25];

    always @(*) begin
        // Safe defaults ensure an illegal instruction has no side effect.
        legal           = 1'b0;
        alu_control     = ALU_ADD;
        alu_a_select    = ALU_A_RS1;
        alu_b_immediate = 1'b0;
        reg_write       = 1'b0;
        result_select   = RESULT_ALU;
        mem_read        = 1'b0;
        mem_write       = 1'b0;
        mem_size        = SIZE_WORD;
        load_unsigned   = 1'b0;
        branch          = 1'b0;
        branch_funct3   = funct3;
        jump            = 1'b0;
        jalr            = 1'b0;
        fence           = 1'b0;
        ecall           = 1'b0;
        ebreak          = 1'b0;

        case (opcode)
            7'b0110111: begin // LUI
                legal           = 1'b1;
                reg_write       = 1'b1;
                alu_a_select    = ALU_A_ZERO;
                alu_b_immediate = 1'b1;
            end

            7'b0010111: begin // AUIPC
                legal           = 1'b1;
                reg_write       = 1'b1;
                alu_a_select    = ALU_A_PC;
                alu_b_immediate = 1'b1;
            end

            7'b1101111: begin // JAL
                legal         = 1'b1;
                reg_write     = 1'b1;
                result_select = RESULT_PC4;
                jump          = 1'b1;
            end

            7'b1100111: begin // JALR
                if (funct3 == 3'b000) begin
                    legal         = 1'b1;
                    reg_write     = 1'b1;
                    result_select = RESULT_PC4;
                    jump          = 1'b1;
                    jalr          = 1'b1;
                end
            end

            7'b1100011: begin // conditional branches
                case (funct3)
                    3'b000, // BEQ
                    3'b001, // BNE
                    3'b100, // BLT
                    3'b101, // BGE
                    3'b110, // BLTU
                    3'b111: begin // BGEU
                        legal  = 1'b1;
                        branch = 1'b1;
                    end
                    default: ;
                endcase
            end

            7'b0000011: begin // LOAD
                case (funct3)
                    3'b000: begin legal = 1'b1; mem_size = SIZE_BYTE; load_unsigned = 1'b0; end // LB
                    3'b001: begin legal = 1'b1; mem_size = SIZE_HALF; load_unsigned = 1'b0; end // LH
                    3'b010: begin legal = 1'b1; mem_size = SIZE_WORD; load_unsigned = 1'b0; end // LW
                    3'b100: begin legal = 1'b1; mem_size = SIZE_BYTE; load_unsigned = 1'b1; end // LBU
                    3'b101: begin legal = 1'b1; mem_size = SIZE_HALF; load_unsigned = 1'b1; end // LHU
                    default: ;
                endcase
                if (legal) begin
                    reg_write       = 1'b1;
                    result_select   = RESULT_MEM;
                    mem_read        = 1'b1;
                    alu_b_immediate = 1'b1;
                    alu_control     = ALU_ADD;
                end
            end

            7'b0100011: begin // STORE
                case (funct3)
                    3'b000: begin legal = 1'b1; mem_size = SIZE_BYTE; end // SB
                    3'b001: begin legal = 1'b1; mem_size = SIZE_HALF; end // SH
                    3'b010: begin legal = 1'b1; mem_size = SIZE_WORD; end // SW
                    default: ;
                endcase
                if (legal) begin
                    mem_write       = 1'b1;
                    alu_b_immediate = 1'b1;
                    alu_control     = ALU_ADD;
                end
            end

            7'b0010011: begin // OP-IMM
                reg_write       = 1'b1;
                alu_b_immediate = 1'b1;
                case (funct3)
                    3'b000: begin legal = 1'b1; alu_control = ALU_ADD;  end // ADDI
                    3'b010: begin legal = 1'b1; alu_control = ALU_SLT;  end // SLTI
                    3'b011: begin legal = 1'b1; alu_control = ALU_SLTU; end // SLTIU
                    3'b100: begin legal = 1'b1; alu_control = ALU_XOR;  end // XORI
                    3'b110: begin legal = 1'b1; alu_control = ALU_OR;   end // ORI
                    3'b111: begin legal = 1'b1; alu_control = ALU_AND;  end // ANDI
                    3'b001: begin // SLLI
                        if (funct7 == 7'b0000000) begin
                            legal = 1'b1;
                            alu_control = ALU_SLL;
                        end
                    end
                    3'b101: begin
                        if (funct7 == 7'b0000000) begin
                            legal = 1'b1;
                            alu_control = ALU_SRL; // SRLI
                        end else if (funct7 == 7'b0100000) begin
                            legal = 1'b1;
                            alu_control = ALU_SRA; // SRAI
                        end
                    end
                    default: ;
                endcase
                if (!legal)
                    reg_write = 1'b0;
            end

            7'b0110011: begin // OP
                reg_write = 1'b1;
                case (funct3)
                    3'b000: begin
                        if (funct7 == 7'b0000000) begin legal = 1'b1; alu_control = ALU_ADD; end
                        else if (funct7 == 7'b0100000) begin legal = 1'b1; alu_control = ALU_SUB; end
                    end
                    3'b001: if (funct7 == 7'b0000000) begin legal = 1'b1; alu_control = ALU_SLL;  end
                    3'b010: if (funct7 == 7'b0000000) begin legal = 1'b1; alu_control = ALU_SLT;  end
                    3'b011: if (funct7 == 7'b0000000) begin legal = 1'b1; alu_control = ALU_SLTU; end
                    3'b100: if (funct7 == 7'b0000000) begin legal = 1'b1; alu_control = ALU_XOR;  end
                    3'b101: begin
                        if (funct7 == 7'b0000000) begin legal = 1'b1; alu_control = ALU_SRL; end
                        else if (funct7 == 7'b0100000) begin legal = 1'b1; alu_control = ALU_SRA; end
                    end
                    3'b110: if (funct7 == 7'b0000000) begin legal = 1'b1; alu_control = ALU_OR;  end
                    3'b111: if (funct7 == 7'b0000000) begin legal = 1'b1; alu_control = ALU_AND; end
                    default: ;
                endcase
                if (!legal)
                    reg_write = 1'b0;
            end

            7'b0001111: begin // FENCE. FENCE.I is in Zifencei and is excluded.
                if (funct3 == 3'b000) begin
                    legal = 1'b1;
                    fence = 1'b1;
                end
            end

            7'b1110011: begin // Base SYSTEM instructions only; no Zicsr.
                if (instruction == 32'h0000_0073) begin
                    legal = 1'b1;
                    ecall = 1'b1;
                end else if (instruction == 32'h0010_0073) begin
                    legal  = 1'b1;
                    ebreak = 1'b1;
                end
            end

            default: ;
        endcase
    end
endmodule

`default_nettype wire

