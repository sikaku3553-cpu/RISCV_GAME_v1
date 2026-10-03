`timescale 1ns/1ps
`default_nettype none

module tb_v3_vga_timing;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg reset = 1'b1;
    wire pixel_enable;
    wire [9:0] pixel_x;
    wire [9:0] pixel_y;
    wire video_active;
    wire hsync;
    wire vsync;
    wire frame_tick;

    integer pixels;
    integer active_pixels;
    integer hsync_low_pixels;
    integer vsync_low_pixels;
    integer clocks;

    VGATiming640x480V3 dut (
        .clk(clk),
        .reset(reset),
        .pixel_enable(pixel_enable),
        .pixel_x(pixel_x),
        .pixel_y(pixel_y),
        .video_active(video_active),
        .hsync(hsync),
        .vsync(vsync),
        .frame_tick(frame_tick)
    );

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        pixels = 0;
        active_pixels = 0;
        hsync_low_pixels = 0;
        vsync_low_pixels = 0;
        clocks = 0;

        while (!frame_tick && clocks < 1_700_100) begin
            @(posedge clk);
            clocks = clocks + 1;
            if (pixel_enable) begin
                pixels = pixels + 1;
                if (video_active)
                    active_pixels = active_pixels + 1;
                if (!hsync)
                    hsync_low_pixels = hsync_low_pixels + 1;
                if (!vsync)
                    vsync_low_pixels = vsync_low_pixels + 1;
            end
        end

        if (!frame_tick)
            $fatal(1, "VGA frame did not complete");
        if (pixels != 800 * 525)
            $fatal(1, "pixel count %0d, expected %0d", pixels, 800 * 525);
        if (active_pixels != 640 * 480)
            $fatal(1, "active pixel count %0d, expected %0d",
                   active_pixels, 640 * 480);
        if (hsync_low_pixels != 96 * 525)
            $fatal(1, "HSYNC low count %0d, expected %0d",
                   hsync_low_pixels, 96 * 525);
        if (vsync_low_pixels != 2 * 800)
            $fatal(1, "VSYNC low count %0d, expected %0d",
                   vsync_low_pixels, 2 * 800);

        $display("PASS: tb_v3_vga_timing (800x525 totals, active area, sync widths)");
        $finish;
    end
endmodule

`default_nettype wire

