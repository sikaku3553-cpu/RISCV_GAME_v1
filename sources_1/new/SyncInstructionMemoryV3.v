`timescale 1ns/1ps
`default_nettype none

// Single-port synchronous instruction memory for the v3 request/response bus.
//
// A request is accepted on req_valid && req_ready.  Exactly one cycle later
// rsp_valid is asserted with the instruction (or rsp_error for a bad address).
// The registered read is intentionally written in a BRAM-friendly style.
module SyncInstructionMemoryV3 #(
    parameter integer WORDS = 4096,
    parameter INIT_FILE = "",
    parameter [31:0] FILL_INSTRUCTION = 32'h0000_0013
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        req_valid,
    output wire        req_ready,
    input  wire [31:0] req_address,
    output reg         rsp_valid,
    output reg  [31:0] rsp_data,
    output reg         rsp_error
);
    (* ram_style = "block" *) reg [31:0] memory [0:WORDS-1];
    integer i;

    assign req_ready = 1'b1;
    wire request_fire = req_valid && req_ready;
    wire request_error = (req_address[1:0] != 2'b00) ||
                         (req_address[31:2] >= WORDS);

    initial begin
        for (i = 0; i < WORDS; i = i + 1)
            memory[i] = FILL_INSTRUCTION;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, memory);
    end

    // Keep reset and error bookkeeping out of the inferred BRAM read process.
    // rsp_data is irrelevant while rsp_valid is low, so it needs no reset.
    always @(posedge clk) begin
        if (request_fire) begin
            if (request_error)
                rsp_data <= FILL_INSTRUCTION;
            else
                rsp_data <= memory[req_address[31:2]];
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            rsp_valid <= 1'b0;
            rsp_error <= 1'b0;
        end else begin
            rsp_valid <= request_fire;
            rsp_error <= request_fire && request_error;
        end
    end
endmodule

`default_nettype wire
