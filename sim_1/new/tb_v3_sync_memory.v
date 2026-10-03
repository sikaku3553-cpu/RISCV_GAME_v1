`timescale 1ns/1ps
`default_nettype none

// Focused end-to-end check for the v3 synchronous memory protocol.
// The program exercises ALU forwarding, STORE, load-use, a taken branch, and
// EBREAK.  STORE request handshakes are counted to catch repeated side effects
// while the pipeline is held for the synchronous response.
module tb_v3_sync_memory;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg cpu_enable = 1'b1;
    always #5 clk = ~clk;

    wire        imem_req_valid;
    wire        imem_req_ready;
    wire [31:0] imem_req_address;
    wire        imem_rsp_valid;
    wire [31:0] imem_rsp_data;
    wire        imem_rsp_error;

    wire        dmem_req_valid;
    wire        dmem_req_ready;
    wire [31:0] dmem_req_address;
    wire        dmem_req_write;
    wire [3:0]  dmem_req_write_strobe;
    wire [31:0] dmem_req_write_data;
    wire        dmem_rsp_valid;
    wire [31:0] dmem_rsp_read_data;
    wire        dmem_rsp_error;

    reg  [4:0]  debug_reg_addr = 5'd0;
    wire [31:0] debug_pc;
    wire [31:0] debug_instruction;
    wire [31:0] debug_reg_data;
    wire [4:0]  debug_trap_cause;
    wire [31:0] debug_trap_value;
    wire        fault;
    wire        pipeline_stalled;
    wire        retire_valid;
    wire [31:0] retire_pc;
    wire [31:0] retire_instruction;
    wire [31:0] cycle_count;
    wire [31:0] instret_count;
    wire [31:0] stall_count;
    wire [31:0] flush_count;

    integer store_request_fires = 0;
    integer cycles = 0;

    TD8_RISCV_V3_Core #(
        .ENABLE_RF_DEBUG(1)
    ) dut (
        .clk(clk),
        .reset(reset),
        .cpu_enable(cpu_enable),
        .imem_req_valid(imem_req_valid),
        .imem_req_ready(imem_req_ready),
        .imem_req_address(imem_req_address),
        .imem_rsp_valid(imem_rsp_valid),
        .imem_rsp_data(imem_rsp_data),
        .imem_rsp_error(imem_rsp_error),
        .dmem_req_valid(dmem_req_valid),
        .dmem_req_ready(dmem_req_ready),
        .dmem_req_address(dmem_req_address),
        .dmem_req_write(dmem_req_write),
        .dmem_req_write_strobe(dmem_req_write_strobe),
        .dmem_req_write_data(dmem_req_write_data),
        .dmem_rsp_valid(dmem_rsp_valid),
        .dmem_rsp_read_data(dmem_rsp_read_data),
        .dmem_rsp_error(dmem_rsp_error),
        .debug_reg_addr(debug_reg_addr),
        .debug_pc(debug_pc),
        .debug_instruction(debug_instruction),
        .debug_reg_data(debug_reg_data),
        .debug_trap_cause(debug_trap_cause),
        .debug_trap_value(debug_trap_value),
        .fault(fault),
        .pipeline_stalled(pipeline_stalled),
        .retire_valid(retire_valid),
        .retire_pc(retire_pc),
        .retire_instruction(retire_instruction),
        .cycle_count(cycle_count),
        .instret_count(instret_count),
        .stall_count(stall_count),
        .flush_count(flush_count)
    );

    SyncInstructionMemoryV3 #(.WORDS(64)) imem (
        .clk(clk),
        .reset(reset),
        .req_valid(imem_req_valid),
        .req_ready(imem_req_ready),
        .req_address(imem_req_address),
        .rsp_valid(imem_rsp_valid),
        .rsp_data(imem_rsp_data),
        .rsp_error(imem_rsp_error)
    );

    SyncDataMemoryV3 #(.BYTES(256)) dmem (
        .clk(clk),
        .reset(reset),
        .req_valid(dmem_req_valid),
        .req_ready(dmem_req_ready),
        .req_address(dmem_req_address),
        .req_write(dmem_req_write),
        .req_write_strobe(dmem_req_write_strobe),
        .req_write_data(dmem_req_write_data),
        .rsp_valid(dmem_rsp_valid),
        .rsp_read_data(dmem_rsp_read_data),
        .rsp_error(dmem_rsp_error)
    );

    always @(posedge clk) begin
        if (!reset) begin
            cycles <= cycles + 1;
            if (dmem_req_valid && dmem_req_ready && dmem_req_write)
                store_request_fires <= store_request_fires + 1;
            if (cycles > 500)
                $fatal(1, "timeout pc=%08x instruction=%08x",
                       debug_pc, debug_instruction);
        end
    end

    task check_register;
        input [4:0] address;
        input [31:0] expected;
        begin
            debug_reg_addr = address;
            #1;
            if (debug_reg_data !== expected)
                $fatal(1, "x%0d expected %08x, got %08x",
                       address, expected, debug_reg_data);
        end
    endtask

    initial begin
        // addi x1,x0,0x40
        // addi x2,x0,0x55
        // sw   x2,0(x1)
        // lw   x3,0(x1)
        // addi x4,x3,1       (load-use dependency)
        // sw   x4,4(x1)
        // lw   x5,4(x1)
        // beq  x5,x4,+8      (skip the x6 failure marker)
        // addi x6,x0,1
        // ebreak
        #1;
        imem.memory[0] = 32'h0400_0093;
        imem.memory[1] = 32'h0550_0113;
        imem.memory[2] = 32'h0020_A023;
        imem.memory[3] = 32'h0000_A183;
        imem.memory[4] = 32'h0011_8213;
        imem.memory[5] = 32'h0040_A223;
        imem.memory[6] = 32'h0040_A283;
        imem.memory[7] = 32'h0042_8463;
        imem.memory[8] = 32'h0010_0313;
        imem.memory[9] = 32'h0010_0073;

        repeat (4) @(posedge clk);
        reset = 1'b0;

        wait (fault);
        #1;

        if (debug_trap_cause !== 5'd3)
            $fatal(1, "expected breakpoint cause, got %0d",
                   debug_trap_cause);
        if (debug_trap_value !== 32'd36)
            $fatal(1, "expected breakpoint PC 36, got %08x",
                   debug_trap_value);
        if (store_request_fires !== 2)
            $fatal(1, "STORE fired %0d times, expected exactly 2",
                   store_request_fires);
        if (dmem.memory[16] !== 32'h0000_0055)
            $fatal(1, "RAM[0x40] mismatch: %08x", dmem.memory[16]);
        if (dmem.memory[17] !== 32'h0000_0056)
            $fatal(1, "RAM[0x44] mismatch: %08x", dmem.memory[17]);
        if (instret_count !== 32'd8)
            $fatal(1, "instret expected 8, got %0d", instret_count);
        if (stall_count == 32'd0)
            $fatal(1, "stall counter did not observe memory/fetch waits");
        if (flush_count < 32'd2)
            $fatal(1, "flush counter expected branch+trap, got %0d",
                   flush_count);

        check_register(5'd1, 32'h0000_0040);
        check_register(5'd2, 32'h0000_0055);
        check_register(5'd3, 32'h0000_0055);
        check_register(5'd4, 32'h0000_0056);
        check_register(5'd5, 32'h0000_0056);
        check_register(5'd6, 32'h0000_0000);

        $display("PASS: v3 synchronous memory, exact-once STORE, branch, load-use");
        $finish;
    end
endmodule

`default_nettype wire
