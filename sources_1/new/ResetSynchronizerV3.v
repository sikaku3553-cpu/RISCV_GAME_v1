`timescale 1ns/1ps
`default_nettype none

// Reset is asserted asynchronously so the board button is always effective,
// then released on a clock edge after two complete synchronization cycles.
module ResetSynchronizerV3 (
    input  wire clk,
    input  wire async_reset,
    output wire reset
);
    (* ASYNC_REG = "TRUE" *) reg [1:0] release_pipe;

    // Xilinx configuration initializes these flip-flops asserted, providing
    // a deterministic two-clock power-on reset even when btnC is not pressed.
    // The asynchronous branch still makes an external reset take effect at
    // once, and the shift register keeps its release synchronous.
    initial release_pipe = 2'b11;

    always @(posedge clk or posedge async_reset) begin
        if (async_reset)
            release_pipe <= 2'b11;
        else
            release_pipe <= {release_pipe[0], 1'b0};
    end

    assign reset = release_pipe[1];
endmodule

`default_nettype wire
