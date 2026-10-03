`timescale 1ns/1ps
`default_nettype none

// Positive-path MMIO regression: input LW, output SW and output readback LW.
module tb_v2_mmio;
    localparam integer IMEM_WORDS = 64;
    localparam integer EXECUTED_INSTRUCTIONS = 6;

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
            $fatal(1, "unexpected MMIO fault: pc=%08x cause=%0d value=%08x",
                   debug_pc, debug_trap_cause, debug_trap_value);
    end

    initial begin
        clk            = 1'b0;
        reset          = 1'b1;
        cpu_enable     = 1'b0;
        input_port     = 8'ha5;
        debug_reg_addr = 5'd0;

        #1;
        for (i = 0; i < IMEM_WORDS; i = i + 1)
            dut.instruction_memory.memory[i] = RV32_NOP;

        dut.instruction_memory.memory[0] =
            rv32_i(32'h100, 5'd0, 3'b000, 5'd1, RV32_OPCODE_OP_IMM); // IO_IN
        dut.instruction_memory.memory[1] =
            rv32_i(32'd0, 5'd1, 3'b010, 5'd2, RV32_OPCODE_LOAD);     // LW input
        dut.instruction_memory.memory[2] =
            rv32_i(32'd4, 5'd1, 3'b000, 5'd1, RV32_OPCODE_OP_IMM);  // IO_OUT
        dut.instruction_memory.memory[3] =
            rv32_i(32'h05a, 5'd0, 3'b000, 5'd3, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[4] =
            rv32_s(32'd0, 5'd3, 5'd1, 3'b010, RV32_OPCODE_STORE);   // SW output
        dut.instruction_memory.memory[5] =
            rv32_i(32'd0, 5'd1, 3'b010, 5'd4, RV32_OPCODE_LOAD);    // LW readback
        dut.instruction_memory.memory[6] =
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
            $fatal(1, "fault remained asserted after MMIO test");
        if (debug_pc !== 32'd24)
            $fatal(1, "final PC mismatch: expected=00000018 actual=%08x", debug_pc);
        if (output_port !== 8'h5a)
            $fatal(1, "output port mismatch: expected=5a actual=%02x", output_port);

        expect_register(5'd2, 32'h0000_00a5); // 8-bit input is zero-extended
        expect_register(5'd4, 32'h0000_005a); // output register readback

        $display("PASS: tb_v2_mmio (input LW, output SW, output LW readback)");
        $finish;
    end
endmodule

`default_nettype wire
