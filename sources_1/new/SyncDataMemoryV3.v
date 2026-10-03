`timescale 1ns/1ps
`default_nettype none

// Byte-write-enabled synchronous data memory for the v3 data/MMIO bus.
//
// Reads and writes both return one completion response one cycle after the
// request handshake.  A store changes the array only on req_valid &&
// req_ready, which makes the write side effect a single event even when the
// CPU is held for several cycles waiting for the response.
module SyncDataMemoryV3 #(
    parameter integer BYTES = 16384,
    parameter INIT_FILE = "",
    parameter integer INITIALIZE_TO_ZERO = 1
) (
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
    output reg         rsp_error
);
    localparam integer WORDS = BYTES / 4;

    (* ram_style = "block" *) reg [31:0] memory [0:WORDS-1];
    integer i;

    assign req_ready = 1'b1;

    initial begin
        if (INITIALIZE_TO_ZERO != 0) begin
            for (i = 0; i < WORDS; i = i + 1)
                memory[i] = 32'd0;
        end
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, memory);
    end

    // Keep reset out of the inferred BRAM process.  rsp_valid qualifies the
    // read data, so rsp_read_data is deliberately don't-care while reset is
    // active.  This prevents an asynchronously asserted board reset from
    // becoming an asynchronous RAMB enable/reset/write control.
    always @(posedge clk) begin
        if (req_valid && req_ready &&
            (req_address < BYTES) &&
            ({req_address[31:2], 2'b00} < BYTES)) begin
            // Read-first behavior is sufficient because stores do not
            // consume the response data.
            rsp_read_data <= memory[req_address[31:2]];
            if (req_write) begin
                if (req_write_strobe[0])
                    memory[req_address[31:2]][7:0]
                        <= req_write_data[7:0];
                if (req_write_strobe[1])
                    memory[req_address[31:2]][15:8]
                        <= req_write_data[15:8];
                if (req_write_strobe[2])
                    memory[req_address[31:2]][23:16]
                        <= req_write_data[23:16];
                if (req_write_strobe[3])
                    memory[req_address[31:2]][31:24]
                        <= req_write_data[31:24];
            end
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            rsp_valid <= 1'b0;
            rsp_error <= 1'b0;
        end else begin
            rsp_valid <= req_valid && req_ready;
            rsp_error <= (req_valid && req_ready) &&
                         ((req_address >= BYTES) ||
                          ({req_address[31:2], 2'b00} >= BYTES));
        end
    end
endmodule

`default_nettype wire
