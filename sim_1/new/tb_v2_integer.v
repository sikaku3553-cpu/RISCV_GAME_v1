`timescale 1ns/1ps
`default_nettype none

// End-to-end execution test for every RV32I OP and OP-IMM instruction, plus
// LUI, AUIPC and the single-hart FENCE no-op behavior.
module tb_v2_integer;
    localparam integer IMEM_WORDS = 64;
    localparam integer EXECUTED_INSTRUCTIONS = 38;

    reg         clk;
    reg         reset;
    reg         cpu_enable;
    reg  [7:0]  input_port;
    reg  [4:0]  debug_reg_addr;
    wire [7:0]  output_port;
    wire [31:0] debug_pc;
    wire [31:0] debug_instruction;
    wire [31:0] debug_reg_data;
    wire [31:0] debug_mem_word0;
    wire [4:0]  debug_trap_cause;
    wire [31:0] debug_trap_value;
    wire        fault;
    wire        retire_valid;

    integer i;

    `include "rv32i_encode.vh"

    TD8_RISCV_V2_Core #(
        .IMEM_WORDS(IMEM_WORDS),
        .INIT_DEMO(0),
        .ENABLE_RF_DEBUG(1),
        .ENABLE_MEM_DEBUG(1)
    ) dut (
        .clk(clk),
        .reset(reset),
        .cpu_enable(cpu_enable),
        .input_port(input_port),
        .debug_reg_addr(debug_reg_addr),
        .output_port(output_port),
        .debug_pc(debug_pc),
        .debug_instruction(debug_instruction),
        .debug_reg_data(debug_reg_data),
        .debug_mem_word0(debug_mem_word0),
        .debug_trap_cause(debug_trap_cause),
        .debug_trap_value(debug_trap_value),
        .fault(fault),
        .retire_valid(retire_valid)
    );

    always #5 clk = ~clk;

    task automatic expect_register;
        input [4:0]  address;
        input [31:0] expected;
        begin
            debug_reg_addr = address;
            #1;
            if (debug_reg_data !== expected) begin
                $fatal(1,
                       "x%0d mismatch: expected=%08x actual=%08x pc=%08x",
                       address, expected, debug_reg_data, debug_pc);
            end
        end
    endtask

    task automatic run_retires;
        input integer count;
        integer retired;
        integer cycles;
        begin
            retired = 0;
            cycles  = 0;
            while ((retired < count) && (cycles < (count * 8 + 32))) begin
                @(posedge clk);
                if (retire_valid)
                    retired = retired + 1;
                #1;
                cycles = cycles + 1;
            end
            if (retired != count)
                $fatal(1, "timeout waiting for %0d retires: got=%0d",
                       count, retired);
        end
    endtask

    always @(negedge clk) begin
        if (!reset && cpu_enable && fault) begin
            $fatal(1,
                   "unexpected fault: pc=%08x instruction=%08x cause=%0d value=%08x",
                   debug_pc, debug_instruction,
                   debug_trap_cause, debug_trap_value);
        end
    end

    initial begin
        clk            = 1'b0;
        reset          = 1'b1;
        cpu_enable     = 1'b0;
        input_port     = 8'd0;
        debug_reg_addr = 5'd0;

        // Delay avoids a time-zero race with InstructionMemoryV2's own
        // initialization block.
        #1;
        for (i = 0; i < IMEM_WORDS; i = i + 1)
            dut.instruction_memory.memory[i] = RV32_NOP;

        // Source operands.
        dut.instruction_memory.memory[0]  = rv32_i(32'd7,  5'd0, 3'b000, 5'd1,  RV32_OPCODE_OP_IMM); // ADDI
        dut.instruction_memory.memory[1]  = rv32_i(32'd3,  5'd0, 3'b000, 5'd2,  RV32_OPCODE_OP_IMM); // ADDI
        dut.instruction_memory.memory[2]  = rv32_i(-32'sd16, 5'd0, 3'b000, 5'd10, RV32_OPCODE_OP_IMM); // ADDI

        // All ten OP encodings.
        dut.instruction_memory.memory[3]  = rv32_r(7'b0000000, 5'd2,  5'd1,  3'b000, 5'd3,  RV32_OPCODE_OP); // ADD
        dut.instruction_memory.memory[4]  = rv32_r(7'b0100000, 5'd2,  5'd1,  3'b000, 5'd4,  RV32_OPCODE_OP); // SUB
        dut.instruction_memory.memory[5]  = rv32_r(7'b0000000, 5'd2,  5'd1,  3'b001, 5'd5,  RV32_OPCODE_OP); // SLL
        dut.instruction_memory.memory[6]  = rv32_r(7'b0000000, 5'd2,  5'd10, 3'b010, 5'd6,  RV32_OPCODE_OP); // SLT
        dut.instruction_memory.memory[7]  = rv32_r(7'b0000000, 5'd2,  5'd10, 3'b011, 5'd7,  RV32_OPCODE_OP); // SLTU
        dut.instruction_memory.memory[8]  = rv32_r(7'b0000000, 5'd2,  5'd1,  3'b100, 5'd8,  RV32_OPCODE_OP); // XOR
        dut.instruction_memory.memory[9]  = rv32_r(7'b0000000, 5'd2,  5'd10, 3'b101, 5'd9,  RV32_OPCODE_OP); // SRL
        dut.instruction_memory.memory[10] = rv32_r(7'b0100000, 5'd2,  5'd10, 3'b101, 5'd11, RV32_OPCODE_OP); // SRA
        dut.instruction_memory.memory[11] = rv32_r(7'b0000000, 5'd2,  5'd1,  3'b110, 5'd12, RV32_OPCODE_OP); // OR
        dut.instruction_memory.memory[12] = rv32_r(7'b0000000, 5'd2,  5'd1,  3'b111, 5'd13, RV32_OPCODE_OP); // AND

        // All nine OP-IMM encodings.  ADDI is repeated here with a negative
        // immediate so the result belongs to this result group.
        dut.instruction_memory.memory[13] = rv32_i(-32'sd2, 5'd1,  3'b000, 5'd14, RV32_OPCODE_OP_IMM); // ADDI
        dut.instruction_memory.memory[14] = rv32_i(32'd0,    5'd10, 3'b010, 5'd15, RV32_OPCODE_OP_IMM); // SLTI
        dut.instruction_memory.memory[15] = rv32_i(32'd4,    5'd2,  3'b011, 5'd16, RV32_OPCODE_OP_IMM); // SLTIU
        dut.instruction_memory.memory[16] = rv32_i(32'd15,   5'd1,  3'b100, 5'd17, RV32_OPCODE_OP_IMM); // XORI
        dut.instruction_memory.memory[17] = rv32_i(32'd8,    5'd2,  3'b110, 5'd18, RV32_OPCODE_OP_IMM); // ORI
        dut.instruction_memory.memory[18] = rv32_i(32'd6,    5'd1,  3'b111, 5'd19, RV32_OPCODE_OP_IMM); // ANDI
        dut.instruction_memory.memory[19] = rv32_i({20'd0, 7'b0000000, 5'd4}, 5'd2,  3'b001, 5'd20, RV32_OPCODE_OP_IMM); // SLLI
        dut.instruction_memory.memory[20] = rv32_i({20'd0, 7'b0000000, 5'd4}, 5'd10, 3'b101, 5'd21, RV32_OPCODE_OP_IMM); // SRLI
        dut.instruction_memory.memory[21] = rv32_i({20'd0, 7'b0100000, 5'd4}, 5'd10, 3'b101, 5'd22, RV32_OPCODE_OP_IMM); // SRAI

        dut.instruction_memory.memory[22] = rv32_u(20'h12345, 5'd23, RV32_OPCODE_LUI);   // LUI
        // AUIPC is at PC=0x5c, therefore x24 must become 0x0000105c.
        dut.instruction_memory.memory[23] = rv32_u(20'h00001, 5'd24, RV32_OPCODE_AUIPC); // AUIPC
        dut.instruction_memory.memory[24] = rv32_i(32'd1, 5'd0, 3'b000, 5'd25, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[25] = rv32_i(32'd0, 5'd0, 3'b000, 5'd0,  RV32_OPCODE_MISC); // FENCE
        dut.instruction_memory.memory[26] = rv32_i(32'd1, 5'd25, 3'b000, 5'd25, RV32_OPCODE_OP_IMM);

        // Boundary shifts and sign-extension regression cases.
        dut.instruction_memory.memory[27] = rv32_i(32'd1,  5'd0,  3'b000, 5'd26, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[28] = rv32_i({20'd0, 7'b0000000, 5'd31}, 5'd26, 3'b001, 5'd27, RV32_OPCODE_OP_IMM); // SLLI 31
        dut.instruction_memory.memory[29] = rv32_i({20'd0, 7'b0000000, 5'd31}, 5'd10, 3'b101, 5'd28, RV32_OPCODE_OP_IMM); // SRLI 31
        dut.instruction_memory.memory[30] = rv32_i({20'd0, 7'b0100000, 5'd31}, 5'd10, 3'b101, 5'd29, RV32_OPCODE_OP_IMM); // SRAI 31
        dut.instruction_memory.memory[31] = rv32_i(32'd34, 5'd0, 3'b000, 5'd31, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[32] = rv32_r(7'b0000000, 5'd31, 5'd26, 3'b001, 5'd26, RV32_OPCODE_OP); // SLL uses 34[4:0]
        dut.instruction_memory.memory[33] = rv32_r(7'b0000000, 5'd31, 5'd10, 3'b101, 5'd27, RV32_OPCODE_OP); // SRL uses 34[4:0]
        dut.instruction_memory.memory[34] = rv32_r(7'b0100000, 5'd31, 5'd10, 3'b101, 5'd28, RV32_OPCODE_OP); // SRA uses 34[4:0]
        dut.instruction_memory.memory[35] = rv32_i(-32'sd1, 5'd2, 3'b011, 5'd29, RV32_OPCODE_OP_IMM); // SLTIU with sign-extended -1
        dut.instruction_memory.memory[36] = rv32_i(32'h0000_0800, 5'd0, 3'b000, 5'd30, RV32_OPCODE_OP_IMM); // minimum I immediate
        dut.instruction_memory.memory[37] = rv32_i(32'd123, 5'd0, 3'b000, 5'd0, RV32_OPCODE_OP_IMM); // x0 write is ignored

        repeat (2) @(posedge clk);
        @(negedge clk);
        reset      = 1'b0;
        cpu_enable = 1'b1;

        run_retires(EXECUTED_INSTRUCTIONS);
        @(negedge clk);
        cpu_enable = 1'b0;
        #1;

        if (fault)
            $fatal(1, "fault remained asserted after integer test");
        if (debug_pc !== 32'd152)
            $fatal(1, "final PC mismatch: expected=00000098 actual=%08x", debug_pc);

        expect_register(5'd0,  32'h0000_0000);
        expect_register(5'd3,  32'h0000_000a); // ADD
        expect_register(5'd4,  32'h0000_0004); // SUB
        expect_register(5'd5,  32'h0000_0038); // SLL
        expect_register(5'd6,  32'h0000_0001); // SLT
        expect_register(5'd7,  32'h0000_0000); // SLTU
        expect_register(5'd8,  32'h0000_0004); // XOR
        expect_register(5'd9,  32'h1fff_fffe); // SRL
        expect_register(5'd11, 32'hffff_fffe); // SRA
        expect_register(5'd12, 32'h0000_0007); // OR
        expect_register(5'd13, 32'h0000_0003); // AND
        expect_register(5'd14, 32'h0000_0005); // ADDI
        expect_register(5'd15, 32'h0000_0001); // SLTI
        expect_register(5'd16, 32'h0000_0001); // SLTIU
        expect_register(5'd17, 32'h0000_0008); // XORI
        expect_register(5'd18, 32'h0000_000b); // ORI
        expect_register(5'd19, 32'h0000_0006); // ANDI
        expect_register(5'd20, 32'h0000_0030); // SLLI
        expect_register(5'd21, 32'h0fff_ffff); // SRLI
        expect_register(5'd22, 32'hffff_ffff); // SRAI
        expect_register(5'd23, 32'h1234_5000); // LUI
        expect_register(5'd24, 32'h0000_105c); // AUIPC
        expect_register(5'd25, 32'h0000_0002); // FENCE retired as a no-op
        expect_register(5'd26, 32'h0000_0004); // R-type SLL uses rs2[4:0]
        expect_register(5'd27, 32'h3fff_fffc); // R-type SRL uses rs2[4:0]
        expect_register(5'd28, 32'hffff_fffc); // R-type SRA uses rs2[4:0]
        expect_register(5'd29, 32'h0000_0001); // SLTIU sign-extends immediate before unsigned compare
        expect_register(5'd30, 32'hffff_f800); // ADDI immediate 0x800 sign extension
        expect_register(5'd31, 32'h0000_0022); // shift source has upper bits set

        $display("PASS: tb_v2_integer (10 OP, 9 OP-IMM, LUI, AUIPC, FENCE)");
        $finish;
    end
endmodule

`default_nettype wire
