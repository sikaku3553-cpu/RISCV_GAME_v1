`timescale 1ns/1ps
`default_nettype none

module ClockEnableV2 #(
    parameter [31:0] DIVISOR = 32'd100_000_000
) (
    input  wire clk,
    input  wire reset,
    output reg  enable_pulse
);
    reg [31:0] count;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            count        <= 32'd0;
            enable_pulse <= 1'b0;
        end else if (DIVISOR <= 32'd1) begin
            count        <= 32'd0;
            enable_pulse <= 1'b1;
        end else if (count == DIVISOR - 1) begin
            count        <= 32'd0;
            enable_pulse <= 1'b1;
        end else begin
            count        <= count + 32'd1;
            enable_pulse <= 1'b0;
        end
    end
endmodule

`default_nettype wire

