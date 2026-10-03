`timescale 1ns/1ps
`default_nettype none

// Synchronizes one asynchronous mechanical input and changes the output only
// after the new value has remained stable for STABLE_CYCLES clocks.
module DebounceInputV3 #(
    parameter integer STABLE_CYCLES = 100_000,
    parameter integer COUNTER_BITS = 17
) (
    input  wire clk,
    input  wire reset,
    input  wire async_input,
    output reg  debounced
);
    (* ASYNC_REG = "TRUE" *) reg sync_meta;
    (* ASYNC_REG = "TRUE" *) reg sync_value;
    reg [COUNTER_BITS-1:0] stable_count;

    always @(posedge clk) begin
        sync_meta  <= async_input;
        sync_value <= sync_meta;
    end

    always @(posedge clk) begin
        if (reset) begin
            debounced    <= 1'b0;
            stable_count <= {COUNTER_BITS{1'b0}};
        end else if (sync_value == debounced) begin
            stable_count <= {COUNTER_BITS{1'b0}};
        end else if (STABLE_CYCLES <= 1) begin
            debounced    <= sync_value;
            stable_count <= {COUNTER_BITS{1'b0}};
        end else if (stable_count == STABLE_CYCLES - 1) begin
            debounced    <= sync_value;
            stable_count <= {COUNTER_BITS{1'b0}};
        end else begin
            stable_count <= stable_count + {{(COUNTER_BITS-1){1'b0}}, 1'b1};
        end
    end
endmodule

`default_nettype wire

