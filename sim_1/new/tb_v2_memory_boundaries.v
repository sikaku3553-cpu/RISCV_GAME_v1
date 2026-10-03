`timescale 1ns/1ps
`default_nettype none

// End-to-end negative-offset and final-valid-address checks for Data RAM.
module tb_v2_memory_boundaries;
    localparam integer IMEM_WORDS = 64;
    localparam integer EXECUTED_INSTRUCTIONS = 14;

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
            $fatal(1, "unexpected memory-boundary fault: pc=%08x cause=%0d value=%08x",
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
            rv32_i(32'h100, 5'd0, 3'b000, 5'd1, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[1] =
            rv32_i(-32'sd128, 5'd0, 3'b000, 5'd2, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[2] =
            rv32_s(-32'sd1, 5'd2, 5'd1, 3'b000, RV32_OPCODE_STORE); // SB 0xff
        dut.instruction_memory.memory[3] =
            rv32_i(-32'sd1, 5'd1, 3'b100, 5'd3, RV32_OPCODE_LOAD);  // LBU 0xff
        dut.instruction_memory.memory[4] =
            rv32_i(-32'sd1, 5'd1, 3'b000, 5'd4, RV32_OPCODE_LOAD);  // LB 0xff
        dut.instruction_memory.memory[5] =
            rv32_u(20'h00008, 5'd2, RV32_OPCODE_LUI);
        dut.instruction_memory.memory[6] =
            rv32_i(32'd1, 5'd2, 3'b000, 5'd2, RV32_OPCODE_OP_IMM); // 0x8001
        dut.instruction_memory.memory[7] =
            rv32_s(-32'sd2, 5'd2, 5'd1, 3'b001, RV32_OPCODE_STORE); // SH 0xfe
        dut.instruction_memory.memory[8] =
            rv32_i(-32'sd2, 5'd1, 3'b101, 5'd5, RV32_OPCODE_LOAD);  // LHU 0xfe
        dut.instruction_memory.memory[9] =
            rv32_i(-32'sd2, 5'd1, 3'b001, 5'd6, RV32_OPCODE_LOAD);  // LH 0xfe
        dut.instruction_memory.memory[10] =
            rv32_u(20'h89abd, 5'd2, RV32_OPCODE_LUI);
        dut.instruction_memory.memory[11] =
            rv32_i(-32'sd529, 5'd2, 3'b000, 5'd2, RV32_OPCODE_OP_IMM); // 0x89abcdef
        dut.instruction_memory.memory[12] =
            rv32_s(-32'sd4, 5'd2, 5'd1, 3'b010, RV32_OPCODE_STORE); // SW 0xfc
        dut.instruction_memory.memory[13] =
            rv32_i(-32'sd4, 5'd1, 3'b010, 5'd7, RV32_OPCODE_LOAD);  // LW 0xfc
        dut.instruction_memory.memory[14] =
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
            $fatal(1, "fault remained asserted after memory-boundary test");
        if (debug_pc !== 32'd56)
            $fatal(1, "final PC mismatch: expected=00000038 actual=%08x", debug_pc);

        expect_register(5'd3, 32'h0000_0080);
        expect_register(5'd4, 32'hffff_ff80);
        expect_register(5'd5, 32'h0000_8001);
        expect_register(5'd6, 32'hffff_8001);
        expect_register(5'd7, 32'h89ab_cdef);

        if (dut.data_memory.memory[63] !== 32'h89ab_cdef)
            $fatal(1, "final RAM word mismatch: expected=89abcdef actual=%08x",
                   dut.data_memory.memory[63]);

        $display("PASS: tb_v2_memory_boundaries (negative offsets and 0xff/0xfe/0xfc endpoints)");
        $finish;
    end
endmodule

`default_nettype wire
