`timescale 1ns/1ps
`default_nettype none

module tb_v3_tile_renderer;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg reset = 1'b1;

    reg         map_req_valid = 1'b0;
    wire        map_req_ready;
    reg         map_req_write = 1'b0;
    reg [11:0]  map_req_addr = 12'd0;
    reg [3:0]   map_req_wstrb = 4'd0;
    reg [31:0]  map_req_wdata = 32'd0;
    wire        map_rsp_valid;
    reg         map_rsp_ready = 1'b1;
    wire [31:0] map_rsp_rdata;
    wire        map_rsp_error;

    wire        map_video_en;
    wire [11:0] map_video_addr;
    wire [7:0]  map_video_tile;

    LevelTilemapV3 level_map (
        .clk(clk), .reset(reset),
        .req_valid(map_req_valid), .req_ready(map_req_ready),
        .req_write(map_req_write), .req_addr(map_req_addr),
        .req_wstrb(map_req_wstrb), .req_wdata(map_req_wdata),
        .rsp_valid(map_rsp_valid), .rsp_ready(map_rsp_ready),
        .rsp_rdata(map_rsp_rdata), .rsp_error(map_rsp_error),
        .video_en(map_video_en), .video_addr(map_video_addr),
        .video_tile(map_video_tile)
    );

    reg         scene_req_valid = 1'b0;
    wire        scene_req_ready;
    reg         scene_req_write = 1'b0;
    reg [8:0]   scene_req_addr = 9'd0;
    reg [3:0]   scene_req_wstrb = 4'd0;
    reg [31:0]  scene_req_wdata = 32'd0;
    wire        scene_rsp_valid;
    reg         scene_rsp_ready = 1'b1;
    wire [31:0] scene_rsp_rdata;
    wire        scene_rsp_error;
    reg         frame_tick = 1'b0;
    wire        commit_pending;
    wire [11:0] active_camera_x;
    wire [11:0] active_backdrop;
    wire [31:0] active_layers;
    wire [31:0] active_score;
    wire [31:0] active_time;
    wire [31:0] active_status;
    wire [15:0] bank_sprite0_x;
    wire [15:0] bank_sprite0_y;
    wire [31:0] bank_sprite0_attr;
    wire [15:0] bank_sprite1_x;
    wire [15:0] bank_sprite1_y;
    wire [31:0] bank_sprite1_attr;
    wire [15:0] bank_sprite2_x;
    wire [15:0] bank_sprite2_y;
    wire [31:0] bank_sprite2_attr;
    wire [15:0] bank_sprite3_x;
    wire [15:0] bank_sprite3_y;
    wire [31:0] bank_sprite3_attr;
    wire [15:0] bank_sprite4_x;
    wire [15:0] bank_sprite4_y;
    wire [31:0] bank_sprite4_attr;

    SpriteRegisterBanksV3 scene_registers (
        .clk(clk), .reset(reset), .frame_tick(frame_tick),
        .video_active(1'b1),
        .req_valid(scene_req_valid), .req_ready(scene_req_ready),
        .req_write(scene_req_write), .req_addr(scene_req_addr),
        .req_wstrb(scene_req_wstrb), .req_wdata(scene_req_wdata),
        .rsp_valid(scene_rsp_valid), .rsp_ready(scene_rsp_ready),
        .rsp_rdata(scene_rsp_rdata), .rsp_error(scene_rsp_error),
        .commit_pending(commit_pending),
        .active_camera_x(active_camera_x),
        .active_backdrop(active_backdrop),
        .active_layer_enable(active_layers),
        .active_hud_score(active_score), .active_hud_time(active_time),
        .active_game_status(active_status),
        .sprite0_x(bank_sprite0_x), .sprite0_y(bank_sprite0_y),
        .sprite0_attr(bank_sprite0_attr),
        .sprite1_x(bank_sprite1_x), .sprite1_y(bank_sprite1_y),
        .sprite1_attr(bank_sprite1_attr),
        .sprite2_x(bank_sprite2_x), .sprite2_y(bank_sprite2_y),
        .sprite2_attr(bank_sprite2_attr),
        .sprite3_x(bank_sprite3_x), .sprite3_y(bank_sprite3_y),
        .sprite3_attr(bank_sprite3_attr),
        .sprite4_x(bank_sprite4_x), .sprite4_y(bank_sprite4_y),
        .sprite4_attr(bank_sprite4_attr)
    );

    reg         pixel_enable = 1'b0;
    reg [9:0]   pixel_x = 10'd0;
    reg [9:0]   pixel_y = 10'd0;
    reg         video_active = 1'b1;
    reg         hsync_in = 1'b1;
    reg         vsync_in = 1'b1;
    reg [11:0]  camera_x = 12'd0;
    reg [11:0]  backdrop = 12'h69F;
    reg [31:0]  layers = 32'h00000003;
    reg [31:0]  hud_score = 32'd0;
    reg [31:0]  hud_time = 32'd0;
    reg [31:0]  game_status = 32'd0;
    reg [15:0]  sprite0_x = 16'd0;
    reg [15:0]  sprite0_y = 16'd0;
    reg [31:0]  sprite0_attr = 32'd0;
    reg [15:0]  sprite1_x = 16'd0;
    reg [15:0]  sprite1_y = 16'd0;
    reg [31:0]  sprite1_attr = 32'd0;
    reg [15:0]  sprite2_x = 16'd0;
    reg [15:0]  sprite2_y = 16'd0;
    reg [31:0]  sprite2_attr = 32'd0;
    reg [15:0]  sprite3_x = 16'd0;
    reg [15:0]  sprite3_y = 16'd0;
    reg [31:0]  sprite3_attr = 32'd0;
    reg [15:0]  sprite4_x = 16'd0;
    reg [15:0]  sprite4_y = 16'd0;
    reg [31:0]  sprite4_attr = 32'd0;

    wire [11:0] vga_rgb;
    wire [3:0]  vga_red;
    wire [3:0]  vga_green;
    wire [3:0]  vga_blue;
    wire        hsync_out;
    wire        vsync_out;
    integer     error_count = 0;

    TileSpriteRendererV3 renderer (
        .clk(clk), .reset(reset), .pixel_enable(pixel_enable),
        .pixel_x(pixel_x), .pixel_y(pixel_y),
        .video_active(video_active), .hsync_in(hsync_in),
        .vsync_in(vsync_in),
        .camera_x(camera_x), .backdrop_color(backdrop),
        .layer_enable(layers), .hud_score(hud_score),
        .hud_time(hud_time), .game_status(game_status),
        .sprite0_x(sprite0_x), .sprite0_y(sprite0_y),
        .sprite0_attr(sprite0_attr),
        .sprite1_x(sprite1_x), .sprite1_y(sprite1_y),
        .sprite1_attr(sprite1_attr),
        .sprite2_x(sprite2_x), .sprite2_y(sprite2_y),
        .sprite2_attr(sprite2_attr),
        .sprite3_x(sprite3_x), .sprite3_y(sprite3_y),
        .sprite3_attr(sprite3_attr),
        .sprite4_x(sprite4_x), .sprite4_y(sprite4_y),
        .sprite4_attr(sprite4_attr),
        .tilemap_video_en(map_video_en),
        .tilemap_video_addr(map_video_addr),
        .tilemap_video_tile(map_video_tile),
        .vga_rgb(vga_rgb), .vga_red(vga_red),
        .vga_green(vga_green), .vga_blue(vga_blue),
        .hsync_out(hsync_out), .vsync_out(vsync_out)
    );

    task check;
        input condition;
        input [255:0] message;
        begin
            if (!condition) begin
                $display("FAIL: %0s", message);
                error_count = error_count + 1;
            end
        end
    endtask

    task map_read_check;
        input [11:0] address;
        input [31:0] expected;
        begin
            @(negedge clk);
            map_req_valid <= 1'b1;
            map_req_write <= 1'b0;
            map_req_addr  <= address;
            map_req_wstrb <= 4'd0;
            @(posedge clk);
            #1;
            map_req_valid <= 1'b0;
            check(map_rsp_valid, "tile-map read did not respond");
            check(!map_rsp_error, "tile-map read returned an error");
            check(map_rsp_rdata == expected, "unexpected tile-map data");
        end
    endtask

    task map_write;
        input [11:0] address;
        input [31:0] value;
        input [3:0] strobes;
        begin
            @(negedge clk);
            map_req_valid <= 1'b1;
            map_req_write <= 1'b1;
            map_req_addr  <= address;
            map_req_wdata <= value;
            map_req_wstrb <= strobes;
            @(posedge clk);
            #1;
            map_req_valid <= 1'b0;
            map_req_write <= 1'b0;
            check(map_rsp_valid && !map_rsp_error,
                  "tile-map write did not complete");
        end
    endtask

    task scene_write;
        input [8:0] address;
        input [31:0] value;
        begin
            @(negedge clk);
            scene_req_valid <= 1'b1;
            scene_req_write <= 1'b1;
            scene_req_addr  <= address;
            scene_req_wdata <= value;
            scene_req_wstrb <= 4'hf;
            @(posedge clk);
            #1;
            scene_req_valid <= 1'b0;
            scene_req_write <= 1'b0;
            check(scene_rsp_valid && !scene_rsp_error,
                  "scene-register write did not complete");
        end
    endtask

    task scene_read_check;
        input [8:0] address;
        input [31:0] expected;
        begin
            @(negedge clk);
            scene_req_valid <= 1'b1;
            scene_req_write <= 1'b0;
            scene_req_addr  <= address;
            scene_req_wstrb <= 4'd0;
            @(posedge clk);
            #1;
            scene_req_valid <= 1'b0;
            check(scene_rsp_valid && !scene_rsp_error,
                  "scene-register read did not complete");
            check(scene_rsp_rdata == expected,
                  "scene-register readback mismatch");
        end
    endtask

    task render_check;
        input [9:0] sample_x;
        input [9:0] sample_y;
        input       sample_active;
        input       sample_hsync;
        input       sample_vsync;
        input [11:0] expected_rgb;
        begin
            @(negedge clk);
            pixel_x      <= sample_x;
            pixel_y      <= sample_y;
            video_active <= sample_active;
            hsync_in     <= sample_hsync;
            vsync_in     <= sample_vsync;
            pixel_enable <= 1'b1;
            @(posedge clk);
            #1 pixel_enable <= 1'b0;
            @(posedge clk);
            @(posedge clk);
            #1;
            if (vga_rgb !== expected_rgb)
                $display("  pixel (%0d,%0d): RGB=%03h expected=%03h",
                         sample_x, sample_y, vga_rgb, expected_rgb);
            check(vga_rgb == expected_rgb, "renderer RGB mismatch");
            check(hsync_out == sample_hsync,
                  "HSYNC not aligned with rendered pixel");
            check(vsync_out == sample_vsync,
                  "VSYNC not aligned with rendered pixel");
            check({vga_red, vga_green, vga_blue} == vga_rgb,
                  "12-bit RGB component wiring mismatch");
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset <= 1'b0;
        repeat (2) @(posedge clk);

        // Seed two words through the CPU port.  Production firmware builds
        // the complete level after reset; the BRAM itself powers up empty.
        map_write(12'hd00, 32'h41414141, 4'b1111);
        map_write(12'hd14, 32'h00004141, 4'b1111);
        map_read_check(12'hd00, 32'h41414141);
        map_read_check(12'hd14, 32'h00004141);

        // Byte-write strobes update one tile without disturbing neighbours.
        map_write(12'h000, 32'h00000044, 4'b0001);
        map_read_check(12'h000, 32'h00000044);

        // The core retains the original low address bits for byte loads and
        // supplies an already shifted lane strobe/data pair for SB.
        map_write(12'h001, 32'h00005500, 4'b0010);
        map_read_check(12'h001, 32'h00005544);

        // Scene writes remain shadowed until a frame commit.
        scene_write(9'h004, 32'd16);
        check(active_camera_x == 12'd0,
              "shadow camera leaked into active frame");
        scene_write(9'h014, 32'h00001234);
        scene_write(9'h140, {16'd32, 16'd32});
        scene_write(9'h144, (43 << 8) | 32'h1);
        // Slot fifteen proves the full architectural descriptor aperture is
        // accepted even though only slots zero through four are rendered.
        scene_write(9'h1f4, (42 << 8) | 32'h1);
        scene_read_check(9'h1f4, (42 << 8) | 32'h1);
        scene_write(9'h00c, 32'h00000001);
        check(commit_pending, "commit request was not latched");
        @(negedge clk);
        frame_tick <= 1'b1;
        @(posedge clk);
        #1;
        frame_tick <= 1'b0;
        check(active_camera_x == 12'd16,
              "camera did not commit at frame boundary");
        check(active_score == 32'h00001234,
              "HUD state did not commit with camera");
        check(bank_sprite4_x == 16'd32 && bank_sprite4_y == 16'd32 &&
              bank_sprite4_attr == ((43 << 8) | 32'h1),
              "slot-four goal descriptor did not commit");
        check(!commit_pending, "commit flag did not clear");

        // Side border uses backdrop, with sync delayed alongside RGB.
        render_check(10'd10, 10'd100, 1'b1, 1'b0, 1'b1, 12'h69f);

        // Ground tile row 13, local (0,0), selects palette colour 4.
        camera_x = 12'd0;
        render_check(10'd64, 10'd416, 1'b1, 1'b1, 1'b1, 12'hdb6);

        // Scrolling tile 22 (the first gap) beneath logical x=0 is sky.
        camera_x = 12'd352;
        render_check(10'd64, 10'd416, 1'b1, 1'b1, 1'b1, 12'h69f);

        // Sprite palette index zero is transparent at its corner, revealing
        // the bonus block written through the CPU port above.
        camera_x = 12'd0;
        sprite0_x = 16'd0;
        sprite0_y = 16'd0;
        sprite0_attr = (32 << 8) | 32'h1;
        render_check(10'd64, 10'd0, 1'b1, 1'b1, 1'b1, 12'h642);

        // The centre of the original explorer sprite overlays the sky.
        render_check(10'd80, 10'd16, 1'b1, 1'b1, 1'b1, 12'hf3a);

        // Architectural slot four is part of the visible set (goal sparkle).
        sprite4_x = 16'd32;
        sprite4_y = 16'd32;
        sprite4_attr = (43 << 8) | 32'h1;
        render_check(10'd142, 10'd78, 1'b1, 1'b1, 1'b1, 12'hfff);

        // Blanking is black, not a stale active-video pixel.
        render_check(10'd700, 10'd500, 1'b0, 1'b1, 1'b0, 12'h000);

        if (error_count != 0) begin
            $display("FAIL: %0d v3 tile/renderer checks failed", error_count);
            $finish(1);
        end else begin
            $display("PASS: v3 tile map, frame commit, and renderer timing");
            $finish;
        end
    end
endmodule

`default_nettype wire
