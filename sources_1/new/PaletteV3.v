`timescale 1ns/1ps
`default_nettype none

// Shared 16-colour, 12-bit RGB palette.  Index zero is transparent to the
// renderer (the lookup value itself is black for debug use).
module PaletteV3 (
    input  wire [3:0]  index,
    output reg  [11:0] rgb
);
    always @* begin
        case (index)
            4'h0: rgb = 12'h000;
            4'h1: rgb = 12'h123;
            4'h2: rgb = 12'h642;
            4'h3: rgb = 12'h963;
            4'h4: rgb = 12'hDB6;
            4'h5: rgb = 12'hB32;
            4'h6: rgb = 12'hE64;
            4'h7: rgb = 12'hFC2;
            4'h8: rgb = 12'hFF8;
            4'h9: rgb = 12'h063;
            4'hA: rgb = 12'h096;
            4'hB: rgb = 12'h4C4;
            4'hC: rgb = 12'hFFF;
            4'hD: rgb = 12'h6CF;
            4'hE: rgb = 12'hAAA;
            default: rgb = 12'hF3A;
        endcase
    end
endmodule

`default_nettype wire
