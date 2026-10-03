`timescale 1ns/1ps
`default_nettype none

// v1.1 LUTRAM-oriented register file retained for v2.
module RegisterFileV2 #(
    parameter integer ENABLE_DEBUG = 0
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        enable,
    input  wire        write_enable,
    input  wire [4:0]  read_addr1,
    input  wire [4:0]  read_addr2,
    input  wire [4:0]  write_addr,
    input  wire [31:0] write_data,
    input  wire [4:0]  debug_addr,
    output wire [31:0] read_data1,
    output wire [31:0] read_data2,
    output wire [31:0] debug_data
);
    // Two single-read distributed memories provide the two source operands.
    // Do not reset these arrays; resetting them causes FF implementation.
    (* ram_style = "distributed" *) reg [31:0] registers_a [0:31];
    (* ram_style = "distributed" *) reg [31:0] registers_b [0:31];

    reg [31:0] valid;
    wire write_fire = enable && write_enable && (write_addr != 5'd0) && !reset;

    assign read_data1 = ((read_addr1 == 5'd0) || !valid[read_addr1])
                      ? 32'd0 : registers_a[read_addr1];
    assign read_data2 = ((read_addr2 == 5'd0) || !valid[read_addr2])
                      ? 32'd0 : registers_b[read_addr2];

    generate
        if (ENABLE_DEBUG != 0) begin : generate_debug_read
            // A separate simulation/debug copy avoids adding a second address
            // to either production operand bank.
            (* ram_style = "distributed" *) reg [31:0] registers_debug [0:31];
            assign debug_data = ((debug_addr == 5'd0) || !valid[debug_addr])
                              ? 32'd0 : registers_debug[debug_addr];

            always @(posedge clk) begin
                if (write_fire)
                    registers_debug[write_addr] <= write_data;
            end
        end else begin : generate_no_debug_read
            assign debug_data = 32'd0;
        end
    endgenerate

    always @(posedge clk) begin
        if (write_fire) begin
            registers_a[write_addr] <= write_data;
            registers_b[write_addr] <= write_data;
        end
    end

    // Only the validity mask is reset. Invalid locations read as zero.
    always @(posedge clk or posedge reset) begin
        if (reset)
            valid <= 32'd0;
        else if (write_fire)
            valid[write_addr] <= 1'b1;
    end
endmodule

`default_nettype wire

