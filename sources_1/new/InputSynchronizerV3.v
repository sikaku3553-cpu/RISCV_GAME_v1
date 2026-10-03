`timescale 1ns/1ps
`default_nettype none

module InputSynchronizerV3 #(
    parameter integer WIDTH = 1
) (
    input  wire                 clk,
    input  wire [WIDTH-1:0]     async_input,
    output wire [WIDTH-1:0]     sync_output
);
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] meta;
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] synced;

    always @(posedge clk) begin
        meta   <= async_input;
        synced <= meta;
    end

    assign sync_output = synced;
endmodule

`default_nettype wire

