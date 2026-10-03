`timescale 1ns/1ps
`default_nettype none

// TD8-derived, five-stage pipelined RV32I v2 core.
//
// Pipeline: IF -> ID -> EX -> MEM -> WB. The small asynchronous instruction
// and data memories are retained so the existing distributed-RAM-oriented
// implementation remains usable. RAW hazards are handled with EX/MEM and
// MEM/WB forwarding, an explicit WB-to-ID bypass, and a one-cycle load-use
// stall. Taken control transfers are resolved in EX and flush both younger
// stages.
//
// Synchronous exceptions travel to WB as in-order tokens. Younger work is
// squashed at EX detection, while older MEM/WB work is allowed to finish.
// The externally visible fatal fault therefore becomes sticky only after all
// older architectural side effects have committed.
//
// Implemented ISA: all 40 instructions in the unprivileged RV32I base.
// Execution environment: 256-byte RAM, word-only MMIO, fatal synchronous
// traps, and no privileged CSRs, trap vector, or interrupts.
module TD8_RISCV_V2_Core #(
    parameter integer IMEM_WORDS = 64,
    parameter integer INIT_DEMO = 1,
    parameter IMEM_INIT_FILE = "",
    parameter integer ENABLE_RF_DEBUG = 0,
    parameter integer ENABLE_MEM_DEBUG = 0
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        cpu_enable,
    input  wire [7:0]  input_port,
    input  wire [4:0]  debug_reg_addr,
    output reg  [7:0]  output_port,
    output wire [31:0] debug_pc,
    output wire [31:0] debug_instruction,
    output wire [31:0] debug_reg_data,
    output wire [31:0] debug_mem_word0,
    output reg  [4:0]  debug_trap_cause,
    output reg  [31:0] debug_trap_value,
    output wire        fault,
    output wire        retire_valid,
    output wire [31:0] retire_pc,
    output wire [31:0] retire_instruction
);
    localparam [31:0] IO_IN_ADDR  = 32'h0000_0100;
    localparam [31:0] IO_OUT_ADDR = 32'h0000_0104;
    localparam [31:0] IMEM_BYTES  = IMEM_WORDS * 4;

    localparam [4:0] CAUSE_INST_ADDR_MISALIGNED = 5'd0;
    localparam [4:0] CAUSE_INST_ACCESS_FAULT    = 5'd1;
    localparam [4:0] CAUSE_ILLEGAL_INSTRUCTION  = 5'd2;
    localparam [4:0] CAUSE_BREAKPOINT           = 5'd3;
    localparam [4:0] CAUSE_LOAD_ADDR_MISALIGNED = 5'd4;
    localparam [4:0] CAUSE_LOAD_ACCESS_FAULT    = 5'd5;
    localparam [4:0] CAUSE_STORE_ADDR_MISALIGNED= 5'd6;
    localparam [4:0] CAUSE_STORE_ACCESS_FAULT   = 5'd7;
    localparam [4:0] CAUSE_ECALL_FROM_M_MODE    = 5'd11;

    localparam [1:0] ALU_A_RS1  = 2'd0;
    localparam [1:0] ALU_A_PC   = 2'd1;
    localparam [1:0] ALU_A_ZERO = 2'd2;

    localparam [1:0] RESULT_ALU = 2'd0;
    localparam [1:0] RESULT_MEM = 2'd1;
    localparam [1:0] RESULT_PC4 = 2'd2;

    localparam [1:0] SIZE_BYTE = 2'd0;
    localparam [1:0] SIZE_HALF = 2'd1;
    localparam [1:0] SIZE_WORD = 2'd2;

    // ---------------------------------------------------------------------
    // IF stage
    // ---------------------------------------------------------------------
    wire [31:0] pc;
    wire [31:0] fetched_instruction;
    wire        fetch_alignment_fault;
    wire        fetch_access_fault;
    wire [31:0] fetch_next_pc;
    wire        pc_enable;

    // ---------------------------------------------------------------------
    // IF/ID pipeline register
    // ---------------------------------------------------------------------
    reg         if_id_valid;
    reg  [31:0] if_id_pc;
    reg  [31:0] if_id_instruction;
    reg         if_id_fetch_alignment_fault;
    reg         if_id_fetch_access_fault;

    // ---------------------------------------------------------------------
    // ID stage
    // ---------------------------------------------------------------------
    wire        id_instruction_legal;
    wire [3:0]  id_alu_control;
    wire [1:0]  id_alu_a_select;
    wire        id_alu_b_immediate;
    wire        id_reg_write;
    wire [1:0]  id_result_select;
    wire        id_mem_read;
    wire        id_mem_write;
    wire [1:0]  id_mem_size;
    wire        id_load_unsigned;
    wire        id_branch;
    wire [2:0]  id_branch_funct3;
    wire        id_jump;
    wire        id_jalr;
    wire        id_fence;
    wire        id_ecall;
    wire        id_ebreak;
    wire [31:0] id_immediate;

    wire [4:0]  id_rs1_addr = if_id_instruction[19:15];
    wire [4:0]  id_rs2_addr = if_id_instruction[24:20];
    wire [4:0]  id_rd_addr  = if_id_instruction[11:7];
    wire [6:0]  id_opcode   = if_id_instruction[6:0];

    wire [31:0] register_read_data1;
    wire [31:0] register_read_data2;
    wire [31:0] id_rs1_value;
    wire [31:0] id_rs2_value;
    reg         id_uses_rs1;
    reg         id_uses_rs2;

    // ---------------------------------------------------------------------
    // ID/EX pipeline register
    // ---------------------------------------------------------------------
    reg         id_ex_valid;
    reg  [31:0] id_ex_pc;
    reg  [31:0] id_ex_instruction;
    reg         id_ex_fetch_alignment_fault;
    reg         id_ex_fetch_access_fault;
    reg         id_ex_instruction_legal;
    reg  [3:0]  id_ex_alu_control;
    reg  [1:0]  id_ex_alu_a_select;
    reg         id_ex_alu_b_immediate;
    reg         id_ex_reg_write;
    reg  [1:0]  id_ex_result_select;
    reg         id_ex_mem_read;
    reg         id_ex_mem_write;
    reg  [1:0]  id_ex_mem_size;
    reg         id_ex_load_unsigned;
    reg         id_ex_branch;
    reg  [2:0]  id_ex_branch_funct3;
    reg         id_ex_jump;
    reg         id_ex_jalr;
    reg         id_ex_ecall;
    reg         id_ex_ebreak;
    reg  [31:0] id_ex_immediate;
    reg  [4:0]  id_ex_rs1_addr;
    reg  [4:0]  id_ex_rs2_addr;
    reg  [4:0]  id_ex_rd_addr;
    reg  [31:0] id_ex_rs1_value;
    reg  [31:0] id_ex_rs2_value;

    // ---------------------------------------------------------------------
    // EX/MEM pipeline register
    // ---------------------------------------------------------------------
    reg         ex_mem_valid;
    reg  [31:0] ex_mem_pc;
    reg  [31:0] ex_mem_instruction;
    reg  [4:0]  ex_mem_rd_addr;
    reg         ex_mem_reg_write;
    reg  [1:0]  ex_mem_result_select;
    reg         ex_mem_mem_read;
    reg         ex_mem_mem_write;
    reg  [1:0]  ex_mem_mem_size;
    reg         ex_mem_load_unsigned;
    reg  [31:0] ex_mem_alu_result;
    reg  [31:0] ex_mem_pc_plus_four;
    reg  [31:0] ex_mem_store_data;
    reg         ex_mem_exception;
    reg  [4:0]  ex_mem_exception_cause;
    reg  [31:0] ex_mem_exception_value;

    // ---------------------------------------------------------------------
    // MEM/WB pipeline register
    // ---------------------------------------------------------------------
    reg         mem_wb_valid;
    reg  [31:0] mem_wb_pc;
    reg  [31:0] mem_wb_instruction;
    reg  [4:0]  mem_wb_rd_addr;
    reg         mem_wb_reg_write;
    reg  [31:0] mem_wb_write_back_data;
    reg         mem_wb_exception;
    reg  [4:0]  mem_wb_exception_cause;
    reg  [31:0] mem_wb_exception_value;

    // Once an exception is detected in EX, stop admitting younger work while
    // the exception token and every older instruction drain toward WB.
    reg trap_pending;

    wire pipeline_advance = cpu_enable && !reset && !fault;
    wire wb_write_enable = mem_wb_valid && !mem_wb_exception &&
                           mem_wb_reg_write && (mem_wb_rd_addr != 5'd0);

    // ---------------------------------------------------------------------
    // ID decode and Register File
    // ---------------------------------------------------------------------
    DecoderV2 decoder (
        .instruction(if_id_instruction),
        .legal(id_instruction_legal),
        .alu_control(id_alu_control),
        .alu_a_select(id_alu_a_select),
        .alu_b_immediate(id_alu_b_immediate),
        .reg_write(id_reg_write),
        .result_select(id_result_select),
        .mem_read(id_mem_read),
        .mem_write(id_mem_write),
        .mem_size(id_mem_size),
        .load_unsigned(id_load_unsigned),
        .branch(id_branch),
        .branch_funct3(id_branch_funct3),
        .jump(id_jump),
        .jalr(id_jalr),
        .fence(id_fence),
        .ecall(id_ecall),
        .ebreak(id_ebreak)
    );

    ImmGenV2 immediate_generator (
        .instruction(if_id_instruction),
        .immediate(id_immediate)
    );

    RegisterFileV2 #(.ENABLE_DEBUG(ENABLE_RF_DEBUG)) register_file (
        .clk(clk),
        .reset(reset),
        .enable(pipeline_advance),
        .write_enable(wb_write_enable),
        .read_addr1(id_rs1_addr),
        .read_addr2(id_rs2_addr),
        .write_addr(mem_wb_rd_addr),
        .write_data(mem_wb_write_back_data),
        .debug_addr(debug_reg_addr),
        .read_data1(register_read_data1),
        .read_data2(register_read_data2),
        .debug_data(debug_reg_data)
    );

    // A Register File write and an ID read occur on the same active edge.
    // Explicit bypassing prevents ID/EX from capturing the old LUTRAM value.
    assign id_rs1_value =
        (wb_write_enable && (mem_wb_rd_addr == id_rs1_addr))
        ? mem_wb_write_back_data : register_read_data1;
    assign id_rs2_value =
        (wb_write_enable && (mem_wb_rd_addr == id_rs2_addr))
        ? mem_wb_write_back_data : register_read_data2;

    always @(*) begin
        id_uses_rs1 = 1'b0;
        id_uses_rs2 = 1'b0;
        case (id_opcode)
            7'b1100111, // JALR
            7'b0000011, // LOAD
            7'b0010011: // OP-IMM
                id_uses_rs1 = 1'b1;

            7'b0100011, // STORE
            7'b1100011, // BRANCH
            7'b0110011: begin // OP
                id_uses_rs1 = 1'b1;
                id_uses_rs2 = 1'b1;
            end
            default: ;
        endcase
    end

    // ---------------------------------------------------------------------
    // EX stage: forwarding, execute, address checks, branch resolution
    // ---------------------------------------------------------------------
    wire ex_mem_can_forward = ex_mem_valid && !ex_mem_exception &&
                              ex_mem_reg_write && !ex_mem_mem_read &&
                              (ex_mem_rd_addr != 5'd0);
    wire mem_wb_can_forward = mem_wb_valid && !mem_wb_exception &&
                              mem_wb_reg_write &&
                              (mem_wb_rd_addr != 5'd0);
    wire [31:0] ex_mem_forward_data =
        (ex_mem_result_select == RESULT_PC4)
        ? ex_mem_pc_plus_four : ex_mem_alu_result;

    reg [31:0] ex_rs1_value;
    reg [31:0] ex_rs2_value;

    always @(*) begin
        ex_rs1_value = id_ex_rs1_value;
        ex_rs2_value = id_ex_rs2_value;

        if (mem_wb_can_forward &&
            (mem_wb_rd_addr == id_ex_rs1_addr))
            ex_rs1_value = mem_wb_write_back_data;
        if (mem_wb_can_forward &&
            (mem_wb_rd_addr == id_ex_rs2_addr))
            ex_rs2_value = mem_wb_write_back_data;

        // EX/MEM contains the newer producer and therefore has priority.
        if (ex_mem_can_forward &&
            (ex_mem_rd_addr == id_ex_rs1_addr))
            ex_rs1_value = ex_mem_forward_data;
        if (ex_mem_can_forward &&
            (ex_mem_rd_addr == id_ex_rs2_addr))
            ex_rs2_value = ex_mem_forward_data;
    end

    reg  [31:0] ex_alu_operand_a;
    wire [31:0] ex_alu_operand_b;
    wire [31:0] ex_alu_result;

    always @(*) begin
        case (id_ex_alu_a_select)
            ALU_A_PC:   ex_alu_operand_a = id_ex_pc;
            ALU_A_ZERO: ex_alu_operand_a = 32'd0;
            default:    ex_alu_operand_a = ex_rs1_value;
        endcase
    end

    assign ex_alu_operand_b =
        id_ex_alu_b_immediate ? id_ex_immediate : ex_rs2_value;

    ALUV2 alu (
        .operand_a(ex_alu_operand_a),
        .operand_b(ex_alu_operand_b),
        .control(id_ex_alu_control),
        .result(ex_alu_result)
    );

    reg ex_branch_condition_true;
    always @(*) begin
        case (id_ex_branch_funct3)
            3'b000: ex_branch_condition_true = (ex_rs1_value == ex_rs2_value);
            3'b001: ex_branch_condition_true = (ex_rs1_value != ex_rs2_value);
            3'b100: ex_branch_condition_true =
                         ($signed(ex_rs1_value) < $signed(ex_rs2_value));
            3'b101: ex_branch_condition_true =
                         ($signed(ex_rs1_value) >= $signed(ex_rs2_value));
            3'b110: ex_branch_condition_true = (ex_rs1_value < ex_rs2_value);
            3'b111: ex_branch_condition_true = (ex_rs1_value >= ex_rs2_value);
            default: ex_branch_condition_true = 1'b0;
        endcase
    end

    wire [31:0] ex_pc_plus_four       = id_ex_pc + 32'd4;
    wire [31:0] ex_pc_relative_target = id_ex_pc + id_ex_immediate;
    wire [31:0] ex_jalr_sum           = ex_rs1_value + id_ex_immediate;
    wire [31:0] ex_transfer_target =
        id_ex_jalr ? {ex_jalr_sum[31:1], 1'b0} : ex_pc_relative_target;
    wire ex_control_transfer_taken =
        id_ex_valid &&
        (id_ex_jump || (id_ex_branch && ex_branch_condition_true));
    wire ex_target_alignment_fault =
        ex_control_transfer_taken && (ex_transfer_target[1:0] != 2'b00);

    wire ex_is_ram_address    = (ex_alu_result < IO_IN_ADDR);
    wire ex_is_input_address  = (ex_alu_result == IO_IN_ADDR);
    wire ex_is_output_address = (ex_alu_result == IO_OUT_ADDR);
    wire ex_valid_load_address =
        ex_is_ram_address ||
        ((ex_is_input_address || ex_is_output_address) &&
         (id_ex_mem_size == SIZE_WORD));
    wire ex_valid_store_address =
        ex_is_ram_address ||
        (ex_is_output_address && (id_ex_mem_size == SIZE_WORD));
    wire ex_data_alignment_fault =
        ((id_ex_mem_size == SIZE_HALF) && ex_alu_result[0]) ||
        ((id_ex_mem_size == SIZE_WORD) &&
         (ex_alu_result[1:0] != 2'b00));
    wire ex_load_access_fault =
        id_ex_mem_read && !ex_valid_load_address;
    wire ex_store_access_fault =
        id_ex_mem_write && !ex_valid_store_address;
    wire [4:0] ex_byte_shift = {ex_alu_result[1:0], 3'b000};
    wire [31:0] ex_store_write_data = ex_rs2_value << ex_byte_shift;

    reg        ex_exception;
    reg [4:0]  ex_exception_cause;
    reg [31:0] ex_exception_value;

    always @(*) begin
        ex_exception       = 1'b0;
        ex_exception_cause = 5'd0;
        ex_exception_value = 32'd0;

        if (id_ex_valid) begin
            if (id_ex_fetch_alignment_fault) begin
                ex_exception       = 1'b1;
                ex_exception_cause = CAUSE_INST_ADDR_MISALIGNED;
                ex_exception_value = id_ex_pc;
            end else if (id_ex_fetch_access_fault) begin
                ex_exception       = 1'b1;
                ex_exception_cause = CAUSE_INST_ACCESS_FAULT;
                ex_exception_value = id_ex_pc;
            end else if (!id_ex_instruction_legal) begin
                ex_exception       = 1'b1;
                ex_exception_cause = CAUSE_ILLEGAL_INSTRUCTION;
                ex_exception_value = id_ex_instruction;
            end else if (id_ex_ebreak) begin
                ex_exception       = 1'b1;
                ex_exception_cause = CAUSE_BREAKPOINT;
                ex_exception_value = id_ex_pc;
            end else if (id_ex_mem_read &&
                         ex_data_alignment_fault) begin
                ex_exception       = 1'b1;
                ex_exception_cause = CAUSE_LOAD_ADDR_MISALIGNED;
                ex_exception_value = ex_alu_result;
            end else if (ex_load_access_fault) begin
                ex_exception       = 1'b1;
                ex_exception_cause = CAUSE_LOAD_ACCESS_FAULT;
                ex_exception_value = ex_alu_result;
            end else if (id_ex_mem_write &&
                         ex_data_alignment_fault) begin
                ex_exception       = 1'b1;
                ex_exception_cause = CAUSE_STORE_ADDR_MISALIGNED;
                ex_exception_value = ex_alu_result;
            end else if (ex_store_access_fault) begin
                ex_exception       = 1'b1;
                ex_exception_cause = CAUSE_STORE_ACCESS_FAULT;
                ex_exception_value = ex_alu_result;
            end else if (id_ex_ecall) begin
                ex_exception       = 1'b1;
                ex_exception_cause = CAUSE_ECALL_FROM_M_MODE;
                ex_exception_value = 32'd0;
            end else if (ex_target_alignment_fault) begin
                ex_exception       = 1'b1;
                ex_exception_cause = CAUSE_INST_ADDR_MISALIGNED;
                ex_exception_value = ex_transfer_target;
            end
        end
    end

    wire ex_redirect = ex_control_transfer_taken && !ex_exception;

    // With asynchronous data memory, the load value is available in MEM.
    // Keeping the classic one-bubble rule avoids a MEM-to-EX critical path.
    wire load_use_stall =
        if_id_valid && id_ex_valid && id_ex_mem_read &&
        (id_ex_rd_addr != 5'd0) &&
        ((id_uses_rs1 && (id_rs1_addr == id_ex_rd_addr)) ||
         (id_uses_rs2 && (id_rs2_addr == id_ex_rd_addr)));

    // ---------------------------------------------------------------------
    // MEM stage
    // ---------------------------------------------------------------------
    wire mem_is_ram_address    = (ex_mem_alu_result < IO_IN_ADDR);
    wire mem_is_input_address  = (ex_mem_alu_result == IO_IN_ADDR);
    wire mem_is_output_address = (ex_mem_alu_result == IO_OUT_ADDR);

    wire [31:0] ram_read_word;
    wire [31:0] memory_read_word =
        mem_is_input_address  ? {24'd0, input_port} :
        mem_is_output_address ? {24'd0, output_port} :
        mem_is_ram_address    ? ram_read_word :
                                32'd0;
    wire [4:0] mem_byte_shift = {ex_mem_alu_result[1:0], 3'b000};
    wire [31:0] shifted_load_word = memory_read_word >> mem_byte_shift;

    reg [31:0] mem_load_data;
    always @(*) begin
        case (ex_mem_mem_size)
            SIZE_BYTE: begin
                if (ex_mem_load_unsigned)
                    mem_load_data = {24'd0, shifted_load_word[7:0]};
                else
                    mem_load_data =
                        {{24{shifted_load_word[7]}},
                         shifted_load_word[7:0]};
            end
            SIZE_HALF: begin
                if (ex_mem_load_unsigned)
                    mem_load_data = {16'd0, shifted_load_word[15:0]};
                else
                    mem_load_data =
                        {{16{shifted_load_word[15]}},
                         shifted_load_word[15:0]};
            end
            default:
                mem_load_data = shifted_load_word;
        endcase
    end

    reg [3:0] mem_store_strobe_raw;
    always @(*) begin
        case (ex_mem_mem_size)
            SIZE_BYTE:
                mem_store_strobe_raw =
                    4'b0001 << ex_mem_alu_result[1:0];
            SIZE_HALF:
                mem_store_strobe_raw =
                    4'b0011 << ex_mem_alu_result[1:0];
            SIZE_WORD:
                mem_store_strobe_raw = 4'b1111;
            default:
                mem_store_strobe_raw = 4'b0000;
        endcase
    end

    reg [31:0] mem_stage_write_back_data;
    always @(*) begin
        case (ex_mem_result_select)
            RESULT_MEM:
                mem_stage_write_back_data = mem_load_data;
            RESULT_PC4:
                mem_stage_write_back_data = ex_mem_pc_plus_four;
            default:
                mem_stage_write_back_data = ex_mem_alu_result;
        endcase
    end

    wire [3:0] ram_write_strobe =
        (pipeline_advance && ex_mem_valid && !ex_mem_exception &&
         ex_mem_mem_write && mem_is_ram_address)
        ? mem_store_strobe_raw : 4'b0000;

    DataMemoryV2 #(.ENABLE_DEBUG(ENABLE_MEM_DEBUG)) data_memory (
        .clk(clk),
        .enable(pipeline_advance),
        .write_strobe(ram_write_strobe),
        .address(ex_mem_alu_result),
        .write_data(ex_mem_store_data),
        .read_data(ram_read_word),
        .debug_word0(debug_mem_word0)
    );

    always @(posedge clk or posedge reset) begin
        if (reset)
            output_port <= 8'd0;
        else if (pipeline_advance && ex_mem_valid &&
                 !ex_mem_exception && ex_mem_mem_write &&
                 mem_is_output_address)
            output_port <= ex_mem_store_data[7:0];
    end

    // ---------------------------------------------------------------------
    // PC and pipeline control
    // ---------------------------------------------------------------------
    assign fetch_alignment_fault = (pc[1:0] != 2'b00);
    assign fetch_access_fault    = (pc >= IMEM_BYTES);
    assign fetch_next_pc = ex_redirect ? ex_transfer_target
                                       : (pc + 32'd4);

    // On a load-use hazard the PC and IF/ID register hold while ID/EX gets a
    // bubble. On exception detection, or while draining a pending exception,
    // no younger instruction is fetched. A valid redirect advances the PC.
    assign pc_enable = pipeline_advance && !trap_pending &&
                       !ex_exception && !load_use_stall;

    ProgramCounterV2 program_counter (
        .clk(clk),
        .reset(reset),
        .enable(pc_enable),
        .next_pc(fetch_next_pc),
        .pc(pc)
    );

    InstructionMemoryV2 #(
        .WORDS(IMEM_WORDS),
        .INIT_DEMO(INIT_DEMO),
        .INIT_FILE(IMEM_INIT_FILE)
    ) instruction_memory (
        .address(pc),
        .instruction(fetched_instruction)
    );

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            trap_pending <= 1'b0;
        end else if (pipeline_advance && ex_exception) begin
            trap_pending <= 1'b1;
        end
    end

    // IF/ID: hold on load-use, flush on an older redirect/exception.
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            if_id_valid                 <= 1'b0;
            if_id_pc                    <= 32'd0;
            if_id_instruction           <= 32'h0000_0013;
            if_id_fetch_alignment_fault <= 1'b0;
            if_id_fetch_access_fault    <= 1'b0;
        end else if (pipeline_advance) begin
            if (ex_exception || ex_redirect || trap_pending) begin
                if_id_valid <= 1'b0;
            end else if (!load_use_stall) begin
                if_id_valid                 <= 1'b1;
                if_id_pc                    <= pc;
                if_id_instruction           <= fetched_instruction;
                if_id_fetch_alignment_fault <= fetch_alignment_fault;
                if_id_fetch_access_fault    <= fetch_access_fault;
            end
        end
    end

    // ID/EX: insert a bubble for stalls and flushes.
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            id_ex_valid                 <= 1'b0;
            id_ex_pc                    <= 32'd0;
            id_ex_instruction           <= 32'h0000_0013;
            id_ex_fetch_alignment_fault <= 1'b0;
            id_ex_fetch_access_fault    <= 1'b0;
            id_ex_instruction_legal     <= 1'b1;
            id_ex_alu_control           <= 4'd0;
            id_ex_alu_a_select          <= ALU_A_RS1;
            id_ex_alu_b_immediate       <= 1'b0;
            id_ex_reg_write             <= 1'b0;
            id_ex_result_select         <= RESULT_ALU;
            id_ex_mem_read              <= 1'b0;
            id_ex_mem_write             <= 1'b0;
            id_ex_mem_size              <= SIZE_WORD;
            id_ex_load_unsigned         <= 1'b0;
            id_ex_branch                <= 1'b0;
            id_ex_branch_funct3         <= 3'd0;
            id_ex_jump                  <= 1'b0;
            id_ex_jalr                  <= 1'b0;
            id_ex_ecall                 <= 1'b0;
            id_ex_ebreak                <= 1'b0;
            id_ex_immediate             <= 32'd0;
            id_ex_rs1_addr              <= 5'd0;
            id_ex_rs2_addr              <= 5'd0;
            id_ex_rd_addr               <= 5'd0;
            id_ex_rs1_value             <= 32'd0;
            id_ex_rs2_value             <= 32'd0;
        end else if (pipeline_advance) begin
            if (ex_exception || ex_redirect || trap_pending ||
                load_use_stall) begin
                id_ex_valid <= 1'b0;
            end else begin
                id_ex_valid                 <= if_id_valid;
                id_ex_pc                    <= if_id_pc;
                id_ex_instruction           <= if_id_instruction;
                id_ex_fetch_alignment_fault <=
                    if_id_fetch_alignment_fault;
                id_ex_fetch_access_fault    <=
                    if_id_fetch_access_fault;
                id_ex_instruction_legal     <= id_instruction_legal;
                id_ex_alu_control           <= id_alu_control;
                id_ex_alu_a_select          <= id_alu_a_select;
                id_ex_alu_b_immediate       <= id_alu_b_immediate;
                id_ex_reg_write             <= id_reg_write;
                id_ex_result_select         <= id_result_select;
                id_ex_mem_read              <= id_mem_read;
                id_ex_mem_write             <= id_mem_write;
                id_ex_mem_size              <= id_mem_size;
                id_ex_load_unsigned         <= id_load_unsigned;
                id_ex_branch                <= id_branch;
                id_ex_branch_funct3         <= id_branch_funct3;
                id_ex_jump                  <= id_jump;
                id_ex_jalr                  <= id_jalr;
                id_ex_ecall                 <= id_ecall;
                id_ex_ebreak                <= id_ebreak;
                id_ex_immediate             <= id_immediate;
                id_ex_rs1_addr              <= id_rs1_addr;
                id_ex_rs2_addr              <= id_rs2_addr;
                id_ex_rd_addr               <= id_rd_addr;
                id_ex_rs1_value             <= id_rs1_value;
                id_ex_rs2_value             <= id_rs2_value;
            end
        end
    end

    // EX/MEM always advances while the backend is draining. Exception
    // controls remain attached to the faulting instruction and suppress only
    // that instruction's side effects.
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            ex_mem_valid             <= 1'b0;
            ex_mem_pc                <= 32'd0;
            ex_mem_instruction       <= 32'h0000_0013;
            ex_mem_rd_addr           <= 5'd0;
            ex_mem_reg_write         <= 1'b0;
            ex_mem_result_select     <= RESULT_ALU;
            ex_mem_mem_read          <= 1'b0;
            ex_mem_mem_write         <= 1'b0;
            ex_mem_mem_size          <= SIZE_WORD;
            ex_mem_load_unsigned     <= 1'b0;
            ex_mem_alu_result        <= 32'd0;
            ex_mem_pc_plus_four      <= 32'd0;
            ex_mem_store_data        <= 32'd0;
            ex_mem_exception         <= 1'b0;
            ex_mem_exception_cause   <= 5'd0;
            ex_mem_exception_value   <= 32'd0;
        end else if (pipeline_advance) begin
            ex_mem_valid             <= id_ex_valid;
            ex_mem_pc                <= id_ex_pc;
            ex_mem_instruction       <= id_ex_instruction;
            ex_mem_rd_addr           <= id_ex_rd_addr;
            ex_mem_reg_write         <= id_ex_reg_write;
            ex_mem_result_select     <= id_ex_result_select;
            ex_mem_mem_read          <= id_ex_mem_read;
            ex_mem_mem_write         <= id_ex_mem_write;
            ex_mem_mem_size          <= id_ex_mem_size;
            ex_mem_load_unsigned     <= id_ex_load_unsigned;
            ex_mem_alu_result        <= ex_alu_result;
            ex_mem_pc_plus_four      <= ex_pc_plus_four;
            ex_mem_store_data        <= ex_store_write_data;
            ex_mem_exception         <= ex_exception;
            ex_mem_exception_cause   <= ex_exception_cause;
            ex_mem_exception_value   <= ex_exception_value;
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            mem_wb_valid             <= 1'b0;
            mem_wb_pc                <= 32'd0;
            mem_wb_instruction       <= 32'h0000_0013;
            mem_wb_rd_addr           <= 5'd0;
            mem_wb_reg_write         <= 1'b0;
            mem_wb_write_back_data   <= 32'd0;
            mem_wb_exception         <= 1'b0;
            mem_wb_exception_cause   <= 5'd0;
            mem_wb_exception_value   <= 32'd0;
        end else if (pipeline_advance) begin
            mem_wb_valid             <= ex_mem_valid;
            mem_wb_pc                <= ex_mem_pc;
            mem_wb_instruction       <= ex_mem_instruction;
            mem_wb_rd_addr           <= ex_mem_rd_addr;
            mem_wb_reg_write         <= ex_mem_reg_write;
            mem_wb_write_back_data   <= mem_stage_write_back_data;
            mem_wb_exception         <= ex_mem_exception;
            mem_wb_exception_cause   <= ex_mem_exception_cause;
            mem_wb_exception_value   <= ex_mem_exception_value;
        end
    end

    // ---------------------------------------------------------------------
    // Retirement, sticky fault, and debug view
    // ---------------------------------------------------------------------
    assign fault = mem_wb_valid && mem_wb_exception;

    assign retire_valid = pipeline_advance && mem_wb_valid &&
                          !mem_wb_exception;
    assign retire_pc = mem_wb_pc;
    assign retire_instruction = mem_wb_instruction;

    always @(*) begin
        debug_trap_cause = 5'd0;
        debug_trap_value = 32'd0;
        if (fault) begin
            debug_trap_cause = mem_wb_exception_cause;
            debug_trap_value = mem_wb_exception_value;
        end
    end

    // Present the oldest live token. During a fault this is naturally the
    // WB exception token, so PC/instruction/cause/value remain coherent.
    assign debug_pc =
        mem_wb_valid ? mem_wb_pc :
        ex_mem_valid ? ex_mem_pc :
        id_ex_valid  ? id_ex_pc :
        if_id_valid  ? if_id_pc :
                       pc;
    assign debug_instruction =
        mem_wb_valid ? mem_wb_instruction :
        ex_mem_valid ? ex_mem_instruction :
        id_ex_valid  ? id_ex_instruction :
        if_id_valid  ? if_id_instruction :
                       fetched_instruction;

    // Referencing FENCE documents that its decoded operation deliberately
    // retires as a no-op in this single-hart, cacheless implementation.
    wire unused_fence = id_fence;
endmodule

`default_nettype wire
