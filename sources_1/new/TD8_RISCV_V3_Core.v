`timescale 1ns/1ps
`default_nettype none

// TD8-derived five-stage RV32I core with latency-safe memory interfaces.
//
// Pipeline: IF -> ID -> EX -> MEM -> WB.
//
// Unlike TD8_RISCV_V2_Core, both memories use explicit request/response
// interfaces.  Each master permits at most one outstanding request, holds a
// request and all of its payload stable until ready, and buffers a response
// that arrives while cpu_enable is low.  A data-memory operation freezes every
// pipeline register, including WB, until its completion response is present.
// The request-issued state prevents STORE/MMIO side effects from repeating
// during that freeze.
//
// The data master is intentionally a generic 32-bit byte-strobe bus.  A SoC
// may decode it to BRAM, timer/input MMIO, tile VRAM, or sprite registers.
module TD8_RISCV_V3_Core #(
    parameter [31:0] RESET_PC = 32'h0000_0000,
    parameter integer ENABLE_RF_DEBUG = 0
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        cpu_enable,

    // Instruction request/response master.  Responses are in order and a
    // response must not be returned in the same cycle as its request fire.
    output wire        imem_req_valid,
    input  wire        imem_req_ready,
    output wire [31:0] imem_req_address,
    input  wire        imem_rsp_valid,
    input  wire [31:0] imem_rsp_data,
    input  wire        imem_rsp_error,

    // Data/RAM/MMIO request/response master.
    output wire        dmem_req_valid,
    input  wire        dmem_req_ready,
    output wire [31:0] dmem_req_address,
    output wire        dmem_req_write,
    output wire [3:0]  dmem_req_write_strobe,
    output wire [31:0] dmem_req_write_data,
    input  wire        dmem_rsp_valid,
    input  wire [31:0] dmem_rsp_read_data,
    input  wire        dmem_rsp_error,

    input  wire [4:0]  debug_reg_addr,
    output wire [31:0] debug_pc,
    output wire [31:0] debug_instruction,
    output wire [31:0] debug_reg_data,
    output reg  [4:0]  debug_trap_cause,
    output reg  [31:0] debug_trap_value,
    output wire        fault,
    output wire        pipeline_stalled,

    output wire        retire_valid,
    output wire [31:0] retire_pc,
    output wire [31:0] retire_instruction,

    output reg  [31:0] cycle_count,
    output reg  [31:0] instret_count,
    output reg  [31:0] stall_count,
    output reg  [31:0] flush_count
);
    localparam [4:0] CAUSE_INST_ADDR_MISALIGNED = 5'd0;
    localparam [4:0] CAUSE_INST_ACCESS_FAULT     = 5'd1;
    localparam [4:0] CAUSE_ILLEGAL_INSTRUCTION   = 5'd2;
    localparam [4:0] CAUSE_BREAKPOINT            = 5'd3;
    localparam [4:0] CAUSE_LOAD_ADDR_MISALIGNED  = 5'd4;
    localparam [4:0] CAUSE_LOAD_ACCESS_FAULT     = 5'd5;
    localparam [4:0] CAUSE_STORE_ADDR_MISALIGNED = 5'd6;
    localparam [4:0] CAUSE_STORE_ACCESS_FAULT    = 5'd7;
    localparam [4:0] CAUSE_ECALL_FROM_M_MODE     = 5'd11;

    localparam [1:0] ALU_A_RS1  = 2'd0;
    localparam [1:0] ALU_A_PC   = 2'd1;
    localparam [1:0] ALU_A_ZERO = 2'd2;

    localparam [1:0] RESULT_ALU = 2'd0;
    localparam [1:0] RESULT_MEM = 2'd1;
    localparam [1:0] RESULT_PC4 = 2'd2;

    localparam [1:0] SIZE_BYTE = 2'd0;
    localparam [1:0] SIZE_HALF = 2'd1;
    localparam [1:0] SIZE_WORD = 2'd2;

    localparam [31:0] NOP = 32'h0000_0013;

    // ------------------------------------------------------------------
    // Instruction request and one-entry response buffer
    // ------------------------------------------------------------------
    reg  [31:0] fetch_address;
    reg         imem_request_active;
    reg  [31:0] imem_request_address_reg;
    reg         imem_outstanding;
    reg  [31:0] imem_outstanding_pc;
    reg         fetch_buffer_valid;
    reg  [31:0] fetch_buffer_pc;
    reg  [31:0] fetch_buffer_instruction;
    reg         fetch_buffer_error;

    assign imem_req_valid   = imem_request_active;
    assign imem_req_address = imem_request_address_reg;

    wire imem_request_fire = imem_request_active && imem_req_ready;
    wire fetch_direct_valid = imem_outstanding && imem_rsp_valid;
    wire fetch_available = fetch_buffer_valid || fetch_direct_valid;
    wire [31:0] fetched_pc = fetch_buffer_valid
                           ? fetch_buffer_pc : imem_outstanding_pc;
    wire [31:0] fetched_instruction = fetch_buffer_valid
                                    ? fetch_buffer_instruction
                                    : imem_rsp_data;
    wire fetched_access_error = fetch_buffer_valid
                              ? fetch_buffer_error : imem_rsp_error;
    wire fetched_alignment_error = (fetched_pc[1:0] != 2'b00);

    // ------------------------------------------------------------------
    // IF/ID pipeline register
    // ------------------------------------------------------------------
    reg         if_id_valid;
    reg  [31:0] if_id_pc;
    reg  [31:0] if_id_instruction;
    reg         if_id_fetch_alignment_fault;
    reg         if_id_fetch_access_fault;

    // ------------------------------------------------------------------
    // ID stage
    // ------------------------------------------------------------------
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

    wire [4:0] id_rs1_addr = if_id_instruction[19:15];
    wire [4:0] id_rs2_addr = if_id_instruction[24:20];
    wire [4:0] id_rd_addr  = if_id_instruction[11:7];
    wire [6:0] id_opcode   = if_id_instruction[6:0];

    wire [31:0] register_read_data1;
    wire [31:0] register_read_data2;
    wire [31:0] id_rs1_value;
    wire [31:0] id_rs2_value;
    reg         id_uses_rs1;
    reg         id_uses_rs2;

    // ------------------------------------------------------------------
    // ID/EX pipeline register
    // ------------------------------------------------------------------
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

    // ------------------------------------------------------------------
    // EX/MEM pipeline register
    // ------------------------------------------------------------------
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
    reg  [3:0]  ex_mem_store_strobe;
    reg         ex_mem_exception;
    reg  [4:0]  ex_mem_exception_cause;
    reg  [31:0] ex_mem_exception_value;

    // ------------------------------------------------------------------
    // MEM/WB pipeline register
    // ------------------------------------------------------------------
    reg         mem_wb_valid;
    reg  [31:0] mem_wb_pc;
    reg  [31:0] mem_wb_instruction;
    reg  [4:0]  mem_wb_rd_addr;
    reg         mem_wb_reg_write;
    reg  [31:0] mem_wb_write_back_data;
    reg         mem_wb_exception;
    reg  [4:0]  mem_wb_exception_cause;
    reg  [31:0] mem_wb_exception_value;

    // Once a synchronous exception is accepted into the pipeline, stop all
    // younger fetches while the in-order exception token drains to WB.
    reg trap_pending;

    // These control wires are defined after the EX/MEM combinational logic.
    wire pipeline_step;
    wire wb_write_enable;

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
        .enable(pipeline_step),
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

    // ------------------------------------------------------------------
    // EX stage: forwarding, ALU, branches, and synchronous exceptions
    // ------------------------------------------------------------------
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

        // EX/MEM is the newer producer and has priority.
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
            3'b000: ex_branch_condition_true =
                         (ex_rs1_value == ex_rs2_value);
            3'b001: ex_branch_condition_true =
                         (ex_rs1_value != ex_rs2_value);
            3'b100: ex_branch_condition_true =
                         ($signed(ex_rs1_value) < $signed(ex_rs2_value));
            3'b101: ex_branch_condition_true =
                         ($signed(ex_rs1_value) >= $signed(ex_rs2_value));
            3'b110: ex_branch_condition_true =
                         (ex_rs1_value < ex_rs2_value);
            3'b111: ex_branch_condition_true =
                         (ex_rs1_value >= ex_rs2_value);
            default: ex_branch_condition_true = 1'b0;
        endcase
    end

    wire [31:0] ex_pc_plus_four       = id_ex_pc + 32'd4;
    wire [31:0] ex_pc_relative_target = id_ex_pc + id_ex_immediate;
    wire [31:0] ex_jalr_sum           = ex_rs1_value + id_ex_immediate;
    // Alignment only depends on the low address bits.  Keeping these checks
    // independent of the full 32-bit ALU/adders avoids putting forwarding,
    // the complete arithmetic result, and pipeline flush control on one
    // timing path.  For JALR bit zero is cleared by definition, so only bit
    // one of the unmasked sum can make the RV32I target misaligned.
    wire [1:0] ex_pc_relative_target_low =
        id_ex_pc[1:0] + id_ex_immediate[1:0];
    wire [1:0] ex_jalr_sum_low =
        ex_rs1_value[1:0] + id_ex_immediate[1:0];
    wire [31:0] ex_transfer_target = id_ex_jalr
                                  ? {ex_jalr_sum[31:1], 1'b0}
                                  : ex_pc_relative_target;
    wire ex_control_transfer_taken = id_ex_valid &&
        (id_ex_jump || (id_ex_branch && ex_branch_condition_true));
    wire ex_target_alignment_fault = ex_control_transfer_taken &&
        (id_ex_jalr ? ex_jalr_sum_low[1]
                    : (ex_pc_relative_target_low != 2'b00));

    // LOAD/STORE effective addresses are always rs1 + immediate.  Use a
    // dedicated two-bit sum for alignment and byte-lane selection rather
    // than routing the full ALU result back into pipeline control.
    wire [1:0] ex_data_address_low =
        ex_rs1_value[1:0] + id_ex_immediate[1:0];
    wire ex_data_alignment_fault =
        ((id_ex_mem_size == SIZE_HALF) && ex_data_address_low[0]) ||
        ((id_ex_mem_size == SIZE_WORD) &&
         (ex_data_address_low != 2'b00));

    wire [4:0] ex_byte_shift = {ex_data_address_low, 3'b000};
    wire [31:0] ex_store_write_data = ex_rs2_value << ex_byte_shift;
    reg  [3:0] ex_store_write_strobe;
    always @(*) begin
        case (id_ex_mem_size)
            SIZE_BYTE:
                ex_store_write_strobe = 4'b0001 << ex_data_address_low;
            SIZE_HALF:
                ex_store_write_strobe = 4'b0011 << ex_data_address_low;
            SIZE_WORD:
                ex_store_write_strobe = 4'b1111;
            default:
                ex_store_write_strobe = 4'b0000;
        endcase
    end

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
            end else if (id_ex_mem_read && ex_data_alignment_fault) begin
                ex_exception       = 1'b1;
                ex_exception_cause = CAUSE_LOAD_ADDR_MISALIGNED;
                ex_exception_value = ex_alu_result;
            end else if (id_ex_mem_write && ex_data_alignment_fault) begin
                ex_exception       = 1'b1;
                ex_exception_cause = CAUSE_STORE_ADDR_MISALIGNED;
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

    wire load_use_stall =
        if_id_valid && id_ex_valid && id_ex_mem_read &&
        (id_ex_rd_addr != 5'd0) &&
        ((id_uses_rs1 && (id_rs1_addr == id_ex_rd_addr)) ||
         (id_uses_rs2 && (id_rs2_addr == id_ex_rd_addr)));

    // ------------------------------------------------------------------
    // Data request and one-entry response buffer
    // ------------------------------------------------------------------
    reg         dmem_request_active;
    reg  [31:0] dmem_request_address_reg;
    reg         dmem_request_write_reg;
    reg  [3:0]  dmem_request_strobe_reg;
    reg  [31:0] dmem_request_write_data_reg;
    reg         dmem_outstanding;
    reg         dmem_response_buffer_valid;
    reg  [31:0] dmem_response_buffer_data;
    reg         dmem_response_buffer_error;

    assign dmem_req_valid        = dmem_request_active;
    assign dmem_req_address      = dmem_request_address_reg;
    assign dmem_req_write        = dmem_request_write_reg;
    assign dmem_req_write_strobe = dmem_request_strobe_reg;
    assign dmem_req_write_data   = dmem_request_write_data_reg;

    wire dmem_request_fire = dmem_request_active && dmem_req_ready;
    wire mem_bus_operation = ex_mem_valid && !ex_mem_exception &&
                             (ex_mem_mem_read || ex_mem_mem_write);
    wire dmem_direct_response_valid = dmem_outstanding && dmem_rsp_valid;
    wire dmem_response_available = dmem_response_buffer_valid ||
                                   dmem_direct_response_valid;
    wire [31:0] dmem_response_data = dmem_response_buffer_valid
                                   ? dmem_response_buffer_data
                                   : dmem_rsp_read_data;
    wire dmem_response_has_error = dmem_response_buffer_valid
                                 ? dmem_response_buffer_error
                                 : dmem_rsp_error;

    wire data_stage_ready = !mem_bus_operation || dmem_response_available;
    wire mem_response_exception = mem_bus_operation &&
                                  dmem_response_available &&
                                  dmem_response_has_error;
    wire [4:0] mem_response_exception_cause = ex_mem_mem_write
        ? CAUSE_STORE_ACCESS_FAULT : CAUSE_LOAD_ACCESS_FAULT;

    // All stages, including an occupied WB stage, hold for a data response.
    // A normal front-end step additionally requires an instruction response;
    // trap draining no longer fetches and therefore does not require one.
    assign pipeline_step = cpu_enable && !fault && data_stage_ready &&
                           (fetch_available || trap_pending);
    assign pipeline_stalled = cpu_enable && !fault && !pipeline_step;

    assign wb_write_enable = pipeline_step && mem_wb_valid &&
                             !mem_wb_exception && mem_wb_reg_write &&
                             (mem_wb_rd_addr != 5'd0);

    wire dmem_response_consumed = pipeline_step && mem_bus_operation &&
                                  dmem_response_available;

    // ------------------------------------------------------------------
    // MEM load formatting and WB selection
    // ------------------------------------------------------------------
    wire [4:0] mem_byte_shift =
        {ex_mem_alu_result[1:0], 3'b000};
    wire [31:0] shifted_load_word =
        dmem_response_data >> mem_byte_shift;

    reg [31:0] mem_load_data;
    always @(*) begin
        case (ex_mem_mem_size)
            SIZE_BYTE: begin
                if (ex_mem_load_unsigned)
                    mem_load_data = {24'd0, shifted_load_word[7:0]};
                else
                    mem_load_data = {{24{shifted_load_word[7]}},
                                     shifted_load_word[7:0]};
            end
            SIZE_HALF: begin
                if (ex_mem_load_unsigned)
                    mem_load_data = {16'd0, shifted_load_word[15:0]};
                else
                    mem_load_data = {{16{shifted_load_word[15]}},
                                     shifted_load_word[15:0]};
            end
            default:
                mem_load_data = shifted_load_word;
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

    // ------------------------------------------------------------------
    // Request/response state.  Valid payloads are registered, so neither
    // cpu_enable nor a pipeline hold can withdraw an unaccepted request.
    // ------------------------------------------------------------------
    wire pipeline_flush_event = pipeline_step &&
        (mem_response_exception || ex_exception || ex_redirect);
    wire fetch_drop = pipeline_step && fetch_available &&
        (mem_response_exception || ex_exception || ex_redirect ||
         trap_pending);
    wire fetch_consume = pipeline_step && fetch_available &&
        !mem_response_exception && !ex_exception && !ex_redirect &&
        !trap_pending && !load_use_stall;

    // These registers directly drive the instruction BRAM request port.  Use
    // a synchronous reset so no asynchronously-reset address/control flop is
    // connected to a BRAM input (Vivado REQP-1839).
    always @(posedge clk) begin
        if (reset) begin
            fetch_address             <= RESET_PC;
            imem_request_active       <= 1'b0;
            imem_request_address_reg  <= RESET_PC;
            imem_outstanding          <= 1'b0;
            imem_outstanding_pc       <= RESET_PC;
            fetch_buffer_valid        <= 1'b0;
            fetch_buffer_pc           <= RESET_PC;
            fetch_buffer_instruction  <= NOP;
            fetch_buffer_error        <= 1'b0;
        end else begin
            if (imem_request_fire) begin
                imem_request_active <= 1'b0;
                imem_outstanding    <= 1'b1;
                imem_outstanding_pc <= imem_request_address_reg;
            end

            if (fetch_direct_valid) begin
                imem_outstanding <= 1'b0;
                // Payload capture is unconditional.  When this response is
                // consumed or killed in the same cycle, the valid assignment
                // below wins and the payload is architecturally invisible.
                // This keeps branch/exception control off the wide payload
                // register clock-enables.
                fetch_buffer_valid       <= 1'b1;
                fetch_buffer_pc          <= imem_outstanding_pc;
                fetch_buffer_instruction <= imem_rsp_data;
                fetch_buffer_error       <= imem_rsp_error;
            end

            if (fetch_consume || fetch_drop)
                fetch_buffer_valid <= 1'b0;

            if (pipeline_step) begin
                if (mem_response_exception || ex_exception) begin
                    // The trap path does not fetch again before reset.
                    fetch_address <= fetch_address;
                end else if (ex_redirect) begin
                    fetch_address <= ex_transfer_target;
                end else if (!trap_pending && !load_use_stall &&
                             fetch_available) begin
                    fetch_address <= fetched_pc + 32'd4;
                end
            end

            if (!imem_request_active && !imem_outstanding &&
                !fetch_buffer_valid && !fetch_direct_valid &&
                cpu_enable && !fault && !trap_pending &&
                !pipeline_flush_event) begin
                imem_request_active      <= 1'b1;
                imem_request_address_reg <= fetch_address;
            end
        end
    end

    // The data-BRAM address, byte enables, and request-valid state reset on a
    // clock edge together.  The memory slave observes reset on that same edge
    // and suppresses any write, avoiding an asynchronous address transition
    // while a BRAM write port could still be enabled (Vivado REQP-1839).
    always @(posedge clk) begin
        if (reset) begin
            dmem_request_active         <= 1'b0;
            dmem_request_address_reg    <= 32'd0;
            dmem_request_write_reg      <= 1'b0;
            dmem_request_strobe_reg     <= 4'd0;
            dmem_request_write_data_reg <= 32'd0;
            dmem_outstanding            <= 1'b0;
            dmem_response_buffer_valid  <= 1'b0;
            dmem_response_buffer_data   <= 32'd0;
            dmem_response_buffer_error  <= 1'b0;
        end else begin
            if (dmem_request_fire) begin
                dmem_request_active <= 1'b0;
                dmem_outstanding    <= 1'b1;
            end

            if (dmem_direct_response_valid) begin
                dmem_outstanding <= 1'b0;
                if (!dmem_response_consumed) begin
                    dmem_response_buffer_valid <= 1'b1;
                    dmem_response_buffer_data  <= dmem_rsp_read_data;
                    dmem_response_buffer_error <= dmem_rsp_error;
                end
            end

            if (dmem_response_consumed) begin
                dmem_outstanding           <= 1'b0;
                dmem_response_buffer_valid <= 1'b0;
            end

            if (mem_bus_operation && !dmem_request_active &&
                !dmem_outstanding && !dmem_response_buffer_valid &&
                !dmem_direct_response_valid && cpu_enable && !fault) begin
                dmem_request_active         <= 1'b1;
                dmem_request_address_reg    <= ex_mem_alu_result;
                dmem_request_write_reg      <= ex_mem_mem_write;
                dmem_request_strobe_reg     <= ex_mem_mem_write
                                             ? ex_mem_store_strobe : 4'b0000;
                dmem_request_write_data_reg <= ex_mem_store_data;
            end
        end
    end

    // ------------------------------------------------------------------
    // Trap state and pipeline registers
    // ------------------------------------------------------------------
    always @(posedge clk or posedge reset) begin
        if (reset)
            trap_pending <= 1'b0;
        else if (pipeline_step &&
                 (mem_response_exception || ex_exception))
            trap_pending <= 1'b1;
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            if_id_valid                 <= 1'b0;
            if_id_pc                    <= RESET_PC;
            if_id_instruction           <= NOP;
            if_id_fetch_alignment_fault <= 1'b0;
            if_id_fetch_access_fault    <= 1'b0;
        end else if (pipeline_step) begin
            // As with the other pipeline stages, flushed payload contents do
            // not matter once valid is cleared.  Only a load-use stall must
            // retain the current IF/ID payload.
            if (!load_use_stall) begin
                if_id_pc                    <= fetched_pc;
                if_id_instruction           <= fetched_instruction;
                if_id_fetch_alignment_fault <= fetched_alignment_error;
                if_id_fetch_access_fault    <= fetched_access_error;
            end

            if (mem_response_exception || ex_exception || ex_redirect ||
                trap_pending) begin
                if_id_valid <= 1'b0;
            end else if (!load_use_stall) begin
                if_id_valid <= fetch_available;
            end
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            id_ex_valid                 <= 1'b0;
            id_ex_pc                    <= RESET_PC;
            id_ex_instruction           <= NOP;
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
        end else if (pipeline_step) begin
            // Bubble/flush state is carried exclusively by id_ex_valid.
            // Updating the payload unconditionally removes the current EX
            // exception/redirect result from hundreds of payload-register
            // clock enables, shortening the dominant feedback timing path.
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

            if (mem_response_exception || ex_exception || ex_redirect ||
                trap_pending || load_use_stall) begin
                id_ex_valid <= 1'b0;
            end else begin
                id_ex_valid <= if_id_valid;
            end
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            ex_mem_valid           <= 1'b0;
            ex_mem_pc              <= RESET_PC;
            ex_mem_instruction     <= NOP;
            ex_mem_rd_addr         <= 5'd0;
            ex_mem_reg_write       <= 1'b0;
            ex_mem_result_select   <= RESULT_ALU;
            ex_mem_mem_read        <= 1'b0;
            ex_mem_mem_write       <= 1'b0;
            ex_mem_mem_size        <= SIZE_WORD;
            ex_mem_load_unsigned   <= 1'b0;
            ex_mem_alu_result      <= 32'd0;
            ex_mem_pc_plus_four    <= 32'd0;
            ex_mem_store_data      <= 32'd0;
            ex_mem_store_strobe    <= 4'd0;
            ex_mem_exception       <= 1'b0;
            ex_mem_exception_cause <= 5'd0;
            ex_mem_exception_value <= 32'd0;
        end else if (pipeline_step) begin
            // As above, ex_mem_valid is the sole bubble marker.  Payload data
            // may change while invalid without any architectural effect.
            ex_mem_pc              <= id_ex_pc;
            ex_mem_instruction     <= id_ex_instruction;
            ex_mem_rd_addr         <= id_ex_rd_addr;
            ex_mem_reg_write       <= id_ex_reg_write;
            ex_mem_result_select   <= id_ex_result_select;
            ex_mem_mem_read        <= id_ex_mem_read;
            ex_mem_mem_write       <= id_ex_mem_write;
            ex_mem_mem_size        <= id_ex_mem_size;
            ex_mem_load_unsigned   <= id_ex_load_unsigned;
            ex_mem_alu_result      <= ex_alu_result;
            ex_mem_pc_plus_four    <= ex_pc_plus_four;
            ex_mem_store_data      <= ex_store_write_data;
            ex_mem_store_strobe    <= ex_store_write_strobe;
            ex_mem_exception       <= ex_exception;
            ex_mem_exception_cause <= ex_exception_cause;
            ex_mem_exception_value <= ex_exception_value;

            if (mem_response_exception) begin
                // A MEM fault is older than ID/EX; squash that younger token.
                ex_mem_valid <= 1'b0;
            end else begin
                ex_mem_valid <= id_ex_valid;
            end
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            mem_wb_valid             <= 1'b0;
            mem_wb_pc                <= RESET_PC;
            mem_wb_instruction       <= NOP;
            mem_wb_rd_addr           <= 5'd0;
            mem_wb_reg_write         <= 1'b0;
            mem_wb_write_back_data   <= 32'd0;
            mem_wb_exception         <= 1'b0;
            mem_wb_exception_cause   <= 5'd0;
            mem_wb_exception_value   <= 32'd0;
        end else if (pipeline_step) begin
            mem_wb_valid           <= ex_mem_valid;
            mem_wb_pc              <= ex_mem_pc;
            mem_wb_instruction     <= ex_mem_instruction;
            mem_wb_rd_addr         <= ex_mem_rd_addr;
            mem_wb_reg_write       <= ex_mem_reg_write;
            mem_wb_write_back_data <= mem_stage_write_back_data;
            mem_wb_exception       <= ex_mem_exception ||
                                      mem_response_exception;
            if (mem_response_exception) begin
                mem_wb_exception_cause <= mem_response_exception_cause;
                mem_wb_exception_value <= ex_mem_alu_result;
            end else begin
                mem_wb_exception_cause <= ex_mem_exception_cause;
                mem_wb_exception_value <= ex_mem_exception_value;
            end
        end
    end

    // ------------------------------------------------------------------
    // Retirement, fault/debug view, and game-platform counters
    // ------------------------------------------------------------------
    assign fault = mem_wb_valid && mem_wb_exception;

    assign retire_valid = pipeline_step && mem_wb_valid &&
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

    assign debug_pc =
        mem_wb_valid ? mem_wb_pc :
        ex_mem_valid ? ex_mem_pc :
        id_ex_valid  ? id_ex_pc :
        if_id_valid  ? if_id_pc :
        fetch_available ? fetched_pc : fetch_address;

    assign debug_instruction =
        mem_wb_valid ? mem_wb_instruction :
        ex_mem_valid ? ex_mem_instruction :
        id_ex_valid  ? id_ex_instruction :
        if_id_valid  ? if_id_instruction :
        fetch_available ? fetched_instruction : NOP;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            cycle_count   <= 32'd0;
            instret_count <= 32'd0;
            stall_count   <= 32'd0;
            flush_count   <= 32'd0;
        end else begin
            if (cpu_enable && !fault)
                cycle_count <= cycle_count + 32'd1;
            if (retire_valid)
                instret_count <= instret_count + 32'd1;
            if (cpu_enable && !fault &&
                (pipeline_stalled ||
                 (pipeline_step && load_use_stall)))
                stall_count <= stall_count + 32'd1;
            if (pipeline_flush_event)
                flush_count <= flush_count + 32'd1;
        end
    end

    // FENCE retires as a no-op in this single-hart, cacheless core.
    wire unused_fence = id_fence;
endmodule

`default_nettype wire
