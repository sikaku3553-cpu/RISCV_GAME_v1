`timescale 1ns/1ps
`default_nettype none

// Self-checking tests for the RV32I load/store datapath.
//
// The program below deliberately builds 0x80ff7f01, stores it with SW and
// reads it through every RV32I load instruction.  It then exercises each of
// the four byte lanes with SB, both halfword lanes with SH and all lanes with
// SW.  Consequently the checks cover little-endian lane selection as well as
// signed/unsigned extension.
module tb_v2_memory;
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
    localparam [6:0] LUI_OP = 7'b0110111;
    localparam [6:0] LOAD   = 7'b0000011;
    localparam [6:0] STORE  = 7'b0100011;
    localparam [6:0] JAL    = 7'b1101111;

    TD8_RISCV_V2_Core #(
        .IMEM_WORDS(64),
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

    function automatic [31:0] make_u;
        input [19:0] imm20;
        input [4:0]  rd;
        input [6:0]  opcode;
        begin
            make_u = {imm20, rd, opcode};
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
        input [8*64-1:0] description;
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
        input [8*64-1:0] description;
        begin
            debug_reg_addr = address;
            #1;
            check32(debug_reg_data, expected, description);
        end
    endtask

    task automatic run_retires;
        input integer count;
        integer retired;
        integer cycle;
        begin
            retired = 0;
            cycle   = 0;
            while ((retired < count) && (cycle < (count * 8 + 32))) begin
                if (fault) begin
                    $display("[FAIL] unexpected fault before cycle %0d: pc=%08x cause=%0d tval=%08x",
                             cycle, debug_pc, debug_trap_cause, debug_trap_value);
                    failures = failures + 1;
                end
                @(posedge clk);
                if (retire_valid)
                    retired = retired + 1;
                #1;
                cycle = cycle + 1;
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
        input_port     = 8'h00;
        debug_reg_addr = 5'd0;
        failures       = 0;

        // Avoid a time-zero race with InstructionMemoryV2's initializer.
        #1;
        for (i = 0; i < 64; i = i + 1)
            dut.instruction_memory.memory[i] = 32'h0000_0013; // NOP

        // x2 = 0x80ff7f01; SW establishes bytes 01, 7f, ff, 80 at 0..3.
        dut.instruction_memory.memory[0]  = make_u(20'h80ff8, 5'd2, LUI_OP);
        dut.instruction_memory.memory[1]  = make_i(-32'sd255, 5'd2, 3'b000, 5'd2, OP_IMM);
        dut.instruction_memory.memory[2]  = make_s(32'd0, 5'd2, 5'd0, 3'b010); // SW

        // Every byte lane, signed and unsigned.
        dut.instruction_memory.memory[3]  = make_i(32'd0, 5'd0, 3'b000, 5'd10, LOAD); // LB
        dut.instruction_memory.memory[4]  = make_i(32'd1, 5'd0, 3'b000, 5'd11, LOAD);
        dut.instruction_memory.memory[5]  = make_i(32'd2, 5'd0, 3'b000, 5'd12, LOAD);
        dut.instruction_memory.memory[6]  = make_i(32'd3, 5'd0, 3'b000, 5'd13, LOAD);
        dut.instruction_memory.memory[7]  = make_i(32'd0, 5'd0, 3'b100, 5'd14, LOAD); // LBU
        dut.instruction_memory.memory[8]  = make_i(32'd1, 5'd0, 3'b100, 5'd15, LOAD);
        dut.instruction_memory.memory[9]  = make_i(32'd2, 5'd0, 3'b100, 5'd16, LOAD);
        dut.instruction_memory.memory[10] = make_i(32'd3, 5'd0, 3'b100, 5'd17, LOAD);

        // Both naturally aligned halfword lanes, signed and unsigned, plus LW.
        dut.instruction_memory.memory[11] = make_i(32'd0, 5'd0, 3'b001, 5'd18, LOAD); // LH
        dut.instruction_memory.memory[12] = make_i(32'd2, 5'd0, 3'b001, 5'd19, LOAD);
        dut.instruction_memory.memory[13] = make_i(32'd0, 5'd0, 3'b101, 5'd20, LOAD); // LHU
        dut.instruction_memory.memory[14] = make_i(32'd2, 5'd0, 3'b101, 5'd21, LOAD);
        dut.instruction_memory.memory[15] = make_i(32'd0, 5'd0, 3'b010, 5'd22, LOAD); // LW

        // SB: write one distinctive value through each of the four lanes.
        dut.instruction_memory.memory[16] = make_i(32'h0a1, 5'd0, 3'b000, 5'd3, OP_IMM);
        dut.instruction_memory.memory[17] = make_s(32'd4, 5'd3, 5'd0, 3'b000);
        dut.instruction_memory.memory[18] = make_i(32'h0b2, 5'd0, 3'b000, 5'd3, OP_IMM);
        dut.instruction_memory.memory[19] = make_s(32'd5, 5'd3, 5'd0, 3'b000);
        dut.instruction_memory.memory[20] = make_i(32'h0c3, 5'd0, 3'b000, 5'd3, OP_IMM);
        dut.instruction_memory.memory[21] = make_s(32'd6, 5'd3, 5'd0, 3'b000);
        dut.instruction_memory.memory[22] = make_i(32'h0d4, 5'd0, 3'b000, 5'd3, OP_IMM);
        dut.instruction_memory.memory[23] = make_s(32'd7, 5'd3, 5'd0, 3'b000);

        // SH: exercise the low and high halfword strobes independently.
        dut.instruction_memory.memory[24] = make_u(20'h00005, 5'd4, LUI_OP);
        dut.instruction_memory.memory[25] = make_i(32'h566, 5'd4, 3'b000, 5'd4, OP_IMM);
        dut.instruction_memory.memory[26] = make_s(32'd8, 5'd4, 5'd0, 3'b001);
        dut.instruction_memory.memory[27] = make_u(20'h0000b, 5'd4, LUI_OP);
        dut.instruction_memory.memory[28] = make_i(-32'sd1349, 5'd4, 3'b000, 5'd4, OP_IMM);
        dut.instruction_memory.memory[29] = make_s(32'd10, 5'd4, 5'd0, 3'b001);

        // SW: all four strobes together.
        dut.instruction_memory.memory[30] = make_u(20'h11223, 5'd5, LUI_OP);
        dut.instruction_memory.memory[31] = make_i(32'h344, 5'd5, 3'b000, 5'd5, OP_IMM);
        dut.instruction_memory.memory[32] = make_s(32'd12, 5'd5, 5'd0, 3'b010);

        // Read back the three store results through the architectural path.
        dut.instruction_memory.memory[33] = make_i(32'd4, 5'd0, 3'b010, 5'd23, LOAD);
        dut.instruction_memory.memory[34] = make_i(32'd8, 5'd0, 3'b010, 5'd24, LOAD);
        dut.instruction_memory.memory[35] = make_i(32'd12, 5'd0, 3'b010, 5'd25, LOAD);
        dut.instruction_memory.memory[36] = make_j(32'd0, 5'd0); // stable legal loop

        repeat (2) @(posedge clk);
        #1;
        reset      = 1'b0;
        cpu_enable = 1'b1;

        run_retires(37);
        cpu_enable = 1'b0;

        if (fault) begin
            $display("[FAIL] memory test ended in fault: pc=%08x cause=%0d tval=%08x",
                     debug_pc, debug_trap_cause, debug_trap_value);
            failures = failures + 1;
        end

        // LB/LBU lane and sign-extension checks.
        check_reg(5'd10, 32'h0000_0001, "LB lane 0");
        check_reg(5'd11, 32'h0000_007f, "LB lane 1");
        check_reg(5'd12, 32'hffff_ffff, "LB lane 2 sign extension");
        check_reg(5'd13, 32'hffff_ff80, "LB lane 3 sign extension");
        check_reg(5'd14, 32'h0000_0001, "LBU lane 0");
        check_reg(5'd15, 32'h0000_007f, "LBU lane 1");
        check_reg(5'd16, 32'h0000_00ff, "LBU lane 2 zero extension");
        check_reg(5'd17, 32'h0000_0080, "LBU lane 3 zero extension");

        // LH/LHU and LW checks also make the little-endian byte order explicit.
        check_reg(5'd18, 32'h0000_7f01, "LH low halfword");
        check_reg(5'd19, 32'hffff_80ff, "LH high halfword sign extension");
        check_reg(5'd20, 32'h0000_7f01, "LHU low halfword");
        check_reg(5'd21, 32'h0000_80ff, "LHU high halfword zero extension");
        check_reg(5'd22, 32'h80ff_7f01, "LW little-endian word");

        // Underlying words verify the write strobes; architectural readbacks
        // verify that the same results are observable by subsequent loads.
        check32(debug_mem_word0,                  32'h80ff_7f01, "SW all lanes word 0");
        check32(dut.data_memory.memory[1],        32'hd4c3_b2a1, "SB lanes 0 through 3");
        check32(dut.data_memory.memory[2],        32'haabb_5566, "SH low and high lanes");
        check32(dut.data_memory.memory[3],        32'h1122_3344, "SW all lanes word 3");
        check_reg(5'd23,                         32'hd4c3_b2a1, "SB result readback");
        check_reg(5'd24,                         32'haabb_5566, "SH result readback");
        check_reg(5'd25,                         32'h1122_3344, "SW result readback");
        check_reg(5'd0,                          32'h0000_0000, "x0 remains zero");
        check32({24'd0, output_port},            32'h0000_0000, "RAM stores do not change MMIO output");

        if (failures == 0) begin
            $display("PASS: tb_v2_memory (LB/LH/LW/LBU/LHU, SB/SH/SW, all lanes, little endian)");
            $finish;
        end else begin
            $fatal(1, "FAIL: tb_v2_memory had %0d error(s)", failures);
        end
    end
endmodule

`default_nettype wire
