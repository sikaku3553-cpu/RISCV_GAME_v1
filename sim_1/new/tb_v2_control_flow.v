`timescale 1ns/1ps
`default_nettype none

// End-to-end execution test for the six RV32I conditional branches and both
// jump instructions.  Every branch is checked once taken and once not taken.
module tb_v2_control_flow;
    localparam integer IMEM_WORDS = 64;
    localparam integer EXECUTED_INSTRUCTIONS = 39;

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

        #1;
        for (i = 0; i < IMEM_WORDS; i = i + 1)
            dut.instruction_memory.memory[i] = RV32_NOP;

        // x1==x2, x3 is negative signed / maximum unsigned, x4 is +1.
        dut.instruction_memory.memory[0] = rv32_i(32'd5,     5'd0, 3'b000, 5'd1,  RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[1] = rv32_i(32'd5,     5'd0, 3'b000, 5'd2,  RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[2] = rv32_i(-32'sd1,   5'd0, 3'b000, 5'd3,  RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[3] = rv32_i(32'd1,     5'd0, 3'b000, 5'd4,  RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[4] = rv32_i(32'd0,     5'd0, 3'b000, 5'd30, RV32_OPCODE_OP_IMM);

        // Each four-entry group has this structure:
        //   expected-taken branch skips the x30 failure increment;
        //   expected-not-taken branch executes a unique success write.
        dut.instruction_memory.memory[5] = rv32_b(32'd8, 5'd2, 5'd1, 3'b000, RV32_OPCODE_BRANCH); // BEQ taken
        dut.instruction_memory.memory[6] = rv32_i(32'd1, 5'd30, 3'b000, 5'd30, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[7] = rv32_b(32'd8, 5'd4, 5'd1, 3'b000, RV32_OPCODE_BRANCH); // BEQ not taken
        dut.instruction_memory.memory[8] = rv32_i(32'd1, 5'd0, 3'b000, 5'd10, RV32_OPCODE_OP_IMM);

        dut.instruction_memory.memory[9]  = rv32_b(32'd8, 5'd4, 5'd1, 3'b001, RV32_OPCODE_BRANCH); // BNE taken
        dut.instruction_memory.memory[10] = rv32_i(32'd1, 5'd30, 3'b000, 5'd30, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[11] = rv32_b(32'd8, 5'd2, 5'd1, 3'b001, RV32_OPCODE_BRANCH); // BNE not taken
        dut.instruction_memory.memory[12] = rv32_i(32'd1, 5'd0, 3'b000, 5'd11, RV32_OPCODE_OP_IMM);

        dut.instruction_memory.memory[13] = rv32_b(32'd8, 5'd4, 5'd3, 3'b100, RV32_OPCODE_BRANCH); // BLT taken: -1 < 1
        dut.instruction_memory.memory[14] = rv32_i(32'd1, 5'd30, 3'b000, 5'd30, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[15] = rv32_b(32'd8, 5'd3, 5'd4, 3'b100, RV32_OPCODE_BRANCH); // BLT not taken
        dut.instruction_memory.memory[16] = rv32_i(32'd1, 5'd0, 3'b000, 5'd12, RV32_OPCODE_OP_IMM);

        dut.instruction_memory.memory[17] = rv32_b(32'd8, 5'd3, 5'd4, 3'b101, RV32_OPCODE_BRANCH); // BGE taken: 1 >= -1
        dut.instruction_memory.memory[18] = rv32_i(32'd1, 5'd30, 3'b000, 5'd30, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[19] = rv32_b(32'd8, 5'd4, 5'd3, 3'b101, RV32_OPCODE_BRANCH); // BGE not taken
        dut.instruction_memory.memory[20] = rv32_i(32'd1, 5'd0, 3'b000, 5'd13, RV32_OPCODE_OP_IMM);

        dut.instruction_memory.memory[21] = rv32_b(32'd8, 5'd3, 5'd4, 3'b110, RV32_OPCODE_BRANCH); // BLTU taken: 1 < UINT_MAX
        dut.instruction_memory.memory[22] = rv32_i(32'd1, 5'd30, 3'b000, 5'd30, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[23] = rv32_b(32'd8, 5'd4, 5'd3, 3'b110, RV32_OPCODE_BRANCH); // BLTU not taken
        dut.instruction_memory.memory[24] = rv32_i(32'd1, 5'd0, 3'b000, 5'd14, RV32_OPCODE_OP_IMM);

        dut.instruction_memory.memory[25] = rv32_b(32'd8, 5'd4, 5'd3, 3'b111, RV32_OPCODE_BRANCH); // BGEU taken: UINT_MAX >= 1
        dut.instruction_memory.memory[26] = rv32_i(32'd1, 5'd30, 3'b000, 5'd30, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[27] = rv32_b(32'd8, 5'd3, 5'd4, 3'b111, RV32_OPCODE_BRANCH); // BGEU not taken
        dut.instruction_memory.memory[28] = rv32_i(32'd1, 5'd0, 3'b000, 5'd15, RV32_OPCODE_OP_IMM);

        // JAL at PC=0x74 writes link 0x78 and skips entry 30.
        dut.instruction_memory.memory[29] = rv32_j(32'd8, 5'd16, RV32_OPCODE_JAL);
        dut.instruction_memory.memory[30] = rv32_i(32'd1, 5'd30, 3'b000, 5'd30, RV32_OPCODE_OP_IMM);

        // 134 + 3 = 137; JALR must clear bit zero and jump to PC=136.
        // JALR at PC=0x80 writes link 0x84 and skips entry 33.
        dut.instruction_memory.memory[31] = rv32_i(32'd134, 5'd0, 3'b000, 5'd19, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[32] = rv32_i(32'd3,   5'd19, 3'b000, 5'd18, RV32_OPCODE_JALR);
        dut.instruction_memory.memory[33] = rv32_i(32'd1,   5'd30, 3'b000, 5'd30, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[34] = rv32_i(32'h55,  5'd0, 3'b000, 5'd20, RV32_OPCODE_OP_IMM);

        // Backward B-immediate: execute the loop body twice.
        dut.instruction_memory.memory[35] = rv32_i(32'd0, 5'd0, 3'b000, 5'd21, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[36] = rv32_i(32'd2, 5'd0, 3'b000, 5'd22, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[37] = rv32_i(32'd1, 5'd21, 3'b000, 5'd21, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[38] = rv32_b(-32'sd4, 5'd22, 5'd21, 3'b100, RV32_OPCODE_BRANCH);
        dut.instruction_memory.memory[39] = rv32_i(32'h66, 5'd0, 3'b000, 5'd23, RV32_OPCODE_OP_IMM);

        // Negative J-immediate path: slot 40 -> 43 -> 41 -> 42 -> 44.
        dut.instruction_memory.memory[40] = rv32_j(32'd12, 5'd0, RV32_OPCODE_JAL);
        dut.instruction_memory.memory[41] = rv32_i(32'h77, 5'd0, 3'b000, 5'd25, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[42] = rv32_j(32'd8, 5'd0, RV32_OPCODE_JAL);
        dut.instruction_memory.memory[43] = rv32_j(-32'sd8, 5'd24, RV32_OPCODE_JAL);
        dut.instruction_memory.memory[44] = rv32_i(32'h88, 5'd0, 3'b000, 5'd26, RV32_OPCODE_OP_IMM);

        repeat (2) @(posedge clk);
        @(negedge clk);
        reset      = 1'b0;
        cpu_enable = 1'b1;

        run_retires(EXECUTED_INSTRUCTIONS);
        @(negedge clk);
        cpu_enable = 1'b0;
        #1;

        if (fault)
            $fatal(1, "fault remained asserted after control-flow test");
        if (debug_pc !== 32'd180)
            $fatal(1, "final PC mismatch: expected=000000b4 actual=%08x", debug_pc);

        expect_register(5'd10, 32'd1); // BEQ not-taken path
        expect_register(5'd11, 32'd1); // BNE not-taken path
        expect_register(5'd12, 32'd1); // BLT not-taken path
        expect_register(5'd13, 32'd1); // BGE not-taken path
        expect_register(5'd14, 32'd1); // BLTU not-taken path
        expect_register(5'd15, 32'd1); // BGEU not-taken path
        expect_register(5'd16, 32'h0000_0078); // JAL link
        expect_register(5'd18, 32'h0000_0084); // JALR link
        expect_register(5'd19, 32'd134);       // JALR base
        expect_register(5'd20, 32'h0000_0055); // jump target reached
        expect_register(5'd21, 32'd2);          // backward BLT loop count
        expect_register(5'd22, 32'd2);          // backward BLT limit
        expect_register(5'd23, 32'h0000_0066);  // loop exit reached
        expect_register(5'd24, 32'h0000_00b0);  // negative JAL link (PC 0xac + 4)
        expect_register(5'd25, 32'h0000_0077);  // negative JAL target reached
        expect_register(5'd26, 32'h0000_0088);  // negative-JAL sequence exited
        expect_register(5'd30, 32'd0);         // no skipped failure path ran

        $display("PASS: tb_v2_control_flow (6 branches taken/not-taken, JAL, JALR)");
        $finish;
    end
endmodule

`default_nettype wire
