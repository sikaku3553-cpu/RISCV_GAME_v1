`timescale 1ns/1ps
`default_nettype none

// Self-checking exception/fault tests for TD8_RISCV_V2_Core.
//
// v2 exposes fatal synchronous traps as debug cause/value signals rather than
// implementing privileged trap CSRs.  Each faulting case therefore checks the
// reported cause/value and clocks the core once more to prove that PC, RF
// validity/data, RAM and the output MMIO register receive no side effects.
module tb_v2_faults;
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

    integer failures;
    integer i;

    localparam [6:0] OP_IMM = 7'b0010011;
    localparam [6:0] OP      = 7'b0110011;
    localparam [6:0] LOAD    = 7'b0000011;
    localparam [6:0] STORE   = 7'b0100011;
    localparam [6:0] BRANCH  = 7'b1100011;
    localparam [6:0] JAL     = 7'b1101111;
    localparam [6:0] JALR    = 7'b1100111;

    localparam [4:0] CAUSE_INST_ADDR_MISALIGNED  = 5'd0;
    localparam [4:0] CAUSE_INST_ACCESS_FAULT     = 5'd1;
    localparam [4:0] CAUSE_ILLEGAL_INSTRUCTION   = 5'd2;
    localparam [4:0] CAUSE_BREAKPOINT            = 5'd3;
    localparam [4:0] CAUSE_LOAD_ADDR_MISALIGNED  = 5'd4;
    localparam [4:0] CAUSE_LOAD_ACCESS_FAULT     = 5'd5;
    localparam [4:0] CAUSE_STORE_ADDR_MISALIGNED = 5'd6;
    localparam [4:0] CAUSE_STORE_ACCESS_FAULT    = 5'd7;
    localparam [4:0] CAUSE_ECALL_FROM_M_MODE     = 5'd11;

    TD8_RISCV_V2_Core #(
        .IMEM_WORDS(16),
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

    function automatic [31:0] make_r;
        input [6:0] funct7;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] funct3;
        input [4:0] rd;
        input [6:0] opcode;
        begin
            make_r = {funct7, rs2, rs1, funct3, rd, opcode};
        end
    endfunction

    function automatic [31:0] make_i;
        input [31:0] imm;
        input [4:0]  rs1;
        input [2:0]  funct3;
        input [4:0]  rd;
        input [6:0]  opcode;
        begin
            make_i = {imm[11:0], rs1, funct3, rd, opcode};
        end
    endfunction

    function automatic [31:0] make_s;
        input [31:0] imm;
        input [4:0]  rs2;
        input [4:0]  rs1;
        input [2:0]  funct3;
        begin
            make_s = {imm[11:5], rs2, rs1, funct3, imm[4:0], STORE};
        end
    endfunction

    function automatic [31:0] make_b;
        input [31:0] imm;
        input [4:0]  rs2;
        input [4:0]  rs1;
        input [2:0]  funct3;
        begin
            make_b = {imm[12], imm[10:5], rs2, rs1, funct3,
                      imm[4:1], imm[11], BRANCH};
        end
    endfunction

    function automatic [31:0] make_j;
        input [31:0] imm;
        input [4:0]  rd;
        begin
            make_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd, JAL};
        end
    endfunction

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
        input [4:0]  address;
        input [31:0] expected;
        input [8*80-1:0] description;
        begin
            debug_reg_addr = address;
            #1;
            check32(debug_reg_data, expected, description);
        end
    endtask

    // Assert reset and establish a repeatable architectural/data-memory state.
    // The RAM is intentionally not reset by RTL, so this white-box initialization
    // is needed to make suppression of faulting stores directly observable.
    task automatic prepare_case;
        input [8*80-1:0] description;
        begin
            $display("[CASE] %0s", description);
            cpu_enable = 1'b0;
            reset      = 1'b1;
            #1;
            for (i = 0; i < 16; i = i + 1)
                dut.instruction_memory.memory[i] = 32'h0000_0013; // NOP
            dut.data_memory.memory[0] = 32'hcafe_babe;
            dut.data_memory.memory[1] = 32'h0123_4567;
        end
    endtask

    task automatic start_case;
        begin
            repeat (2) @(posedge clk);
            #1;
            reset      = 1'b0;
            cpu_enable = 1'b1;
            #1;
        end
    endtask

    // Retire only instructions that are expected to be legal and non-faulting.
    // A fault may appear immediately after the last edge when the next PC is
    // selected, so only the pre-edge state is checked here.
    task automatic retire_legal;
        input integer count;
        input [8*80-1:0] description;
        integer retired;
        integer cycle;
        begin
            retired = 0;
            cycle   = 0;
            while ((retired < count) &&
                   (cycle < (count * 8 + 32))) begin
                @(posedge clk);
                if (retire_valid)
                    retired = retired + 1;
                #1;
                if (fault && (retired < count)) begin
                    $display("[FAIL] %0s: early fault at pc=%08x cause=%0d tval=%08x",
                             description, debug_pc, debug_trap_cause,
                             debug_trap_value);
                    failures = failures + 1;
                end
                cycle = cycle + 1;
            end
            if (retired != count) begin
                $display("[FAIL] %0s: timeout waiting for %0d retires (got %0d)",
                         description, count, retired);
                failures = failures + 1;
            end
        end
    endtask

    // Check trap metadata, then apply a clock edge and verify that the fatal
    // fault blocks every state-changing destination visible in this design.
    task automatic check_fault_and_hold;
        input [4:0]  expected_cause;
        input [31:0] expected_value;
        input [4:0]  observed_reg;
        input [8*80-1:0] description;
        reg [31:0] pc_before;
        reg [31:0] valid_before;
        reg [31:0] register_before;
        reg [31:0] memory0_before;
        reg [31:0] memory1_before;
        reg [7:0]  output_before;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while (!fault && (wait_cycles < 40)) begin
                @(posedge clk);
                #1;
                wait_cycles = wait_cycles + 1;
            end
            if (!fault) begin
                $display("[FAIL] %0s: expected fault, pc=%08x instruction=%08x",
                         description, debug_pc, debug_instruction);
                failures = failures + 1;
            end
            check32({27'd0, debug_trap_cause}, {27'd0, expected_cause},
                    "trap cause");
            check32(debug_trap_value, expected_value, "trap value");

            debug_reg_addr = observed_reg;
            #1;
            pc_before       = debug_pc;
            valid_before    = dut.register_file.valid;
            register_before = debug_reg_data;
            memory0_before  = dut.data_memory.memory[0];
            memory1_before  = dut.data_memory.memory[1];
            output_before   = output_port;

            @(posedge clk);
            #1;
            if (!fault) begin
                $display("[FAIL] %0s: fault did not remain asserted", description);
                failures = failures + 1;
            end
            check32(debug_pc,                    pc_before,       "fault holds PC");
            check32(dut.register_file.valid,     valid_before,    "fault holds RF valid mask");
            check32(debug_reg_data,              register_before, "fault suppresses RF write");
            check32(dut.data_memory.memory[0],   memory0_before,  "fault suppresses RAM word 0 write");
            check32(dut.data_memory.memory[1],   memory1_before,  "fault suppresses RAM word 1 write");
            check32({24'd0, output_port}, {24'd0, output_before}, "fault suppresses output write");
            check32({27'd0, debug_trap_cause}, {27'd0, expected_cause},
                    "fault cause remains stable");
            check32(debug_trap_value, expected_value, "fault value remains stable");
        end
    endtask

    initial begin
        clk            = 1'b0;
        reset          = 1'b1;
        cpu_enable     = 1'b0;
        input_port     = 8'ha5;
        debug_reg_addr = 5'd0;
        failures       = 0;
        #1;

        // A non-taken branch must not report its misaligned hypothetical target.
        prepare_case("non-taken branch ignores misaligned target");
        dut.instruction_memory.memory[0] = make_b(32'd2, 5'd0, 5'd0, 3'b001); // BNE x0,x0,+2
        dut.instruction_memory.memory[1] = make_i(32'd9, 5'd0, 3'b000, 5'd5, OP_IMM);
        start_case;
        if (fault) begin
            $display("[FAIL] non-taken branch incorrectly faulted");
            failures = failures + 1;
        end
        retire_legal(2, "non-taken branch and following ADDI");
        check32(debug_pc, 32'd8, "non-taken branch advances by four");
        check_reg(5'd5, 32'd9, "instruction after non-taken branch executes");

        // A taken control transfer to an IALIGN=32-invalid target faults on
        // the control-transfer instruction and must not write its link register.
        prepare_case("JAL target-address misalignment");
        dut.instruction_memory.memory[0] = make_j(32'd2, 5'd5);
        start_case;
        check_fault_and_hold(CAUSE_INST_ADDR_MISALIGNED, 32'd2, 5'd5,
                             "misaligned JAL target");
        check_reg(5'd5, 32'd0, "misaligned JAL does not write link register");

        prepare_case("JALR target-address misalignment after bit-zero clearing");
        dut.instruction_memory.memory[0] = make_i(32'd2, 5'd0, 3'b000, 5'd1, OP_IMM);
        dut.instruction_memory.memory[1] = make_i(32'd0, 5'd1, 3'b000, 5'd5, JALR);
        start_case;
        retire_legal(1, "JALR base setup");
        check_fault_and_hold(CAUSE_INST_ADDR_MISALIGNED, 32'd2, 5'd5,
                             "misaligned JALR target");
        check_reg(5'd5, 32'd0, "misaligned JALR does not write link register");

        // An aligned, out-of-range target is allowed to retire.  The subsequent
        // fetch reports cause 1, and that faulting fetch cannot change state.
        prepare_case("aligned out-of-range target becomes fetch access fault");
        dut.instruction_memory.memory[0] = make_j(32'd64, 5'd5);
        start_case;
        retire_legal(1, "out-of-range JAL retirement");
        check32(debug_pc, 32'd64, "JAL reaches first byte beyond 16-word ROM");
        check_reg(5'd5, 32'd4, "out-of-range JAL still writes link before fetch fault");
        check_fault_and_hold(CAUSE_INST_ACCESS_FAULT, 32'd64, 5'd5,
                             "out-of-range instruction fetch");

        // White-box PC injection reaches the otherwise guarded fetch-alignment
        // detector independently of the target-alignment detector.
        prepare_case("direct misaligned instruction fetch");
        start_case;
        dut.program_counter.pc = 32'd2;
        #1;
        check_fault_and_hold(CAUSE_INST_ADDR_MISALIGNED, 32'd2, 5'd5,
                             "misaligned current PC");

        // Strict decoding: M-extension OP, reserved LOAD funct3 and reserved
        // SLLI upper immediate bits are all illegal RV32I encodings.
        prepare_case("illegal M-extension OP encoding");
        dut.instruction_memory.memory[0] = make_i(32'h055, 5'd0, 3'b000, 5'd5, OP_IMM);
        dut.instruction_memory.memory[1] = make_r(7'b0000001, 5'd0, 5'd5, 3'b000, 5'd5, OP);
        start_case;
        retire_legal(1, "illegal OP setup");
        check_fault_and_hold(CAUSE_ILLEGAL_INSTRUCTION,
                             make_r(7'b0000001, 5'd0, 5'd5, 3'b000, 5'd5, OP),
                             5'd5, "M-extension encoding is illegal");
        check_reg(5'd5, 32'h0000_0055, "illegal OP preserves destination");

        prepare_case("illegal LOAD funct3 encoding");
        dut.instruction_memory.memory[0] = make_i(32'd0, 5'd0, 3'b011, 5'd5, LOAD);
        start_case;
        check_fault_and_hold(CAUSE_ILLEGAL_INSTRUCTION,
                             make_i(32'd0, 5'd0, 3'b011, 5'd5, LOAD),
                             5'd5, "reserved LOAD encoding");

        prepare_case("illegal SLLI upper immediate encoding");
        dut.instruction_memory.memory[0] = make_i(32'h401, 5'd0, 3'b001, 5'd5, OP_IMM);
        start_case;
        check_fault_and_hold(CAUSE_ILLEGAL_INSTRUCTION,
                             make_i(32'h401, 5'd0, 3'b001, 5'd5, OP_IMM),
                             5'd5, "reserved SLLI encoding");

        // Base SYSTEM encodings have their distinct synchronous causes.
        prepare_case("ECALL from machine execution environment");
        dut.instruction_memory.memory[0] = 32'h0000_0073;
        start_case;
        check_fault_and_hold(CAUSE_ECALL_FROM_M_MODE, 32'd0, 5'd5, "ECALL");

        prepare_case("EBREAK reports breakpoint and current PC");
        dut.instruction_memory.memory[0] = make_i(32'h022, 5'd0, 3'b000, 5'd5, OP_IMM);
        dut.instruction_memory.memory[1] = 32'h0010_0073;
        start_case;
        retire_legal(1, "EBREAK setup");
        check_fault_and_hold(CAUSE_BREAKPOINT, 32'd4, 5'd5, "EBREAK");
        check_reg(5'd5, 32'h0000_0022, "EBREAK preserves prior register state");

        // Load alignment checks for both alignment-sensitive widths.
        prepare_case("misaligned LH");
        dut.instruction_memory.memory[0] = make_i(32'd1, 5'd0, 3'b000, 5'd1, OP_IMM);
        dut.instruction_memory.memory[1] = make_i(32'd0, 5'd1, 3'b001, 5'd5, LOAD);
        start_case;
        retire_legal(1, "LH address setup");
        check_fault_and_hold(CAUSE_LOAD_ADDR_MISALIGNED, 32'd1, 5'd5, "LH address 1");

        prepare_case("misaligned LW");
        dut.instruction_memory.memory[0] = make_i(32'd2, 5'd0, 3'b000, 5'd1, OP_IMM);
        dut.instruction_memory.memory[1] = make_i(32'd0, 5'd1, 3'b010, 5'd5, LOAD);
        start_case;
        retire_legal(1, "LW address setup");
        check_fault_and_hold(CAUSE_LOAD_ADDR_MISALIGNED, 32'd2, 5'd5, "LW address 2");

        // Store alignment checks also prove the faulting write strobes are gated.
        prepare_case("misaligned SH has no RAM side effect");
        dut.instruction_memory.memory[0] = make_i(32'h05a, 5'd0, 3'b000, 5'd2, OP_IMM);
        dut.instruction_memory.memory[1] = make_s(32'd1, 5'd2, 5'd0, 3'b001);
        start_case;
        retire_legal(1, "SH data setup");
        check_fault_and_hold(CAUSE_STORE_ADDR_MISALIGNED, 32'd1, 5'd5, "SH address 1");

        prepare_case("misaligned SW has no RAM side effect");
        dut.instruction_memory.memory[0] = make_i(32'h05a, 5'd0, 3'b000, 5'd2, OP_IMM);
        dut.instruction_memory.memory[1] = make_s(32'd2, 5'd2, 5'd0, 3'b010);
        start_case;
        retire_legal(1, "SW data setup");
        check_fault_and_hold(CAUSE_STORE_ADDR_MISALIGNED, 32'd2, 5'd5, "SW address 2");

        // Address-map checks: RAM is 0x000..0x0ff; only aligned word accesses
        // are accepted at the exact 0x100 input and 0x104 output registers.
        prepare_case("out-of-map load access fault");
        dut.instruction_memory.memory[0] = make_i(32'h108, 5'd0, 3'b000, 5'd1, OP_IMM);
        dut.instruction_memory.memory[1] = make_i(32'd0, 5'd1, 3'b010, 5'd5, LOAD);
        start_case;
        retire_legal(1, "load access address setup");
        check_fault_and_hold(CAUSE_LOAD_ACCESS_FAULT, 32'h0000_0108, 5'd5,
                             "LW beyond implemented map");

        // Loads to x0 must still perform address checks and raise exceptions.
        prepare_case("out-of-map load to x0 still faults");
        dut.instruction_memory.memory[0] = make_i(32'h108, 5'd0, 3'b010, 5'd0, LOAD);
        start_case;
        check_fault_and_hold(CAUSE_LOAD_ACCESS_FAULT, 32'h0000_0108, 5'd0,
                             "LW to x0 beyond implemented map");

        prepare_case("subword input-MMIO load is rejected");
        dut.instruction_memory.memory[0] = make_i(32'h100, 5'd0, 3'b100, 5'd5, LOAD); // LBU
        start_case;
        check_fault_and_hold(CAUSE_LOAD_ACCESS_FAULT, 32'h0000_0100, 5'd5,
                             "LBU from word-only input register");

        prepare_case("store to read-only input MMIO is rejected");
        dut.instruction_memory.memory[0] = make_i(32'h05a, 5'd0, 3'b000, 5'd2, OP_IMM);
        dut.instruction_memory.memory[1] = make_s(32'h104, 5'd2, 5'd0, 3'b010); // legal output seed
        dut.instruction_memory.memory[2] = make_s(32'h100, 5'd2, 5'd0, 3'b010); // illegal input write
        start_case;
        retire_legal(2, "output seed before input-store fault");
        check32({24'd0, output_port}, 32'h0000_005a, "legal output seed committed");
        check_fault_and_hold(CAUSE_STORE_ACCESS_FAULT, 32'h0000_0100, 5'd5,
                             "SW to read-only input register");

        prepare_case("subword output-MMIO store is rejected");
        dut.instruction_memory.memory[0] = make_i(32'h05a, 5'd0, 3'b000, 5'd2, OP_IMM);
        dut.instruction_memory.memory[1] = make_s(32'h104, 5'd2, 5'd0, 3'b010); // legal output seed
        dut.instruction_memory.memory[2] = make_i(32'h0a5, 5'd0, 3'b000, 5'd2, OP_IMM);
        dut.instruction_memory.memory[3] = make_s(32'h104, 5'd2, 5'd0, 3'b000); // illegal SB
        start_case;
        retire_legal(3, "output seed before subword-store fault");
        check32({24'd0, output_port}, 32'h0000_005a, "output remains seeded before SB fault");
        check_fault_and_hold(CAUSE_STORE_ACCESS_FAULT, 32'h0000_0104, 5'd5,
                             "SB to word-only output register");
        check32({24'd0, output_port}, 32'h0000_005a, "faulting SB preserves output value");

        prepare_case("out-of-map store access fault");
        dut.instruction_memory.memory[0] = make_i(32'h05a, 5'd0, 3'b000, 5'd2, OP_IMM);
        dut.instruction_memory.memory[1] = make_s(32'h108, 5'd2, 5'd0, 3'b010);
        start_case;
        retire_legal(1, "store access data setup");
        check_fault_and_hold(CAUSE_STORE_ACCESS_FAULT, 32'h0000_0108, 5'd5,
                             "SW beyond implemented map");

        cpu_enable = 1'b0;
        if (failures == 0) begin
            $display("PASS: tb_v2_faults (20 decode/SYSTEM/alignment/access/target/fetch cases)");
            $finish;
        end else begin
            $fatal(1, "FAIL: tb_v2_faults had %0d error(s)", failures);
        end
    end
endmodule

`default_nettype wire
