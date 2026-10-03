`timescale 1ns/1ps
`default_nettype none

// Regression for the v1.1 LUTRAM-oriented reset policy retained by v2.
// Register data arrays and Data RAM must not be cleared by CPU reset; only
// the Register File valid mask is reset, so architectural reads become zero.
module tb_v2_lutram_reset;
    localparam integer IMEM_WORDS = 64;

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

    initial begin
        clk            = 1'b0;
        reset          = 1'b1;
        cpu_enable     = 1'b0;
        debug_reg_addr = 5'd1;

        #1;
        for (i = 0; i < IMEM_WORDS; i = i + 1)
            dut.instruction_memory.memory[i] = RV32_NOP;

        // x1 <- 0x55; RAM[0] <- x1; then stop on a self-jump.
        dut.instruction_memory.memory[0] =
            rv32_i(32'h55, 5'd0, 3'b000, 5'd1, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[1] =
            rv32_s(32'd0, 5'd1, 5'd0, 3'b010, RV32_OPCODE_STORE);
        dut.instruction_memory.memory[2] =
            rv32_j(32'd0, 5'd0, RV32_OPCODE_JAL);

        repeat (2) @(posedge clk);
        @(negedge clk);
        reset      = 1'b0;
        cpu_enable = 1'b1;

        run_retires(2);
        @(negedge clk);
        cpu_enable = 1'b0;
        #1;

        if (fault)
            $fatal(1, "unexpected fault before reset-policy check");
        if (debug_pc !== 32'd8)
            $fatal(1, "pre-reset PC mismatch: expected=8 actual=%08x", debug_pc);
        if (debug_reg_data !== 32'h0000_0055)
            $fatal(1, "pre-reset x1 mismatch: %08x", debug_reg_data);
        if (debug_mem_word0 !== 32'h0000_0055)
            $fatal(1, "pre-reset RAM[0] mismatch: %08x", debug_mem_word0);

        // Asserting reset clears architectural validity and PC, but leaves
        // both physical Register File banks and Data RAM untouched.
        reset = 1'b1;
        #1;
        if (debug_pc !== 32'd0)
            $fatal(1, "PC was not asynchronously reset: %08x", debug_pc);
        if (debug_reg_data !== 32'd0)
            $fatal(1, "invalidated x1 did not read as zero: %08x", debug_reg_data);
        if (dut.register_file.valid !== 32'd0)
            $fatal(1, "Register File valid mask was not cleared: %08x",
                   dut.register_file.valid);
        if (dut.register_file.registers_a[1] !== 32'h0000_0055 ||
            dut.register_file.registers_b[1] !== 32'h0000_0055)
            $fatal(1, "Register File physical data arrays were cleared by reset");
        if (debug_mem_word0 !== 32'h0000_0055)
            $fatal(1, "Data RAM was cleared by reset: %08x", debug_mem_word0);

        // Even with cpu_enable high and a store at PC=0, reset must suppress
        // every architectural side effect through the pipeline enables.
        dut.data_memory.memory[0] = 32'haabb_ccdd;
        dut.instruction_memory.memory[0] =
            rv32_s(32'd0, 5'd0, 5'd0, 3'b010, RV32_OPCODE_STORE);
        cpu_enable = 1'b1;
        repeat (2) @(posedge clk);
        @(negedge clk);
        cpu_enable = 1'b0;
        #1;

        if (debug_mem_word0 !== 32'haabb_ccdd)
            $fatal(1, "reset allowed a Data RAM side effect: %08x",
                   debug_mem_word0);
        if (debug_pc !== 32'd0)
            $fatal(1, "reset allowed PC to advance: %08x", debug_pc);

        $display("PASS: tb_v2_lutram_reset (RAM persistence, RF valid-mask reset, side-effect suppression)");
        $finish;
    end
endmodule

`default_nettype wire
