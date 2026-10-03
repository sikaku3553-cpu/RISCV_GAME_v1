`timescale 1ns/1ps
`default_nettype none

// CPU-authored scene state with shadow-to-active commit at a frame boundary.
// req_addr is relative to 0x1100:
//
//   000 status       004 camera       008 backdrop    00c commit
//   010 layer enable 014 HUD score    018 HUD time    01c game status
//   100 + 10*n sprite position (x low 16, y high 16), n=0..15
//   104 + 10*n sprite attributes
//   108 + 10*n firmware animation/debug tag
//   10c + 10*n reserved
//
// Attribute bits are shared with firmware: bit 0 enable, bit 1 horizontal
// flip, bit 2 vertical flip, bits 5:4 priority (0 is front), and bits 13:8
// tile id.  The CPU always accesses the shadow copy.  A write of one to
// COMMIT makes all scene state visible together on the next frame_tick.
module SpriteRegisterBanksV3 (
    input  wire        clk,
    input  wire        reset,
    input  wire        frame_tick,
    input  wire        video_active,

    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_write,
    input  wire [8:0]  req_addr,
    input  wire [3:0]  req_wstrb,
    input  wire [31:0] req_wdata,
    output reg         rsp_valid,
    input  wire        rsp_ready,
    output reg  [31:0] rsp_rdata,
    output reg         rsp_error,

    output reg         commit_pending,
    output reg  [11:0] active_camera_x,
    output reg  [11:0] active_backdrop,
    output reg  [31:0] active_layer_enable,
    output reg  [31:0] active_hud_score,
    output reg  [31:0] active_hud_time,
    output reg  [31:0] active_game_status,

    output wire [15:0] sprite0_x,
    output wire [15:0] sprite0_y,
    output wire [31:0] sprite0_attr,
    output wire [15:0] sprite1_x,
    output wire [15:0] sprite1_y,
    output wire [31:0] sprite1_attr,
    output wire [15:0] sprite2_x,
    output wire [15:0] sprite2_y,
    output wire [31:0] sprite2_attr,
    output wire [15:0] sprite3_x,
    output wire [15:0] sprite3_y,
    output wire [31:0] sprite3_attr,
    output wire [15:0] sprite4_x,
    output wire [15:0] sprite4_y,
    output wire [31:0] sprite4_attr
);
    localparam [31:0] DEFAULT_PLAYER_ATTR = (32 << 8) | 32'h00000001;
    localparam [31:0] DEFAULT_ENEMY_ATTR  = (40 << 8) | 32'h00000011;

    reg [11:0] shadow_camera_x;
    reg [11:0] shadow_backdrop;
    reg [31:0] shadow_layer_enable;
    reg [31:0] shadow_hud_score;
    reg [31:0] shadow_hud_time;
    reg [31:0] shadow_game_status;

    reg [31:0] shadow_sprite_pos  [0:15];
    reg [31:0] shadow_sprite_attr [0:15];
    reg [31:0] shadow_sprite_tag  [0:15];
    reg [31:0] active_sprite_pos  [0:15];
    reg [31:0] active_sprite_attr [0:15];

    reg [31:0] read_data_comb;
    reg        address_known_comb;
    reg        write_allowed_comb;
    integer    slot;

    function [31:0] merge_wstrb;
        input [31:0] old_value;
        input [31:0] new_value;
        input [3:0]  strobes;
        begin
            merge_wstrb = old_value;
            if (strobes[0]) merge_wstrb[7:0]   = new_value[7:0];
            if (strobes[1]) merge_wstrb[15:8]  = new_value[15:8];
            if (strobes[2]) merge_wstrb[23:16] = new_value[23:16];
            if (strobes[3]) merge_wstrb[31:24] = new_value[31:24];
        end
    endfunction

    wire [31:0] merged_camera =
        merge_wstrb({20'd0, shadow_camera_x}, req_wdata, req_wstrb);
    wire [31:0] merged_backdrop =
        merge_wstrb({20'd0, shadow_backdrop}, req_wdata, req_wstrb);

    assign req_ready = !rsp_valid || rsp_ready;

    assign sprite0_x    = active_sprite_pos[0][15:0];
    assign sprite0_y    = active_sprite_pos[0][31:16];
    assign sprite0_attr = active_sprite_attr[0];
    assign sprite1_x    = active_sprite_pos[1][15:0];
    assign sprite1_y    = active_sprite_pos[1][31:16];
    assign sprite1_attr = active_sprite_attr[1];
    assign sprite2_x    = active_sprite_pos[2][15:0];
    assign sprite2_y    = active_sprite_pos[2][31:16];
    assign sprite2_attr = active_sprite_attr[2];
    assign sprite3_x    = active_sprite_pos[3][15:0];
    assign sprite3_y    = active_sprite_pos[3][31:16];
    assign sprite3_attr = active_sprite_attr[3];
    assign sprite4_x    = active_sprite_pos[4][15:0];
    assign sprite4_y    = active_sprite_pos[4][31:16];
    assign sprite4_attr = active_sprite_attr[4];

    always @* begin
        read_data_comb      = 32'd0;
        address_known_comb  = 1'b1;
        write_allowed_comb  = 1'b1;

        case (req_addr)
            9'h000: begin
                read_data_comb = {28'd0, 1'b0, commit_pending,
                                  !video_active, video_active};
                write_allowed_comb = 1'b0;
            end
            9'h004: read_data_comb = {20'd0, shadow_camera_x};
            9'h008: read_data_comb = {20'd0, shadow_backdrop};
            9'h00c: read_data_comb = {31'd0, commit_pending};
            9'h010: read_data_comb = shadow_layer_enable;
            9'h014: read_data_comb = shadow_hud_score;
            9'h018: read_data_comb = shadow_hud_time;
            9'h01c: read_data_comb = shadow_game_status;
            default: begin
                if (req_addr[8]) begin
                    case (req_addr[3:2])
                        2'd0: read_data_comb =
                            shadow_sprite_pos[req_addr[7:4]];
                        2'd1: read_data_comb =
                            shadow_sprite_attr[req_addr[7:4]];
                        2'd2: read_data_comb =
                            shadow_sprite_tag[req_addr[7:4]];
                        default: begin
                            read_data_comb = 32'd0;
                            write_allowed_comb = 1'b0;
                        end
                    endcase
                end else begin
                    address_known_comb = 1'b0;
                    write_allowed_comb = 1'b0;
                end
            end
        endcase
    end

    always @(posedge clk) begin
        if (reset) begin
            rsp_valid            <= 1'b0;
            rsp_rdata            <= 32'd0;
            rsp_error            <= 1'b0;
            commit_pending       <= 1'b0;

            shadow_camera_x      <= 12'd0;
            active_camera_x      <= 12'd0;
            shadow_backdrop      <= 12'h69F;
            active_backdrop      <= 12'h69F;
            shadow_layer_enable  <= 32'h00000007;
            active_layer_enable  <= 32'h00000007;
            shadow_hud_score     <= 32'd0;
            active_hud_score     <= 32'd0;
            shadow_hud_time      <= 32'd400;
            active_hud_time      <= 32'd400;
            shadow_game_status   <= 32'h00030000;
            active_game_status   <= 32'h00030000;

            for (slot = 0; slot < 16; slot = slot + 1) begin
                shadow_sprite_pos[slot]  <= 32'd0;
                active_sprite_pos[slot]  <= 32'd0;
                shadow_sprite_attr[slot] <= 32'd0;
                active_sprite_attr[slot] <= 32'd0;
                shadow_sprite_tag[slot]  <= 32'd0;
            end

            shadow_sprite_pos[0]  <= {16'd192, 16'd32};
            active_sprite_pos[0]  <= {16'd192, 16'd32};
            shadow_sprite_attr[0] <= DEFAULT_PLAYER_ATTR;
            active_sprite_attr[0] <= DEFAULT_PLAYER_ATTR;

            shadow_sprite_pos[1]  <= {16'd192, 16'd144};
            active_sprite_pos[1]  <= {16'd192, 16'd144};
            shadow_sprite_attr[1] <= DEFAULT_ENEMY_ATTR;
            active_sprite_attr[1] <= DEFAULT_ENEMY_ATTR;

            shadow_sprite_pos[2]  <= {16'd192, 16'd320};
            active_sprite_pos[2]  <= {16'd192, 16'd320};
            shadow_sprite_attr[2] <= DEFAULT_ENEMY_ATTR;
            active_sprite_attr[2] <= DEFAULT_ENEMY_ATTR;
        end else begin
            if (rsp_valid && rsp_ready)
                rsp_valid <= 1'b0;

            // Commit first; a simultaneous new COMMIT request remains pending
            // for the following frame rather than being lost.
            if (frame_tick && commit_pending) begin
                active_camera_x     <= shadow_camera_x;
                active_backdrop     <= shadow_backdrop;
                active_layer_enable <= shadow_layer_enable;
                active_hud_score    <= shadow_hud_score;
                active_hud_time     <= shadow_hud_time;
                active_game_status  <= shadow_game_status;
                for (slot = 0; slot < 16; slot = slot + 1) begin
                    active_sprite_pos[slot]  <= shadow_sprite_pos[slot];
                    active_sprite_attr[slot] <= shadow_sprite_attr[slot];
                end
                commit_pending <= 1'b0;
            end

            if (req_valid && req_ready) begin
                rsp_valid <= 1'b1;
                rsp_rdata <= read_data_comb;
                rsp_error <= (|req_addr[1:0]) || !address_known_comb ||
                             (req_write && !write_allowed_comb);

                if (req_write && !(|req_addr[1:0]) &&
                    address_known_comb && write_allowed_comb) begin
                    case (req_addr)
                        9'h004: shadow_camera_x <= merged_camera[11:0];
                        9'h008: shadow_backdrop <= merged_backdrop[11:0];
                        9'h00c: begin
                            if (req_wstrb[0] && req_wdata[0])
                                commit_pending <= 1'b1;
                        end
                        9'h010: shadow_layer_enable <= merge_wstrb(
                            shadow_layer_enable, req_wdata, req_wstrb);
                        9'h014: shadow_hud_score <= merge_wstrb(
                            shadow_hud_score, req_wdata, req_wstrb);
                        9'h018: shadow_hud_time <= merge_wstrb(
                            shadow_hud_time, req_wdata, req_wstrb);
                        9'h01c: shadow_game_status <= merge_wstrb(
                            shadow_game_status, req_wdata, req_wstrb);
                        default: begin
                            if (req_addr[8]) begin
                                case (req_addr[3:2])
                                    2'd0: shadow_sprite_pos[req_addr[7:4]]
                                        <= merge_wstrb(
                                            shadow_sprite_pos[req_addr[7:4]],
                                            req_wdata, req_wstrb);
                                    2'd1: shadow_sprite_attr[req_addr[7:4]]
                                        <= merge_wstrb(
                                            shadow_sprite_attr[req_addr[7:4]],
                                            req_wdata, req_wstrb);
                                    2'd2: shadow_sprite_tag[req_addr[7:4]]
                                        <= merge_wstrb(
                                            shadow_sprite_tag[req_addr[7:4]],
                                            req_wdata, req_wstrb);
                                    default: begin end
                                endcase
                            end
                        end
                    endcase
                end
            end
        end
    end
endmodule

`default_nettype wire
