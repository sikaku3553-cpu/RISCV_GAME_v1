`timescale 1ns/1ps
`default_nettype none

// 256-byte data memory retained as one 64 x 32-bit distributed-RAM array.
// Byte strobes add SB/SH support without returning to four separately declared
// byte arrays. The array itself intentionally has no reset.
module DataMemoryV2 #(
    parameter integer ENABLE_DEBUG = 0
) (
    input  wire        clk,
    input  wire        enable,
    input  wire [3:0]  write_strobe,
    input  wire [31:0] address,
    input  wire [31:0] write_data,
    output wire [31:0] read_data,
    output wire [31:0] debug_word0
);
    (* ram_style = "distributed" *) reg [31:0] memory [0:63];
    wire [5:0] word_index = address[7:2];
    integer i;

    initial begin
        for (i = 0; i < 64; i = i + 1)
            memory[i] = 32'd0;
    end

    assign read_data = memory[word_index];

    generate
        if (ENABLE_DEBUG != 0) begin : generate_debug_read
            // Simulation/debug only. Production top keeps ENABLE_DEBUG at zero
            // so this extra read does not affect RAM inference.
            assign debug_word0 = memory[0];
        end else begin : generate_no_debug_read
            assign debug_word0 = 32'd0;
        end
    endgenerate

    always @(posedge clk) begin
        if (enable) begin
            if (write_strobe[0]) memory[word_index][7:0]   <= write_data[7:0];
            if (write_strobe[1]) memory[word_index][15:8]  <= write_data[15:8];
            if (write_strobe[2]) memory[word_index][23:16] <= write_data[23:16];
            if (write_strobe[3]) memory[word_index][31:24] <= write_data[31:24];
        end
    end
endmodule

`default_nettype wire

