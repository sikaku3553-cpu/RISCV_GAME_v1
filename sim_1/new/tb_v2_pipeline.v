`timescale 1ns/1ps
`default_nettype none

// Focused regression for the five-stage pipeline itself. Existing ISA tests
// cover instruction semantics; this test targets inter-stage behavior.
module tb_v2_pipeline;
    localparam integer IMEM_WORDS = 64;
    localparam [4:0] CAUSE_LOAD_ADDR_MISALIGNED = 5'd4;

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
    wire [31:0] retire_pc;
    wire [31:0] retire_instruction;

    integer failures;
    integer i;
    integer retire_count;
    integer ram_store_count;
    integer load_use_stall_count;
    integer held_retire_count;
    integer held_store_count;
    integer hold_cycle;
    reg [31:0] held_pc;
    reg [3:0]  held_valids;
    reg [31:0] held_memory0;
    reg [31:0] held_memory1;
    reg [31:0] held_rf_valid;
    reg [7:0]  held_output;

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
        .retire_valid(retire_valid),
        .retire_pc(retire_pc),
        .retire_instruction(retire_instruction)
    );

    always #5 clk = ~clk;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            retire_count         <= 0;
            ram_store_count      <= 0;
            load_use_stall_count <= 0;
        end else begin
            if (retire_valid)
                retire_count <= retire_count + 1;
            if (dut.pipeline_advance &&
                (dut.ram_write_strobe != 4'b0000))
                ram_store_count <= ram_store_count + 1;
            if (dut.pipeline_advance && dut.load_use_stall)
                load_use_stall_count <= load_use_stall_count + 1;
        end
    end

    task automatic check32;
        input [31:0] actual;
        input [31:0] expected;
        input [8*80-1:0] description;
        begin
            if (actual !== expected) begin
                $display("[FAIL] %0s: expected=%08x actual=%08x",
                         description, expected, actual);
                failures = failures + 1;
            end
        end
    endtask

    task automatic check_reg;
        input [4:0] address;
        input [31:0] expected;
        input [8*80-1:0] description;
        begin
            debug_reg_addr = address;
            #1;
            check32(debug_reg_data, expected, description);
        end
    endtask

    task automatic fill_nops;
        begin
            for (i = 0; i < IMEM_WORDS; i = i + 1)
                dut.instruction_memory.memory[i] = RV32_NOP;
        end
    endtask

    task automatic start_cpu;
        begin
            repeat (2) @(posedge clk);
            @(negedge clk);
            reset      = 1'b0;
            cpu_enable = 1'b1;
        end
    endtask

    task automatic wait_for_retires;
        input integer target;
        input integer max_cycles;
        integer cycles;
        begin
            cycles = 0;
            while ((retire_count < target) && (cycles < max_cycles)) begin
                @(posedge clk);
                #1;
                if (fault)
                    $fatal(1,
                           "unexpected fault while waiting for retire %0d: pc=%08x instruction=%08x cause=%0d value=%08x",
                           target, debug_pc, debug_instruction,
                           debug_trap_cause, debug_trap_value);
                cycles = cycles + 1;
            end
            if (retire_count < target)
                $fatal(1,
                       "timeout waiting for %0d retires: got=%0d",
                       target, retire_count);
        end
    endtask

    task automatic wait_for_fault;
        input integer max_cycles;
        integer cycles;
        begin
            cycles = 0;
            while (!fault && (cycles < max_cycles)) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end
            if (!fault)
                $fatal(1, "timeout waiting for pipeline fault");
        end
    endtask

    task automatic wait_and_check_retire;
        input [31:0] expected_pc;
        input [31:0] expected_instruction;
        input [8*80-1:0] description;
        integer cycles;
        integer seen;
        begin
            cycles = 0;
            seen   = 0;
            while (!seen && (cycles < 40)) begin
                @(posedge clk);
                // Sample before nonblocking pipeline updates. retire_valid
                // identifies the token committing on this active edge.
                if (retire_valid) begin
                    seen = 1;
                    check32(retire_pc, expected_pc,
                            description);
                    check32(retire_instruction, expected_instruction,
                            description);
                end
                #1;
                cycles = cycles + 1;
            end
            if (!seen)
                $fatal(1, "timeout waiting for %0s", description);
        end
    endtask

    initial begin
        clk            = 1'b0;
        reset          = 1'b1;
        cpu_enable     = 1'b0;
        input_port     = 8'ha5;
        debug_reg_addr = 5'd0;
        failures       = 0;

        // -------------------------------------------------------------
        // Phase A: forwarding, load-use stalls, flushes and clock enable
        // -------------------------------------------------------------
        #1;
        fill_nops;
        for (i = 0; i < 8; i = i + 1)
            dut.data_memory.memory[i] = 32'd0;
        dut.data_memory.memory[2] = 32'hcafe_babe;
        dut.data_memory.memory[5] = 32'h0000_009c;
        dut.data_memory.memory[6] = 32'h0000_001c;

        dut.instruction_memory.memory[0] =
            rv32_i(32'd5, 5'd0, 3'b000, 5'd1, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[1] =
            rv32_i(32'd7, 5'd1, 3'b000, 5'd2, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[2] =
            rv32_r(7'b0000000, 5'd1, 5'd2, 3'b000, 5'd3,
                   RV32_OPCODE_OP);
        dut.instruction_memory.memory[3] =
            rv32_s(32'd0, 5'd3, 5'd0, 3'b010, RV32_OPCODE_STORE);
        dut.instruction_memory.memory[4] =
            rv32_i(32'd0, 5'd0, 3'b010, 5'd4, RV32_OPCODE_LOAD);
        dut.instruction_memory.memory[5] =
            rv32_i(32'd1, 5'd4, 3'b000, 5'd5, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[6] =
            rv32_s(32'd4, 5'd5, 5'd0, 3'b010, RV32_OPCODE_STORE);
        dut.instruction_memory.memory[7] =
            rv32_i(32'd4, 5'd0, 3'b010, 5'd6, RV32_OPCODE_LOAD);
        dut.instruction_memory.memory[8] =
            rv32_b(32'd12, 5'd5, 5'd6, 3'b000, RV32_OPCODE_BRANCH);
        dut.instruction_memory.memory[9]  = 32'h0000_0073;
        dut.instruction_memory.memory[10] =
            rv32_s(32'd8, 5'd1, 5'd0, 3'b010, RV32_OPCODE_STORE);
        dut.instruction_memory.memory[11] =
            rv32_i(32'h033, 5'd0, 3'b000, 5'd7, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[12] =
            rv32_b(32'd12, 5'd0, 5'd7, 3'b000, RV32_OPCODE_BRANCH);
        dut.instruction_memory.memory[13] =
            rv32_i(32'h044, 5'd0, 3'b000, 5'd8, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[14] =
            rv32_b(32'd12, 5'd7, 5'd7, 3'b000, RV32_OPCODE_BRANCH);
        dut.instruction_memory.memory[15] =
            rv32_i(32'd1, 5'd0, 3'b000, 5'd30, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[16] =
            rv32_s(32'd8, 5'd1, 5'd0, 3'b010, RV32_OPCODE_STORE);
        dut.instruction_memory.memory[17] =
            rv32_j(32'd12, 5'd9, RV32_OPCODE_JAL);
        dut.instruction_memory.memory[18] =
            rv32_s(32'd8, 5'd1, 5'd0, 3'b010, RV32_OPCODE_STORE);
        dut.instruction_memory.memory[19] = 32'h0010_0073;
        dut.instruction_memory.memory[20] =
            rv32_i(32'd4, 5'd9, 3'b000, 5'd10, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[21] =
            rv32_i(32'h064, 5'd0, 3'b000, 5'd11, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[22] =
            rv32_i(32'd0, 5'd11, 3'b000, 5'd12, RV32_OPCODE_JALR);
        dut.instruction_memory.memory[23] =
            rv32_i(32'd2, 5'd0, 3'b000, 5'd30, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[24] =
            rv32_s(32'd8, 5'd1, 5'd0, 3'b010, RV32_OPCODE_STORE);
        dut.instruction_memory.memory[25] =
            rv32_i(32'd4, 5'd12, 3'b000, 5'd13, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[26] =
            rv32_i(32'd12, 5'd0, 3'b000, 5'd14, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[27] =
            rv32_s(32'd0, 5'd13, 5'd14, 3'b010, RV32_OPCODE_STORE);
        dut.instruction_memory.memory[28] =
            rv32_i(32'd12, 5'd0, 3'b010, 5'd15, RV32_OPCODE_LOAD);
        dut.instruction_memory.memory[29] =
            rv32_s(32'd16, 5'd15, 5'd0, 3'b010, RV32_OPCODE_STORE);
        dut.instruction_memory.memory[30] =
            rv32_i(32'h021, 5'd0, 3'b000, 5'd16, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[31] =
            rv32_i(32'd1, 5'd0, 3'b000, 5'd17, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[32] =
            rv32_i(32'd2, 5'd0, 3'b000, 5'd18, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[33] =
            rv32_r(7'b0000000, 5'd0, 5'd16, 3'b000, 5'd19,
                   RV32_OPCODE_OP);
        dut.instruction_memory.memory[34] =
            rv32_i(32'h104, 5'd0, 3'b000, 5'd22, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[35] =
            rv32_i(32'd20, 5'd0, 3'b010, 5'd20, RV32_OPCODE_LOAD);
        dut.instruction_memory.memory[36] =
            rv32_i(32'd0, 5'd20, 3'b000, 5'd21, RV32_OPCODE_JALR);
        dut.instruction_memory.memory[37] =
            rv32_s(32'd0, 5'd1, 5'd22, 3'b010, RV32_OPCODE_STORE);
        dut.instruction_memory.memory[38] = 32'h0000_0073;
        dut.instruction_memory.memory[39] =
            rv32_i(32'd4, 5'd21, 3'b000, 5'd23, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[40] =
            rv32_i(32'd24, 5'd0, 3'b010, 5'd24, RV32_OPCODE_LOAD);
        dut.instruction_memory.memory[41] =
            rv32_s(32'd0, 5'd13, 5'd24, 3'b010, RV32_OPCODE_STORE);
        dut.instruction_memory.memory[42] =
            rv32_i(32'd1, 5'd0, 3'b000, 5'd29, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[43] =
            rv32_j(32'd0, 5'd0, RV32_OPCODE_JAL);

        start_cpu;

        // Freeze a partially filled pipeline. No stage, side effect, retire
        // count, or stall count may advance while cpu_enable is low.
        repeat (3) @(posedge clk);
        #1;
        @(negedge clk);
        cpu_enable        = 1'b0;
        held_pc           = dut.program_counter.pc;
        held_valids       = {dut.mem_wb_valid, dut.ex_mem_valid,
                             dut.id_ex_valid, dut.if_id_valid};
        held_retire_count = retire_count;
        held_store_count  = ram_store_count;
        for (hold_cycle = 0; hold_cycle < 4; hold_cycle = hold_cycle + 1) begin
            @(posedge clk);
            #1;
            check32(dut.program_counter.pc, held_pc,
                    "cpu_enable=0 holds fetch PC");
            check32({28'd0, dut.mem_wb_valid, dut.ex_mem_valid,
                     dut.id_ex_valid, dut.if_id_valid},
                    {28'd0, held_valids},
                    "cpu_enable=0 holds pipeline valid bits");
            check32(retire_count, held_retire_count,
                    "cpu_enable=0 suppresses retirement");
            check32(ram_store_count, held_store_count,
                    "cpu_enable=0 suppresses repeated stores");
        end
        @(negedge clk);
        cpu_enable = 1'b1;

        wait_for_retires(33, 160);
        @(negedge clk);
        cpu_enable = 1'b0;
        #1;

        check32(fault, 1'b0, "hazard program has no fault");
        check32(retire_count, 32'd33, "dynamic instruction retire count");
        check32(ram_store_count, 32'd5, "exact RAM store commit count");
        check32(load_use_stall_count, 32'd5,
                "one bubble for each load-use dependency");

        check_reg(5'd1,  32'd5,          "x1 seed");
        check_reg(5'd2,  32'd12,         "EX/MEM forwarding");
        check_reg(5'd3,  32'd17,         "dual-source forwarding");
        check_reg(5'd5,  32'd18,         "load-to-ALU forwarding");
        check_reg(5'd6,  32'd18,         "load result");
        check_reg(5'd7,  32'h0000_0033,  "taken-branch target");
        check_reg(5'd8,  32'h0000_0044,  "not-taken branch path");
        check_reg(5'd9,  32'h0000_0048,  "JAL link");
        check_reg(5'd10, 32'h0000_004c,  "JAL-link consumer");
        check_reg(5'd12, 32'h0000_005c,  "JALR link");
        check_reg(5'd13, 32'h0000_0060,  "JALR-link consumer");
        check_reg(5'd15, 32'h0000_0060,  "load-to-store value");
        check_reg(5'd19, 32'h0000_0021,  "WB-to-ID bypass");
        check_reg(5'd20, 32'h0000_009c,  "JALR target load");
        check_reg(5'd21, 32'h0000_0094,  "load-to-JALR link");
        check_reg(5'd23, 32'h0000_0098,  "JALR target reached");
        check_reg(5'd24, 32'h0000_001c,  "store-address load");
        check_reg(5'd29, 32'd1,          "hazard program sentinel");
        check_reg(5'd30, 32'd0,          "all wrong-path RF writes squashed");

        check32(dut.data_memory.memory[0], 32'd17,
                "forwarded store data word 0");
        check32(dut.data_memory.memory[1], 32'd18,
                "load-use store word 1");
        check32(dut.data_memory.memory[2], 32'hcafe_babe,
                "wrong-path RAM stores squashed");
        check32(dut.data_memory.memory[3], 32'h0000_0060,
                "dual-forwarded store");
        check32(dut.data_memory.memory[4], 32'h0000_0060,
                "load-to-store data path");
        check32(dut.data_memory.memory[7], 32'h0000_0060,
                "load-to-store address path");
        check32({24'd0, output_port}, 32'd0,
                "wrong-path MMIO store squashed");

        // -------------------------------------------------------------
        // Phase B: precise fatal exception and sticky hold
        // -------------------------------------------------------------
        reset      = 1'b1;
        cpu_enable = 1'b0;
        #1;
        fill_nops;
        dut.data_memory.memory[0] = 32'h1122_3344;
        dut.data_memory.memory[1] = 32'h5566_7788;

        dut.instruction_memory.memory[0] =
            rv32_i(32'h055, 5'd0, 3'b000, 5'd1, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[1] =
            rv32_s(32'd0, 5'd1, 5'd0, 3'b010, RV32_OPCODE_STORE);
        dut.instruction_memory.memory[2] =
            rv32_i(32'd2, 5'd0, 3'b000, 5'd2, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[3] =
            rv32_i(32'd0, 5'd2, 3'b010, 5'd3, RV32_OPCODE_LOAD);
        dut.instruction_memory.memory[4] =
            rv32_i(32'h066, 5'd0, 3'b000, 5'd4, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[5] =
            rv32_s(32'd4, 5'd1, 5'd0, 3'b010, RV32_OPCODE_STORE);

        start_cpu;
        wait_for_fault(40);
        #1;

        check32(retire_count, 32'd3,
                "all older instructions retire before fault");
        check32(ram_store_count, 32'd1,
                "only the older store commits before fault");
        check32({27'd0, debug_trap_cause},
                {27'd0, CAUSE_LOAD_ADDR_MISALIGNED},
                "precise trap cause");
        check32(debug_trap_value, 32'd2, "precise trap value");
        check32(debug_pc, 32'h0000_000c, "faulting instruction PC");
        check32(debug_instruction,
                rv32_i(32'd0, 5'd2, 3'b010, 5'd3, RV32_OPCODE_LOAD),
                "faulting instruction debug value");
        check_reg(5'd1, 32'h0000_0055, "older ALU write committed");
        check_reg(5'd2, 32'h0000_0002, "last older ALU write committed");
        check_reg(5'd3, 32'd0, "faulting load write suppressed");
        check_reg(5'd4, 32'd0, "younger ALU write squashed");
        check32(dut.data_memory.memory[0], 32'h0000_0055,
                "older store committed");
        check32(dut.data_memory.memory[1], 32'h5566_7788,
                "younger store squashed");

        held_pc           = debug_pc;
        held_memory0      = dut.data_memory.memory[0];
        held_memory1      = dut.data_memory.memory[1];
        held_rf_valid     = dut.register_file.valid;
        held_output       = output_port;
        held_retire_count = retire_count;
        held_store_count  = ram_store_count;
        repeat (3) begin
            @(posedge clk);
            #1;
            check32(debug_pc, held_pc, "fault holds trap PC");
            check32(dut.data_memory.memory[0], held_memory0,
                    "fault holds RAM word 0");
            check32(dut.data_memory.memory[1], held_memory1,
                    "fault holds RAM word 1");
            check32(dut.register_file.valid, held_rf_valid,
                    "fault holds Register File valid mask");
            check32({24'd0, output_port}, {24'd0, held_output},
                    "fault holds MMIO output");
            check32(retire_count, held_retire_count,
                    "fault suppresses retirement");
            check32(ram_store_count, held_store_count,
                    "fault suppresses stores");
            check32({27'd0, debug_trap_cause},
                    {27'd0, CAUSE_LOAD_ADDR_MISALIGNED},
                    "fault cause remains sticky");
            check32(debug_trap_value, 32'd2,
                    "fault value remains sticky");
        end

        // -------------------------------------------------------------
        // Phase C: asynchronous reset flushes an in-flight pipeline
        // -------------------------------------------------------------
        @(negedge clk);
        reset      = 1'b1;
        cpu_enable = 1'b0;
        #1;
        fill_nops;
        dut.data_memory.memory[0] = 32'haabb_ccdd;
        dut.instruction_memory.memory[0] =
            rv32_i(32'h02a, 5'd0, 3'b000, 5'd1, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[1] =
            rv32_i(32'd1, 5'd1, 3'b000, 5'd2, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[2] =
            rv32_s(32'd0, 5'd2, 5'd0, 3'b010, RV32_OPCODE_STORE);

        start_cpu;
        repeat (3) @(posedge clk);
        #1;
        if (!(dut.if_id_valid || dut.id_ex_valid || dut.ex_mem_valid))
            $fatal(1, "pipeline did not fill before reset test");

        @(negedge clk);
        reset = 1'b1;
        #1;
        check32(dut.program_counter.pc, 32'd0,
                "reset clears Program Counter");
        check32({28'd0, dut.mem_wb_valid, dut.ex_mem_valid,
                 dut.id_ex_valid, dut.if_id_valid},
                32'd0, "reset flushes all pipeline valid bits");
        check32(dut.register_file.valid, 32'd0,
                "reset clears Register File validity");
        check32(dut.data_memory.memory[0], 32'haabb_ccdd,
                "reset preserves physical Data RAM");
        check32(fault, 1'b0, "reset clears sticky fault");
        check32(dut.trap_pending, 1'b0,
                "reset clears pending exception drain");
        check32({24'd0, output_port}, 32'd0,
                "reset clears output port");

        // -------------------------------------------------------------
        // Phase D: newest forwarding priority and retire interface
        // -------------------------------------------------------------
        cpu_enable = 1'b0;
        #1;
        fill_nops;
        dut.data_memory.memory[0] = 32'ha5a5_5a5a;

        dut.instruction_memory.memory[0] =
            rv32_i(32'd1, 5'd0, 3'b000, 5'd1, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[1] =
            rv32_i(32'd2, 5'd0, 3'b000, 5'd1, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[2] =
            rv32_r(7'b0000000, 5'd0, 5'd1, 3'b000, 5'd2,
                   RV32_OPCODE_OP);
        dut.instruction_memory.memory[3] =
            rv32_i(32'h05a, 5'd0, 3'b000, 5'd3, RV32_OPCODE_OP_IMM);
        dut.instruction_memory.memory[4] =
            rv32_s(32'd0, 5'd3, 5'd0, 3'b010, RV32_OPCODE_STORE);
        dut.instruction_memory.memory[5] =
            rv32_j(32'd0, 5'd0, RV32_OPCODE_JAL);

        start_cpu;
        wait_and_check_retire(
            32'h0000_0000,
            rv32_i(32'd1, 5'd0, 3'b000, 5'd1, RV32_OPCODE_OP_IMM),
            "first same-rd producer");
        wait_and_check_retire(
            32'h0000_0004,
            rv32_i(32'd2, 5'd0, 3'b000, 5'd1, RV32_OPCODE_OP_IMM),
            "second same-rd producer");
        wait_and_check_retire(
            32'h0000_0008,
            rv32_r(7'b0000000, 5'd0, 5'd1, 3'b000, 5'd2,
                   RV32_OPCODE_OP),
            "same-rd consumer");

        // The store is now resident in EX/MEM. Stop the entire pipeline
        // before its MEM edge and prove that it neither commits repeatedly
        // nor retires while disabled.
        @(negedge clk);
        if (!(dut.ex_mem_valid && dut.ex_mem_mem_write))
            $fatal(1, "store did not reach EX/MEM at freeze point");
        cpu_enable        = 1'b0;
        held_memory0      = dut.data_memory.memory[0];
        held_store_count  = ram_store_count;
        held_retire_count = retire_count;
        repeat (3) begin
            @(posedge clk);
            #1;
            check32(dut.data_memory.memory[0], held_memory0,
                    "disabled MEM store leaves RAM unchanged");
            check32(ram_store_count, held_store_count,
                    "disabled MEM store does not recommit");
            check32(retire_count, held_retire_count,
                    "disabled MEM store does not retire");
        end

        @(negedge clk);
        cpu_enable = 1'b1;
        wait_for_retires(5, 40);
        @(negedge clk);
        cpu_enable = 1'b0;
        #1;

        check_reg(5'd1, 32'd2, "newest same-rd producer committed");
        check_reg(5'd2, 32'd2, "EX/MEM wins same-rd forwarding conflict");
        check32(dut.data_memory.memory[0], 32'h0000_005a,
                "held MEM store commits once after resume");
        check32(ram_store_count, 32'd1,
                "held MEM store exact commit count");

        cpu_enable = 1'b0;
        if (failures == 0) begin
            $display("PASS: tb_v2_pipeline (forward/stall/flush/enable/precise-trap/reset/retire)");
            $finish;
        end else begin
            $fatal(1, "FAIL: tb_v2_pipeline had %0d error(s)", failures);
        end
    end

    initial begin
        #10000;
        $fatal(1, "TIMEOUT: tb_v2_pipeline");
    end
endmodule

`default_nettype wire
