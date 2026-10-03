`timescale 1ns/1ps
`default_nettype none

// End-to-end arithmetic and control-flow boundary regression.
module tb_v2_boundaries;
    localparam integer IMEM_WORDS = 64;
    localparam integer EXECUTED_INSTRUCTIONS = 12;

    reg         clk;
    reg         reset;
    reg         cpu_enable;
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
        .input_port(8'd0),
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
            if (debug_reg_data !== expected)
                $fatal(1, "x%0d mismatch: expected=%08x actual=%08x",
                       address, expected, debug_reg_data);
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
        if (!reset && cpu_enable && fault)
            $fatal(1, "unexpected boundary-test fault: pc=%08x cause=%0d value=%08x",
                   debug_pc, debug_trap_cause, debug_trap_value);
    end

    initial begin
        clk            = 1'b0;
        reset          = 1'b1;
        cpu_enable     = 1'b0;
        debug_reg_addr = 5'd0;

        #1;
        for (i = 0; i < IMEM_WORDS; i = i + 1)
            dut.instruction_memory.memory[i] = RV32_NOP;

        dut.instruction_memory.memory[0] =
            rv32_u(20'h80000, 5'd1, RV32_OPCODE_LUI); // x1 = INT32_MIN
        dut.instruction_memory.memory[1] =
            rv32_i(-32'sd1, 5'd1, 3'b000, 5'd2, RV32_OPCODE_OP_IMM); // INT32_MAX
        dut.instruction_memory.memory[2] =
            rv32_i(32'd1, 5'd0, 3'b000, 5'd3, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[3] =
            rv32_r(7'h00, 5'd3, 5'd2, 3'b000, 5'd4, RV32_OPCODE_OP); // ADD wraps
        dut.instruction_memory.memory[4] =
            rv32_r(7'h20, 5'd3, 5'd1, 3'b000, 5'd5, RV32_OPCODE_OP); // SUB wraps
        dut.instruction_memory.memory[5] =
            rv32_i(-32'sd1, 5'd1, 3'b000, 5'd6, RV32_OPCODE_OP_IMM); // ADDI wraps
        dut.instruction_memory.memory[6] =
            rv32_i(32'd2047, 5'd0, 3'b000, 5'd7, RV32_OPCODE_OP_IMM); // I max
        dut.instruction_memory.memory[7] =
            rv32_i(32'h0000_0800, 5'd0, 3'b000, 5'd8, RV32_OPCODE_OP_IMM); // I min
        dut.instruction_memory.memory[8] = 32'h0330_000f; // FENCE rw,rw
        dut.instruction_memory.memory[9] =
            rv32_i(32'd48, 5'd0, 3'b000, 5'd9, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[10] =
            rv32_i(32'd0, 5'd9, 3'b000, 5'd9, RV32_OPCODE_JALR); // rd == rs1
        dut.instruction_memory.memory[11] =
            rv32_i(32'd999, 5'd0, 3'b000, 5'd10, RV32_OPCODE_OP_IMM); // skipped
        dut.instruction_memory.memory[12] =
            rv32_i(32'd0, 5'd9, 3'b000, 5'd10, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[13] =
            rv32_j(32'd0, 5'd0, RV32_OPCODE_JAL);

        repeat (2) @(posedge clk);
        @(negedge clk);
        reset      = 1'b0;
        cpu_enable = 1'b1;

        run_retires(EXECUTED_INSTRUCTIONS);
        @(negedge clk);
        cpu_enable = 1'b0;
        #1;

        if (fault)
            $fatal(1, "fault remained asserted after boundary test");
        if (debug_pc !== 32'd52)
            $fatal(1, "final PC mismatch: expected=00000034 actual=%08x", debug_pc);

        expect_register(5'd1,  32'h8000_0000);
        expect_register(5'd2,  32'h7fff_ffff);
        expect_register(5'd4,  32'h8000_0000); // ADD overflow is modulo 2^32
        expect_register(5'd5,  32'h7fff_ffff); // SUB underflow is modulo 2^32
        expect_register(5'd6,  32'h7fff_ffff); // ADDI underflow is modulo 2^32
        expect_register(5'd7,  32'h0000_07ff);
        expect_register(5'd8,  32'hffff_f800);
        expect_register(5'd9,  32'h0000_002c); // JALR link PC+4, old x9 selected target
        expect_register(5'd10, 32'h0000_002c); // target observed link, skipped value absent

        $display("PASS: tb_v2_boundaries (overflow, I-immediates, FENCE rw/rw, JALR rd=rs1)");
        $finish;
    end
endmodule

`default_nettype wire
