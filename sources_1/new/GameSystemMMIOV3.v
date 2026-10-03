`timescale 1ns/1ps
`default_nettype none

// System/input/performance register block at 0x0000_1000-0x0000_10ff.
// Requests complete one clock after acceptance. Write side effects are tied to
// req_valid && req_ready, so a stalled CPU cannot repeat an MMIO operation.
module GameSystemMMIOV3 (
    input  wire        clk,
    input  wire        reset,

    input  wire        req_valid,
    output wire        req_ready,
    input  wire [31:0] req_address,
    input  wire        req_write,
    input  wire [3:0]  req_write_strobe,
    input  wire [31:0] req_write_data,
    output reg         rsp_valid,
    output reg  [31:0] rsp_read_data,
    output reg         rsp_error,

    input  wire [15:0] switch_state,
    input  wire [4:0]  input_state,
    input  wire        frame_tick,
    input  wire [7:0]  ps2_scan_code,
    input  wire        ps2_scan_valid,
    input  wire        ps2_parity_error,
    input  wire [31:0] cycle_count,
    input  wire [31:0] instret_count,
    input  wire [31:0] stall_count,
    input  wire [31:0] flush_count,

    output reg  [15:0] led_output,
    output reg  [31:0] frame_count,
    output reg  [31:0] wall_clock_count
);
    localparam [31:0] ADDR_SWITCHES = 32'h0000_1000;
    localparam [31:0] ADDR_INPUT    = 32'h0000_1004;
    localparam [31:0] ADDR_EDGES    = 32'h0000_1008;
    localparam [31:0] ADDR_FRAME    = 32'h0000_100c;
    localparam [31:0] ADDR_TIMER    = 32'h0000_1010;
    // The high halves are reserved as zero so the software ABI can grow to
    // 64-bit counters without moving any register.
    localparam [31:0] ADDR_CYCLE_LO   = 32'h0000_1014;
    localparam [31:0] ADDR_CYCLE_HI   = 32'h0000_1018;
    localparam [31:0] ADDR_INSTRET_LO = 32'h0000_101c;
    localparam [31:0] ADDR_INSTRET_HI = 32'h0000_1020;
    localparam [31:0] ADDR_STALL_LO   = 32'h0000_1024;
    localparam [31:0] ADDR_STALL_HI   = 32'h0000_1028;
    localparam [31:0] ADDR_FLUSH_LO   = 32'h0000_102c;
    localparam [31:0] ADDR_FLUSH_HI   = 32'h0000_1030;
    localparam [31:0] ADDR_MEMWAIT_LO = 32'h0000_1034;
    localparam [31:0] ADDR_MEMWAIT_HI = 32'h0000_1038;
    localparam [31:0] ADDR_COUNTER_CTL= 32'h0000_103c;
    localparam [31:0] ADDR_LED      = 32'h0000_1040;
    localparam [31:0] ADDR_PS2      = 32'h0000_1044;

    reg [4:0] previous_input;
    reg [4:0] input_edges;
    wire [4:0] new_input_edges = input_state & ~previous_input;
    reg [31:0] selected_read_data;
    reg selected_address_valid;
    reg selected_write_allowed;

    assign req_ready = 1'b1;

    always @(*) begin
        selected_read_data = 32'd0;
        selected_address_valid = 1'b1;
        selected_write_allowed = 1'b0;
        case (req_address)
            ADDR_SWITCHES: selected_read_data = {16'd0, switch_state};
            ADDR_INPUT:    selected_read_data = {27'd0, input_state};
            ADDR_EDGES: begin
                selected_read_data = {27'd0, input_edges};
                selected_write_allowed = 1'b1;
            end
            ADDR_FRAME:   selected_read_data = frame_count;
            ADDR_TIMER:   selected_read_data = wall_clock_count;
            ADDR_CYCLE_LO:   selected_read_data = cycle_count;
            ADDR_CYCLE_HI:   selected_read_data = 32'd0;
            ADDR_INSTRET_LO: selected_read_data = instret_count;
            ADDR_INSTRET_HI: selected_read_data = 32'd0;
            ADDR_STALL_LO:   selected_read_data = stall_count;
            ADDR_STALL_HI:   selected_read_data = 32'd0;
            ADDR_FLUSH_LO:   selected_read_data = flush_count;
            ADDR_FLUSH_HI:   selected_read_data = 32'd0;
            // A dedicated memory-wait counter is reserved for a later core
            // revision.  Reading it is defined and deterministic today.
            ADDR_MEMWAIT_LO: selected_read_data = 32'd0;
            ADDR_MEMWAIT_HI: selected_read_data = 32'd0;
            ADDR_COUNTER_CTL: begin
                selected_read_data = 32'd0;
                selected_write_allowed = 1'b1;
            end
            ADDR_LED: begin
                selected_read_data = {16'd0, led_output};
                selected_write_allowed = 1'b1;
            end
            ADDR_PS2: selected_read_data = {
                14'd0, ps2_parity_error, ps2_scan_valid, 8'd0,
                ps2_scan_code
            };
            default: begin
                selected_address_valid = 1'b0;
                selected_read_data = 32'd0;
            end
        endcase
    end

    always @(posedge clk) begin
        if (reset) begin
            rsp_valid        <= 1'b0;
            rsp_read_data    <= 32'd0;
            rsp_error        <= 1'b0;
            previous_input   <= 5'd0;
            input_edges      <= 5'd0;
            led_output       <= 16'd0;
            frame_count      <= 32'd0;
            wall_clock_count <= 32'd0;
        end else begin
            wall_clock_count <= wall_clock_count + 32'd1;
            if (frame_tick)
                frame_count <= frame_count + 32'd1;

            input_edges    <= input_edges | new_input_edges;
            previous_input <= input_state;

            rsp_valid <= req_valid && req_ready;
            rsp_error <= 1'b0;
            if (req_valid && req_ready) begin
                rsp_read_data <= selected_read_data;
                if (!selected_address_valid ||
                    (req_write &&
                     (!selected_write_allowed ||
                      req_write_strobe != 4'b1111))) begin
                    rsp_error <= 1'b1;
                end else if (req_write) begin
                    case (req_address)
                        ADDR_EDGES:
                            input_edges <= (input_edges &
                                           ~req_write_data[4:0]) |
                                           new_input_edges;
                        ADDR_LED:
                            led_output <= req_write_data[15:0];
                        default: ;
                    endcase
                end
            end
        end
    end
endmodule

`default_nettype wire
