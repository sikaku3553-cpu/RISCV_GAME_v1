`timescale 1ns/1ps
`default_nettype none

// 640x480 VGA tile/sprite renderer for a 256x240 logical scene at 2x scale.
// The viewport occupies x=64..575; the two 64-pixel side borders use the
// active backdrop colour.  Game rules do not live here: the CPU supplies the
// camera, HUD values, and the five visible sprite descriptors used by the
// firmware (the register bank still stores all sixteen architectural slots).
//
// The level-map read and atlas read are each synchronous.  Accordingly RGB,
// HSYNC, and VSYNC all emerge together two system clocks after a sampled
// pixel_enable.  They then remain stable until the next sampled pixel.
module TileSpriteRendererV3 (
    input  wire        clk,
    input  wire        reset,
    input  wire        pixel_enable,
    input  wire [9:0]  pixel_x,
    input  wire [9:0]  pixel_y,
    input  wire        video_active,
    input  wire        hsync_in,
    input  wire        vsync_in,

    input  wire [11:0] camera_x,
    input  wire [11:0] backdrop_color,
    input  wire [31:0] layer_enable,
    input  wire [31:0] hud_score,
    input  wire [31:0] hud_time,
    input  wire [31:0] game_status,

    input  wire [15:0] sprite0_x,
    input  wire [15:0] sprite0_y,
    input  wire [31:0] sprite0_attr,
    input  wire [15:0] sprite1_x,
    input  wire [15:0] sprite1_y,
    input  wire [31:0] sprite1_attr,
    input  wire [15:0] sprite2_x,
    input  wire [15:0] sprite2_y,
    input  wire [31:0] sprite2_attr,
    input  wire [15:0] sprite3_x,
    input  wire [15:0] sprite3_y,
    input  wire [31:0] sprite3_attr,
    input  wire [15:0] sprite4_x,
    input  wire [15:0] sprite4_y,
    input  wire [31:0] sprite4_attr,

    output wire        tilemap_video_en,
    output wire [11:0] tilemap_video_addr,
    input  wire [7:0]  tilemap_video_tile,

    output reg  [11:0] vga_rgb,
    output wire [3:0]  vga_red,
    output wire [3:0]  vga_green,
    output wire [3:0]  vga_blue,
    output reg          hsync_out,
    output reg          vsync_out
);
    wire viewport_now = video_active &&
                        (pixel_x >= 10'd64) && (pixel_x < 10'd576) &&
                        (pixel_y < 10'd480);
    wire [9:0] viewport_x_unscaled = pixel_x - 10'd64;
    wire [7:0] logical_x_now = viewport_x_unscaled[8:1];
    wire [7:0] logical_y_now = pixel_y[8:1];
    wire [11:0] world_x_now = camera_x + {4'd0, logical_x_now};
    wire [3:0] tile_local_x_now = world_x_now[3:0];
    wire [3:0] tile_local_y_now = logical_y_now[3:0];

    assign tilemap_video_en   = pixel_enable && viewport_now;
    assign tilemap_video_addr = {logical_y_now[7:4], world_x_now[11:4]};

    assign vga_red   = vga_rgb[11:8];
    assign vga_green = vga_rgb[7:4];
    assign vga_blue  = vga_rgb[3:0];

    wire signed [16:0] world_x_signed = {5'd0, world_x_now};
    wire signed [16:0] logical_y_signed = {9'd0, logical_y_now};
    wire signed [16:0] sprite0_x_signed =
        {{1{sprite0_x[15]}}, sprite0_x};
    wire signed [16:0] sprite0_y_signed =
        {{1{sprite0_y[15]}}, sprite0_y};
    wire signed [16:0] sprite1_x_signed =
        {{1{sprite1_x[15]}}, sprite1_x};
    wire signed [16:0] sprite1_y_signed =
        {{1{sprite1_y[15]}}, sprite1_y};
    wire signed [16:0] sprite2_x_signed =
        {{1{sprite2_x[15]}}, sprite2_x};
    wire signed [16:0] sprite2_y_signed =
        {{1{sprite2_y[15]}}, sprite2_y};
    wire signed [16:0] sprite3_x_signed =
        {{1{sprite3_x[15]}}, sprite3_x};
    wire signed [16:0] sprite3_y_signed =
        {{1{sprite3_y[15]}}, sprite3_y};
    wire signed [16:0] sprite4_x_signed =
        {{1{sprite4_x[15]}}, sprite4_x};
    wire signed [16:0] sprite4_y_signed =
        {{1{sprite4_y[15]}}, sprite4_y};

    wire sprite0_hit = viewport_now && sprite0_attr[0] &&
        world_x_signed >= sprite0_x_signed &&
        world_x_signed < (sprite0_x_signed + 17'sd16) &&
        logical_y_signed >= sprite0_y_signed &&
        logical_y_signed < (sprite0_y_signed + 17'sd16);
    wire sprite1_hit = viewport_now && sprite1_attr[0] &&
        world_x_signed >= sprite1_x_signed &&
        world_x_signed < (sprite1_x_signed + 17'sd16) &&
        logical_y_signed >= sprite1_y_signed &&
        logical_y_signed < (sprite1_y_signed + 17'sd16);
    wire sprite2_hit = viewport_now && sprite2_attr[0] &&
        world_x_signed >= sprite2_x_signed &&
        world_x_signed < (sprite2_x_signed + 17'sd16) &&
        logical_y_signed >= sprite2_y_signed &&
        logical_y_signed < (sprite2_y_signed + 17'sd16);
    wire sprite3_hit = viewport_now && sprite3_attr[0] &&
        world_x_signed >= sprite3_x_signed &&
        world_x_signed < (sprite3_x_signed + 17'sd16) &&
        logical_y_signed >= sprite3_y_signed &&
        logical_y_signed < (sprite3_y_signed + 17'sd16);
    wire sprite4_hit = viewport_now && sprite4_attr[0] &&
        world_x_signed >= sprite4_x_signed &&
        world_x_signed < (sprite4_x_signed + 17'sd16) &&
        logical_y_signed >= sprite4_y_signed &&
        logical_y_signed < (sprite4_y_signed + 17'sd16);

    wire signed [16:0] sprite0_dx = world_x_signed - sprite0_x_signed;
    wire signed [16:0] sprite0_dy = logical_y_signed - sprite0_y_signed;
    wire signed [16:0] sprite1_dx = world_x_signed - sprite1_x_signed;
    wire signed [16:0] sprite1_dy = logical_y_signed - sprite1_y_signed;
    wire signed [16:0] sprite2_dx = world_x_signed - sprite2_x_signed;
    wire signed [16:0] sprite2_dy = logical_y_signed - sprite2_y_signed;
    wire signed [16:0] sprite3_dx = world_x_signed - sprite3_x_signed;
    wire signed [16:0] sprite3_dy = logical_y_signed - sprite3_y_signed;
    wire signed [16:0] sprite4_dx = world_x_signed - sprite4_x_signed;
    wire signed [16:0] sprite4_dy = logical_y_signed - sprite4_y_signed;

    reg       sprite_hit_now;
    reg [5:0] sprite_tile_now;
    reg [3:0] sprite_local_x_now;
    reg [3:0] sprite_local_y_now;
    reg [1:0] sprite_priority_now;

    // Priority zero is nearest the viewer; equal priorities keep the lower
    // descriptor number.  Only a selected descriptor reaches the atlas.
    always @* begin
        sprite_hit_now     = 1'b0;
        sprite_tile_now    = 6'd0;
        sprite_local_x_now = 4'd0;
        sprite_local_y_now = 4'd0;
        sprite_priority_now = 2'b11;

        if (sprite0_hit) begin
            sprite_hit_now      = 1'b1;
            sprite_tile_now     = sprite0_attr[13:8];
            sprite_priority_now = sprite0_attr[5:4];
            sprite_local_x_now  = sprite0_attr[1]
                ? 4'd15 - sprite0_dx[3:0] : sprite0_dx[3:0];
            sprite_local_y_now  = sprite0_attr[2]
                ? 4'd15 - sprite0_dy[3:0] : sprite0_dy[3:0];
        end
        if (sprite1_hit &&
            (!sprite_hit_now || sprite1_attr[5:4] < sprite_priority_now)) begin
            sprite_hit_now      = 1'b1;
            sprite_tile_now     = sprite1_attr[13:8];
            sprite_priority_now = sprite1_attr[5:4];
            sprite_local_x_now  = sprite1_attr[1]
                ? 4'd15 - sprite1_dx[3:0] : sprite1_dx[3:0];
            sprite_local_y_now  = sprite1_attr[2]
                ? 4'd15 - sprite1_dy[3:0] : sprite1_dy[3:0];
        end
        if (sprite2_hit &&
            (!sprite_hit_now || sprite2_attr[5:4] < sprite_priority_now)) begin
            sprite_hit_now      = 1'b1;
            sprite_tile_now     = sprite2_attr[13:8];
            sprite_priority_now = sprite2_attr[5:4];
            sprite_local_x_now  = sprite2_attr[1]
                ? 4'd15 - sprite2_dx[3:0] : sprite2_dx[3:0];
            sprite_local_y_now  = sprite2_attr[2]
                ? 4'd15 - sprite2_dy[3:0] : sprite2_dy[3:0];
        end
        if (sprite3_hit &&
            (!sprite_hit_now || sprite3_attr[5:4] < sprite_priority_now)) begin
            sprite_hit_now      = 1'b1;
            sprite_tile_now     = sprite3_attr[13:8];
            sprite_priority_now = sprite3_attr[5:4];
            sprite_local_x_now  = sprite3_attr[1]
                ? 4'd15 - sprite3_dx[3:0] : sprite3_dx[3:0];
            sprite_local_y_now  = sprite3_attr[2]
                ? 4'd15 - sprite3_dy[3:0] : sprite3_dy[3:0];
        end
        if (sprite4_hit &&
            (!sprite_hit_now || sprite4_attr[5:4] < sprite_priority_now)) begin
            sprite_hit_now      = 1'b1;
            sprite_tile_now     = sprite4_attr[13:8];
            sprite_priority_now = sprite4_attr[5:4];
            sprite_local_x_now  = sprite4_attr[1]
                ? 4'd15 - sprite4_dx[3:0] : sprite4_dx[3:0];
            sprite_local_y_now  = sprite4_attr[2]
                ? 4'd15 - sprite4_dy[3:0] : sprite4_dy[3:0];
        end
    end

    reg        stage0_valid;
    reg        stage0_video_active;
    reg        stage0_viewport;
    reg        stage0_hsync;
    reg        stage0_vsync;
    reg [7:0]  stage0_logical_x;
    reg [7:0]  stage0_logical_y;
    reg [3:0]  stage0_tile_x;
    reg [3:0]  stage0_tile_y;
    reg        stage0_sprite_hit;
    reg [5:0]  stage0_sprite_tile;
    reg [3:0]  stage0_sprite_x;
    reg [3:0]  stage0_sprite_y;
    reg [11:0] stage0_backdrop;
    reg [2:0]  stage0_layers;
    reg [31:0] stage0_hud_score;
    reg [31:0] stage0_hud_time;
    reg [31:0] stage0_game_status;

    reg        stage1_valid;
    reg        stage1_video_active;
    reg        stage1_viewport;
    reg        stage1_hsync;
    reg        stage1_vsync;
    reg [7:0]  stage1_logical_x;
    reg [7:0]  stage1_logical_y;
    reg        stage1_sprite_hit;
    reg [11:0] stage1_backdrop;
    reg [2:0]  stage1_layers;
    reg [31:0] stage1_hud_score;
    reg [31:0] stage1_hud_time;
    reg [31:0] stage1_game_status;

    wire [3:0] background_index;
    wire [3:0] sprite_index;
    wire [11:0] background_rgb;
    wire [11:0] sprite_rgb;
    wire [3:0] hud_index;
    wire [11:0] hud_rgb;

    TileAtlasV3 atlas (
        .clk(clk),
        .reset(reset),
        .bg_en(stage0_valid && stage0_viewport && stage0_layers[0]),
        .bg_tile_id(tilemap_video_tile[5:0]),
        .bg_x(stage0_tile_x),
        .bg_y(stage0_tile_y),
        .bg_palette_index(background_index),
        .sprite_en(stage0_valid && stage0_viewport &&
                   stage0_layers[1] && stage0_sprite_hit),
        .sprite_tile_id(stage0_sprite_tile),
        .sprite_x(stage0_sprite_x),
        .sprite_y(stage0_sprite_y),
        .sprite_palette_index(sprite_index)
    );

    PaletteV3 background_palette (
        .index(background_index),
        .rgb(background_rgb)
    );
    PaletteV3 sprite_palette (
        .index(sprite_index),
        .rgb(sprite_rgb)
    );
    PaletteV3 hud_palette_lookup (
        .index(hud_index),
        .rgb(hud_rgb)
    );

    function [2:0] digit_row;
        input [3:0] digit;
        input [2:0] row;
        begin
            digit_row = 3'b000;
            case (digit)
                4'h0: case (row)
                    0: digit_row=3'b111; 1: digit_row=3'b101;
                    2: digit_row=3'b101; 3: digit_row=3'b101;
                    4: digit_row=3'b111; default: digit_row=3'b000;
                endcase
                4'h1: case (row)
                    0: digit_row=3'b010; 1: digit_row=3'b110;
                    2: digit_row=3'b010; 3: digit_row=3'b010;
                    4: digit_row=3'b111; default: digit_row=3'b000;
                endcase
                4'h2: case (row)
                    0: digit_row=3'b111; 1: digit_row=3'b001;
                    2: digit_row=3'b111; 3: digit_row=3'b100;
                    4: digit_row=3'b111; default: digit_row=3'b000;
                endcase
                4'h3: case (row)
                    0: digit_row=3'b111; 1: digit_row=3'b001;
                    2: digit_row=3'b111; 3: digit_row=3'b001;
                    4: digit_row=3'b111; default: digit_row=3'b000;
                endcase
                4'h4: case (row)
                    0: digit_row=3'b101; 1: digit_row=3'b101;
                    2: digit_row=3'b111; 3: digit_row=3'b001;
                    4: digit_row=3'b001; default: digit_row=3'b000;
                endcase
                4'h5: case (row)
                    0: digit_row=3'b111; 1: digit_row=3'b100;
                    2: digit_row=3'b111; 3: digit_row=3'b001;
                    4: digit_row=3'b111; default: digit_row=3'b000;
                endcase
                4'h6: case (row)
                    0: digit_row=3'b111; 1: digit_row=3'b100;
                    2: digit_row=3'b111; 3: digit_row=3'b101;
                    4: digit_row=3'b111; default: digit_row=3'b000;
                endcase
                4'h7: case (row)
                    0: digit_row=3'b111; 1: digit_row=3'b001;
                    2: digit_row=3'b010; 3: digit_row=3'b010;
                    4: digit_row=3'b010; default: digit_row=3'b000;
                endcase
                4'h8: case (row)
                    0: digit_row=3'b111; 1: digit_row=3'b101;
                    2: digit_row=3'b111; 3: digit_row=3'b101;
                    4: digit_row=3'b111; default: digit_row=3'b000;
                endcase
                4'h9: case (row)
                    0: digit_row=3'b111; 1: digit_row=3'b101;
                    2: digit_row=3'b111; 3: digit_row=3'b001;
                    4: digit_row=3'b111; default: digit_row=3'b000;
                endcase
                4'hA: case (row)
                    0: digit_row=3'b111; 1: digit_row=3'b101;
                    2: digit_row=3'b111; 3: digit_row=3'b101;
                    4: digit_row=3'b101; default: digit_row=3'b000;
                endcase
                4'hB: case (row)
                    0: digit_row=3'b110; 1: digit_row=3'b101;
                    2: digit_row=3'b110; 3: digit_row=3'b101;
                    4: digit_row=3'b110; default: digit_row=3'b000;
                endcase
                4'hC: case (row)
                    0: digit_row=3'b111; 1: digit_row=3'b100;
                    2: digit_row=3'b100; 3: digit_row=3'b100;
                    4: digit_row=3'b111; default: digit_row=3'b000;
                endcase
                4'hD: case (row)
                    0: digit_row=3'b110; 1: digit_row=3'b101;
                    2: digit_row=3'b101; 3: digit_row=3'b101;
                    4: digit_row=3'b110; default: digit_row=3'b000;
                endcase
                4'hE: case (row)
                    0: digit_row=3'b111; 1: digit_row=3'b100;
                    2: digit_row=3'b110; 3: digit_row=3'b100;
                    4: digit_row=3'b111; default: digit_row=3'b000;
                endcase
                default: case (row)
                    0: digit_row=3'b111; 1: digit_row=3'b100;
                    2: digit_row=3'b110; 3: digit_row=3'b100;
                    4: digit_row=3'b100; default: digit_row=3'b000;
                endcase
            endcase
        end
    endfunction

    function glyph_pixel;
        input [3:0] digit;
        input [1:0] column;
        input [2:0] row;
        reg [2:0] bits;
        begin
            bits = digit_row(digit, row);
            case (column)
                2'd0: glyph_pixel = bits[2];
                2'd1: glyph_pixel = bits[1];
                2'd2: glyph_pixel = bits[0];
                default: glyph_pixel = 1'b0;
            endcase
        end
    endfunction

    function [3:0] make_hud_pixel;
        input [7:0] lx;
        input [7:0] ly;
        input [31:0] score;
        input [31:0] time_value;
        input [31:0] status;
        reg lit;
        begin
            lit = 1'b0;
            make_hud_pixel = 4'h0;
            if (ly >= 8'd8 && ly < 8'd13) begin
                if (lx >= 8'd8 && lx < 8'd11)
                    lit = glyph_pixel(score[15:12], lx - 8'd8, ly - 8'd8);
                else if (lx >= 8'd12 && lx < 8'd15)
                    lit = glyph_pixel(score[11:8], lx - 8'd12, ly - 8'd8);
                else if (lx >= 8'd16 && lx < 8'd19)
                    lit = glyph_pixel(score[7:4], lx - 8'd16, ly - 8'd8);
                else if (lx >= 8'd20 && lx < 8'd23)
                    lit = glyph_pixel(score[3:0], lx - 8'd20, ly - 8'd8);
                else if (lx >= 8'd124 && lx < 8'd127) begin
                    lit = glyph_pixel(status[3:0], lx - 8'd124,
                                      ly - 8'd8);
                    if (lit)
                        make_hud_pixel = 4'h7;
                end else if (lx >= 8'd232 && lx < 8'd235)
                    lit = glyph_pixel(time_value[15:12], lx - 8'd232,
                                      ly - 8'd8);
                else if (lx >= 8'd236 && lx < 8'd239)
                    lit = glyph_pixel(time_value[11:8], lx - 8'd236,
                                      ly - 8'd8);
                else if (lx >= 8'd240 && lx < 8'd243)
                    lit = glyph_pixel(time_value[7:4], lx - 8'd240,
                                      ly - 8'd8);
                else if (lx >= 8'd244 && lx < 8'd247)
                    lit = glyph_pixel(time_value[3:0], lx - 8'd244,
                                      ly - 8'd8);

                if (lit && make_hud_pixel == 4'h0)
                    make_hud_pixel = 4'hC;
            end
        end
    endfunction

    assign hud_index = make_hud_pixel(stage1_logical_x,
                                      stage1_logical_y,
                                      stage1_hud_score,
                                      stage1_hud_time,
                                      stage1_game_status);

    always @(posedge clk) begin
        if (reset) begin
            stage0_valid         <= 1'b0;
            stage1_valid         <= 1'b0;
            stage0_video_active  <= 1'b0;
            stage1_video_active  <= 1'b0;
            stage0_viewport      <= 1'b0;
            stage1_viewport      <= 1'b0;
            stage0_hsync         <= 1'b1;
            stage1_hsync         <= 1'b1;
            stage0_vsync         <= 1'b1;
            stage1_vsync         <= 1'b1;
            stage0_logical_x     <= 8'd0;
            stage0_logical_y     <= 8'd0;
            stage1_logical_x     <= 8'd0;
            stage1_logical_y     <= 8'd0;
            stage0_tile_x        <= 4'd0;
            stage0_tile_y        <= 4'd0;
            stage0_sprite_hit    <= 1'b0;
            stage1_sprite_hit    <= 1'b0;
            stage0_sprite_tile   <= 6'd0;
            stage0_sprite_x      <= 4'd0;
            stage0_sprite_y      <= 4'd0;
            stage0_backdrop      <= 12'd0;
            stage1_backdrop      <= 12'd0;
            stage0_layers        <= 3'd0;
            stage1_layers        <= 3'd0;
            stage0_hud_score     <= 32'd0;
            stage0_hud_time      <= 32'd0;
            stage0_game_status   <= 32'd0;
            stage1_hud_score     <= 32'd0;
            stage1_hud_time      <= 32'd0;
            stage1_game_status   <= 32'd0;
            vga_rgb              <= 12'd0;
            hsync_out            <= 1'b1;
            vsync_out            <= 1'b1;
        end else begin
            stage0_valid <= pixel_enable;
            if (pixel_enable) begin
                stage0_video_active <= video_active;
                stage0_viewport     <= viewport_now;
                stage0_hsync        <= hsync_in;
                stage0_vsync        <= vsync_in;
                stage0_logical_x    <= logical_x_now;
                stage0_logical_y    <= logical_y_now;
                stage0_tile_x       <= tile_local_x_now;
                stage0_tile_y       <= tile_local_y_now;
                stage0_sprite_hit   <= sprite_hit_now;
                stage0_sprite_tile  <= sprite_tile_now;
                stage0_sprite_x     <= sprite_local_x_now;
                stage0_sprite_y     <= sprite_local_y_now;
                stage0_backdrop     <= backdrop_color;
                stage0_layers       <= layer_enable[2:0];
                stage0_hud_score    <= hud_score;
                stage0_hud_time     <= hud_time;
                stage0_game_status  <= game_status;
            end

            stage1_valid <= stage0_valid;
            if (stage0_valid) begin
                stage1_video_active <= stage0_video_active;
                stage1_viewport     <= stage0_viewport;
                stage1_hsync        <= stage0_hsync;
                stage1_vsync        <= stage0_vsync;
                stage1_logical_x    <= stage0_logical_x;
                stage1_logical_y    <= stage0_logical_y;
                stage1_sprite_hit   <= stage0_sprite_hit;
                stage1_backdrop     <= stage0_backdrop;
                stage1_layers       <= stage0_layers;
                stage1_hud_score    <= stage0_hud_score;
                stage1_hud_time     <= stage0_hud_time;
                stage1_game_status  <= stage0_game_status;
            end

            if (stage1_valid) begin
                hsync_out <= stage1_hsync;
                vsync_out <= stage1_vsync;
                if (!stage1_video_active)
                    vga_rgb <= 12'h000;
                else if (!stage1_viewport)
                    vga_rgb <= stage1_backdrop;
                else if (stage1_layers[2] && hud_index != 4'h0)
                    vga_rgb <= hud_rgb;
                else if (stage1_layers[1] && stage1_sprite_hit &&
                         sprite_index != 4'h0)
                    vga_rgb <= sprite_rgb;
                else if (stage1_layers[0] && background_index != 4'h0)
                    vga_rgb <= background_rgb;
                else
                    vga_rgb <= stage1_backdrop;
            end
        end
    end
endmodule

`default_nettype wire
