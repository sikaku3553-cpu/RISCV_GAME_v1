`timescale 1ns/1ps
`default_nettype none

// 640x480 progressive VGA timing from the Basys 3 100 MHz oscillator. A
// clock-enable is used instead of a fabric-generated pixel clock, keeping the
// complete design in one clock domain. The resulting 25.000 MHz pixel rate is
// accepted by standard 640x480 displays.
module VGATiming640x480V3 (
    input  wire       clk,
    input  wire       reset,
    output wire       pixel_enable,
    output reg  [9:0] pixel_x,
    output reg  [9:0] pixel_y,
    output wire       video_active,
    output wire       hsync,
    output wire       vsync,
    output reg        frame_tick
);
    localparam integer H_VISIBLE = 640;
    localparam integer H_FRONT   = 16;
    localparam integer H_SYNC    = 96;
    localparam integer H_TOTAL   = 800;
    localparam integer V_VISIBLE = 480;
    localparam integer V_FRONT   = 10;
    localparam integer V_SYNC    = 2;
    localparam integer V_TOTAL   = 525;

    reg [1:0] pixel_divider;
    assign pixel_enable = (pixel_divider == 2'd3);

    assign video_active = (pixel_x < H_VISIBLE) && (pixel_y < V_VISIBLE);
    assign hsync = !((pixel_x >= H_VISIBLE + H_FRONT) &&
                     (pixel_x <  H_VISIBLE + H_FRONT + H_SYNC));
    assign vsync = !((pixel_y >= V_VISIBLE + V_FRONT) &&
                     (pixel_y <  V_VISIBLE + V_FRONT + V_SYNC));

    always @(posedge clk) begin
        if (reset) begin
            pixel_divider <= 2'd0;
            pixel_x       <= 10'd0;
            pixel_y       <= 10'd0;
            frame_tick    <= 1'b0;
        end else begin
            frame_tick <= 1'b0;
            pixel_divider <= pixel_divider + 2'd1;
            if (pixel_enable) begin
                if (pixel_x == H_TOTAL - 1) begin
                    pixel_x <= 10'd0;
                    if (pixel_y == V_TOTAL - 1) begin
                        pixel_y    <= 10'd0;
                        frame_tick <= 1'b1;
                    end else begin
                        pixel_y <= pixel_y + 10'd1;
                    end
                end else begin
                    pixel_x <= pixel_x + 10'd1;
                end
            end
        end
    end
endmodule

`default_nettype wire

