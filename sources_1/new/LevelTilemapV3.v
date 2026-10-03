`timescale 1ns/1ps
`default_nettype none

// 256 x 16 byte tile map used by the game CPU and the VGA renderer.
//
// Each byte is {collision_class[1:0], tile_id[5:0]}.  The CPU port is a
// transaction-safe 32-bit, byte-write port for the 0x2000-0x2fff aperture;
// req_addr is the original 12-bit byte offset inside that aperture.  The
// returned word is selected by req_addr[11:2], while req_addr[1:0] is retained
// for the CPU load formatter and is not an error.  Stores supply an already
// shifted req_wdata/req_wstrb, so an SB at any byte address is supported.
// Internally the map is 1024 x 32 bits: this matches a Xilinx true dual-port
// BRAM template, with byte write enables on the CPU port and a word read on
// the VGA port.  The VGA byte lane is selected after the synchronous read.
// Firmware constructs the complete original teaching level after reset; no
// commercial ROM, map, or extracted artwork is embedded here.
module LevelTilemapV3 (
    input  wire        clk,
    input  wire        reset,

    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_write,
    input  wire [11:0] req_addr,
    input  wire [3:0]  req_wstrb,
    input  wire [31:0] req_wdata,
    output reg         rsp_valid,
    input  wire        rsp_ready,
    output reg  [31:0] rsp_rdata,
    output reg         rsp_error,

    input  wire        video_en,
    input  wire [11:0] video_addr,
    output reg  [7:0]  video_tile
);
    (* ram_style = "block" *) reg [31:0] tile_memory [0:1023];
    reg [31:0] video_word;
    reg [1:0]  video_byte_select;

    integer index;

    // CPU requests are word transactions.  A buffered response allows a
    // paused master to hold rsp_ready low without losing or changing data.
    assign req_ready = !rsp_valid || rsp_ready;

    initial begin
        for (index = 0; index < 1024; index = index + 1)
            tile_memory[index] = 32'd0;
    end

    // The memory array has no reset branch.  Its contents are initialized at
    // configuration and then rebuilt by firmware; rsp_valid alone determines
    // whether rsp_rdata is meaningful.  Keeping reset out of this process
    // avoids asynchronous control paths on the inferred true dual-port BRAM.
    always @(posedge clk) begin
        if (req_valid && req_ready) begin
            // Alignment has already been checked by the CPU according to
            // access size.  Byte accesses intentionally retain addr[1:0].
            rsp_rdata <= tile_memory[req_addr[11:2]];

            if (req_write) begin
                if (req_wstrb[0])
                    tile_memory[req_addr[11:2]][7:0]
                        <= req_wdata[7:0];
                if (req_wstrb[1])
                    tile_memory[req_addr[11:2]][15:8]
                        <= req_wdata[15:8];
                if (req_wstrb[2])
                    tile_memory[req_addr[11:2]][23:16]
                        <= req_wdata[23:16];
                if (req_wstrb[3])
                    tile_memory[req_addr[11:2]][31:24]
                        <= req_wdata[31:24];
            end
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            rsp_valid <= 1'b0;
            rsp_error <= 1'b0;
        end else begin
            if (rsp_valid && rsp_ready)
                rsp_valid <= 1'b0;

            if (req_valid && req_ready) begin
                rsp_valid <= 1'b1;
                rsp_error <= 1'b0;
            end
        end
    end

    always @(posedge clk) begin
        if (video_en) begin
            video_word        <= tile_memory[video_addr[11:2]];
            video_byte_select <= video_addr[1:0];
        end
    end

    always @* begin
        case (video_byte_select)
            2'd0: video_tile = video_word[7:0];
            2'd1: video_tile = video_word[15:8];
            2'd2: video_tile = video_word[23:16];
            default: video_tile = video_word[31:24];
        endcase
    end
endmodule

`default_nettype wire
