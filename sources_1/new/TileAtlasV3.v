`timescale 1ns/1ps
`default_nettype none

// Two-read-port procedural tile atlas.  A tile is 16 x 16 pixels and returns
// a four-bit palette index.  Port zero is used by the background and port one
// by the sprite layer.  The one-clock registered outputs model the latency of
// a small ROM while keeping the artwork auditable as geometric RTL.
module TileAtlasV3 (
    input  wire       clk,
    input  wire       reset,

    input  wire       bg_en,
    input  wire [5:0] bg_tile_id,
    input  wire [3:0] bg_x,
    input  wire [3:0] bg_y,
    output reg  [3:0] bg_palette_index,

    input  wire       sprite_en,
    input  wire [5:0] sprite_tile_id,
    input  wire [3:0] sprite_x,
    input  wire [3:0] sprite_y,
    output reg  [3:0] sprite_palette_index
);
    function [3:0] tile_pixel;
        input [5:0] tile_id;
        input [3:0] px;
        input [3:0] py;
        begin
            tile_pixel = 4'h0;
            case (tile_id)
                // Ground cap and fill.
                6'd1: begin
                    if (py < 4'd2)
                        tile_pixel = 4'h4;
                    else if (py == 4'd2 || px == 4'd0)
                        tile_pixel = 4'h2;
                    else if (px[2] ^ py[2])
                        tile_pixel = 4'h3;
                    else
                        tile_pixel = 4'h2;
                end
                6'd2: begin
                    if ((px[2:0] == 3'd0) || (py[2:0] == 3'd0))
                        tile_pixel = 4'h2;
                    else if (px[3] ^ py[3])
                        tile_pixel = 4'h3;
                    else
                        tile_pixel = 4'h4;
                end

                // Brick, bonus, and spent block.
                6'd3: begin
                    if (px == 4'd0 || py == 4'd0 || py == 4'd7 ||
                        py == 4'd15 ||
                        ((py < 4'd7) && px == 4'd8) ||
                        ((py > 4'd7) && px == 4'd4))
                        tile_pixel = 4'h2;
                    else if (py[2])
                        tile_pixel = 4'h6;
                    else
                        tile_pixel = 4'h5;
                end
                6'd4: begin
                    if (px == 4'd0 || px == 4'd15 ||
                        py == 4'd0 || py == 4'd15)
                        tile_pixel = 4'h2;
                    else if ((py == 4'd4 && px >= 4'd6 && px <= 4'd10) ||
                             (py == 4'd5 && (px == 4'd5 || px == 4'd11)) ||
                             (py == 4'd6 && px == 4'd10) ||
                             (py == 4'd7 && px == 4'd9) ||
                             (py == 4'd8 && px == 4'd8) ||
                             (py == 4'd11 && px == 4'd8))
                        tile_pixel = 4'h1;
                    else if (px == 4'd2 || py == 4'd2)
                        tile_pixel = 4'h8;
                    else
                        tile_pixel = 4'h7;
                end
                6'd5: begin
                    if (px == 4'd0 || px == 4'd15 ||
                        py == 4'd0 || py == 4'd15)
                        tile_pixel = 4'h1;
                    else if (px == 4'd2 || py == 4'd2)
                        tile_pixel = 4'h4;
                    else
                        tile_pixel = 4'h3;
                end

                // Pipe top-left/top-right and body-left/body-right.
                6'd6, 6'd7: begin
                    if (px == 4'd0 || px == 4'd15 ||
                        py == 4'd0 || py == 4'd3 || py == 4'd15)
                        tile_pixel = 4'h9;
                    else if ((tile_id == 6'd6 && px > 4'd10) ||
                             (tile_id == 6'd7 && px < 4'd5))
                        tile_pixel = 4'hA;
                    else if (px[2:0] < 3'd3)
                        tile_pixel = 4'hB;
                    else
                        tile_pixel = 4'hA;
                end
                6'd8, 6'd9: begin
                    if ((tile_id == 6'd8 && px == 4'd0) ||
                        (tile_id == 6'd9 && px == 4'd15))
                        tile_pixel = 4'h9;
                    else if ((tile_id == 6'd8 && px >= 4'd11) ||
                             (tile_id == 6'd9 && px <= 4'd4))
                        tile_pixel = 4'hA;
                    else if (px[2:0] < 3'd3)
                        tile_pixel = 4'hB;
                    else
                        tile_pixel = 4'hA;
                end

                6'd10: begin
                    if (px == 4'd0 || py == 4'd0)
                        tile_pixel = 4'h1;
                    else if (px == 4'd2 || py == 4'd2)
                        tile_pixel = 4'h8;
                    else
                        tile_pixel = 4'hE;
                end

                // Goal pole and project-created triangular marker.
                6'd11: begin
                    if (px == 4'd7 || px == 4'd8)
                        tile_pixel = 4'hE;
                    else if (py >= 4'd13 && px >= 4'd4 && px <= 4'd11)
                        tile_pixel = 4'h1;
                end
                6'd12: begin
                    if (px == 4'd0)
                        tile_pixel = 4'hE;
                    else if (py < 4'd10 && px <= (4'd12 - py))
                        tile_pixel = (px == 4'd1 || py == 4'd0) ? 4'h1 : 4'hF;
                end

                // Clouds, shrubs, and a low hill are transparent scenery.
                6'd13: begin
                    if (((py >= 4'd7 && py <= 4'd12) &&
                         (px >= 4'd2 && px <= 4'd14)) ||
                        ((py >= 4'd4 && py <= 4'd11) &&
                         (px >= 4'd5 && px <= 4'd10)))
                        tile_pixel = (py == 4'd12) ? 4'hD : 4'hC;
                end
                6'd14: begin
                    if ((py >= 4'd7 && px >= 4'd1 && px <= 4'd14) ||
                        (py >= 4'd4 && py < 4'd12 &&
                         px >= 4'd5 && px <= 4'd10))
                        tile_pixel = (py == 4'd15 || px == 4'd1 ||
                                      px == 4'd14) ? 4'h9 : 4'hA;
                end
                6'd15: begin
                    if (py >= 4'd4 && py >= (px > 4'd8 ? px - 4'd5 :
                                                       4'd11 - px))
                        tile_pixel = (px[2:0] == 3'd0) ? 4'h9 : 4'hB;
                end

                // Three small warning spikes.
                6'd16: begin
                    if (py >= 4'd8 &&
                        ((px[2:0] <= (py - 4'd8)) ||
                         (px[2:0] >= (4'd15 - py))))
                        tile_pixel = (py == 4'd15) ? 4'h1 : 4'hF;
                end

                // Original player character: a compact helmeted explorer.
                6'd32, 6'd33, 6'd34: begin
                    if (py <= 4'd2 && px >= 4'd5 && px <= 4'd10)
                        tile_pixel = 4'hD;
                    else if (py >= 4'd3 && py <= 4'd6 &&
                             px >= 4'd4 && px <= 4'd11)
                        tile_pixel = (px == 4'd5 || px == 4'd10) ? 4'h1 : 4'hC;
                    else if (py >= 4'd7 && py <= 4'd11 &&
                             px >= 4'd3 && px <= 4'd12)
                        tile_pixel = (px == 4'd3 || px == 4'd12) ? 4'h1 : 4'hF;
                    else if (tile_id == 6'd34 && py >= 4'd12 &&
                             ((px >= 4'd2 && px <= 4'd6) ||
                              (px >= 4'd9 && px <= 4'd13)))
                        tile_pixel = 4'hD;
                    else if (tile_id == 6'd33 && py >= 4'd12 &&
                             ((px >= 4'd3 && px <= 4'd7) ||
                              (py >= 4'd14 && px >= 4'd9 && px <= 4'd14)))
                        tile_pixel = 4'hD;
                    else if (tile_id == 6'd32 && py >= 4'd12 &&
                             ((px >= 4'd4 && px <= 4'd7) ||
                              (px >= 4'd9 && px <= 4'd12)))
                        tile_pixel = 4'hD;
                end

                // Round walking obstacle, two animation phases.
                6'd40, 6'd41: begin
                    if (py >= 4'd5 && py <= 4'd12 &&
                        px >= 4'd2 && px <= 4'd13) begin
                        if ((py == 4'd6 && (px == 4'd5 || px == 4'd10)) ||
                            (py == 4'd10 && px >= 4'd6 && px <= 4'd9))
                            tile_pixel = 4'h1;
                        else
                            tile_pixel = 4'h6;
                    end else if (py >= 4'd13 &&
                                 ((tile_id == 6'd40 &&
                                   ((px >= 4'd1 && px <= 4'd5) ||
                                    (px >= 4'd10 && px <= 4'd14))) ||
                                  (tile_id == 6'd41 &&
                                   ((px >= 4'd3 && px <= 4'd7) ||
                                    (px >= 4'd8 && px <= 4'd12)))))
                        tile_pixel = 4'h2;
                end

                // Collectable ring and completion sparkle.
                6'd42: begin
                    if (((px >= 4'd5 && px <= 4'd10) &&
                         (py == 4'd3 || py == 4'd12)) ||
                        ((py >= 4'd5 && py <= 4'd10) &&
                         (px == 4'd3 || px == 4'd12)))
                        tile_pixel = 4'h7;
                    else if (((px == 4'd4 || px == 4'd11) &&
                              (py == 4'd4 || py == 4'd11)))
                        tile_pixel = 4'h8;
                end
                6'd43: begin
                    if (px == 4'd7 || px == 4'd8 ||
                        py == 4'd7 || py == 4'd8 ||
                        px == py || (px + py == 4'd15))
                        tile_pixel = (px[0] ^ py[0]) ? 4'h8 : 4'hC;
                end
                default: tile_pixel = 4'h0;
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (reset) begin
            bg_palette_index     <= 4'd0;
            sprite_palette_index <= 4'd0;
        end else begin
            if (bg_en)
                bg_palette_index <= tile_pixel(bg_tile_id, bg_x, bg_y);
            else
                bg_palette_index <= 4'd0;

            if (sprite_en)
                sprite_palette_index
                    <= tile_pixel(sprite_tile_id, sprite_x, sprite_y);
            else
                sprite_palette_index <= 4'd0;
        end
    end
endmodule

`default_nettype wire
