`timescale 1ns/1ps
`default_nettype none

// Latency-safe data-bus fabric and game-platform slaves.
//
// Address map:
//   0x0000_1000-0x0000_10ff  system/input/performance MMIO
//   0x0000_1100-0x0000_12ff  VGA control and sprite descriptors
//   0x0000_2000-0x0000_2fff  dual-port tile map
//   0x0000_4000-0x0000_7fff  16 KiB main data RAM
//
// The CPU permits one outstanding data request.  This fabric latches the
// selected slave at the request handshake so the response remains correctly
// routed while the master address changes or the pipeline is held.  An
// unmapped access receives a one-cycle-later error response.
module GameMemorySubsystemV3 #(
    parameter integer DATA_BYTES = 16384,
    parameter DATA_INIT_FILE = ""
) (
    input  wire        clk,
    input  wire        reset,

    input  wire        req_valid,
    output wire        req_ready,
    input  wire [31:0] req_address,
    input  wire        req_write,
    input  wire [3:0]  req_write_strobe,
    input  wire [31:0] req_write_data,
    output reg         rsp_valid,
    output reg  [31:0] rsp_read_data,
    output reg         rsp_error,

    input  wire [15:0] switch_state,
    input  wire [4:0]  input_state,
    input  wire        frame_tick,
    input  wire [7:0]  ps2_scan_code,
    input  wire        ps2_scan_valid,
    input  wire        ps2_parity_error,
    input  wire [31:0] cycle_count,
    input  wire [31:0] instret_count,
    input  wire [31:0] stall_count,
    input  wire [31:0] flush_count,

    output wire [15:0] led_output,
    output wire [31:0] frame_count,
    output wire [31:0] wall_clock_count,

    input  wire        video_active,
    output wire        commit_pending,
    output wire [11:0] active_camera_x,
    output wire [11:0] active_backdrop,
    output wire [31:0] active_layer_enable,
    output wire [31:0] active_hud_score,
    output wire [31:0] active_hud_time,
    output wire [31:0] active_game_status,

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
    output wire [31:0] sprite4_attr,

    input  wire        tile_video_en,
    input  wire [11:0] tile_video_addr,
    output wire [7:0]  tile_video_data
);
    localparam [2:0] ROUTE_SYSTEM = 3'd0;
    localparam [2:0] ROUTE_SCENE  = 3'd1;
    localparam [2:0] ROUTE_TILE   = 3'd2;
    localparam [2:0] ROUTE_RAM    = 3'd3;
    localparam [2:0] ROUTE_ERROR  = 3'd4;

    wire select_system = (req_address >= 32'h0000_1000) &&
                         (req_address <  32'h0000_1100);
    wire select_scene  = (req_address >= 32'h0000_1100) &&
                         (req_address <  32'h0000_1300);
    wire select_tile   = (req_address >= 32'h0000_2000) &&
                         (req_address <  32'h0000_3000);
    wire select_ram    = (req_address >= 32'h0000_4000) &&
                         (req_address <  32'h0000_8000);

    reg       route_active;
    reg [2:0] active_route;

    wire system_req_ready;
    wire scene_req_ready;
    wire tile_req_ready;
    wire ram_req_ready;

    wire selected_req_ready = select_system ? system_req_ready :
                              select_scene  ? scene_req_ready  :
                              select_tile   ? tile_req_ready   :
                              select_ram    ? ram_req_ready    : 1'b1;
    assign req_ready = !route_active && selected_req_ready;
    wire request_fire = req_valid && req_ready;

    wire system_req_valid = req_valid && !route_active && select_system;
    wire scene_req_valid  = req_valid && !route_active && select_scene;
    wire tile_req_valid   = req_valid && !route_active && select_tile;
    wire ram_req_valid    = req_valid && !route_active && select_ram;

    wire        system_rsp_valid;
    wire [31:0] system_rsp_data;
    wire        system_rsp_error;
    wire        scene_rsp_valid;
    wire [31:0] scene_rsp_data;
    wire        scene_rsp_error;
    wire        tile_rsp_valid;
    wire [31:0] tile_rsp_data;
    wire        tile_rsp_error;
    wire        ram_rsp_valid;
    wire [31:0] ram_rsp_data;
    wire        ram_rsp_error;

    always @* begin
        rsp_valid     = 1'b0;
        rsp_read_data = 32'd0;
        rsp_error     = 1'b0;
        if (route_active) begin
            case (active_route)
                ROUTE_SYSTEM: begin
                    rsp_valid     = system_rsp_valid;
                    rsp_read_data = system_rsp_data;
                    rsp_error     = system_rsp_error;
                end
                ROUTE_SCENE: begin
                    rsp_valid     = scene_rsp_valid;
                    rsp_read_data = scene_rsp_data;
                    rsp_error     = scene_rsp_error;
                end
                ROUTE_TILE: begin
                    rsp_valid     = tile_rsp_valid;
                    rsp_read_data = tile_rsp_data;
                    rsp_error     = tile_rsp_error;
                end
                ROUTE_RAM: begin
                    rsp_valid     = ram_rsp_valid;
                    rsp_read_data = ram_rsp_data;
                    rsp_error     = ram_rsp_error;
                end
                ROUTE_ERROR: begin
                    rsp_valid     = 1'b1;
                    rsp_read_data = 32'd0;
                    rsp_error     = 1'b1;
                end
                default: begin
                    rsp_valid = 1'b1;
                    rsp_error = 1'b1;
                end
            endcase
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            route_active <= 1'b0;
            active_route <= ROUTE_ERROR;
        end else begin
            if (route_active && rsp_valid)
                route_active <= 1'b0;

            if (request_fire) begin
                route_active <= 1'b1;
                if (select_system)
                    active_route <= ROUTE_SYSTEM;
                else if (select_scene)
                    active_route <= ROUTE_SCENE;
                else if (select_tile)
                    active_route <= ROUTE_TILE;
                else if (select_ram)
                    active_route <= ROUTE_RAM;
                else
                    active_route <= ROUTE_ERROR;
            end
        end
    end

    GameSystemMMIOV3 system_mmio (
        .clk(clk),
        .reset(reset),
        .req_valid(system_req_valid),
        .req_ready(system_req_ready),
        .req_address(req_address),
        .req_write(req_write),
        .req_write_strobe(req_write_strobe),
        .req_write_data(req_write_data),
        .rsp_valid(system_rsp_valid),
        .rsp_read_data(system_rsp_data),
        .rsp_error(system_rsp_error),
        .switch_state(switch_state),
        .input_state(input_state),
        .frame_tick(frame_tick),
        .ps2_scan_code(ps2_scan_code),
        .ps2_scan_valid(ps2_scan_valid),
        .ps2_parity_error(ps2_parity_error),
        .cycle_count(cycle_count),
        .instret_count(instret_count),
        .stall_count(stall_count),
        .flush_count(flush_count),
        .led_output(led_output),
        .frame_count(frame_count),
        .wall_clock_count(wall_clock_count)
    );

    SpriteRegisterBanksV3 scene_registers (
        .clk(clk),
        .reset(reset),
        .frame_tick(frame_tick),
        .video_active(video_active),
        .req_valid(scene_req_valid),
        .req_ready(scene_req_ready),
        .req_write(req_write),
        .req_addr(req_address[8:0] - 9'h100),
        .req_wstrb(req_write_strobe),
        .req_wdata(req_write_data),
        .rsp_valid(scene_rsp_valid),
        .rsp_ready(1'b1),
        .rsp_rdata(scene_rsp_data),
        .rsp_error(scene_rsp_error),
        .commit_pending(commit_pending),
        .active_camera_x(active_camera_x),
        .active_backdrop(active_backdrop),
        .active_layer_enable(active_layer_enable),
        .active_hud_score(active_hud_score),
        .active_hud_time(active_hud_time),
        .active_game_status(active_game_status),
        .sprite0_x(sprite0_x),
        .sprite0_y(sprite0_y),
        .sprite0_attr(sprite0_attr),
        .sprite1_x(sprite1_x),
        .sprite1_y(sprite1_y),
        .sprite1_attr(sprite1_attr),
        .sprite2_x(sprite2_x),
        .sprite2_y(sprite2_y),
        .sprite2_attr(sprite2_attr),
        .sprite3_x(sprite3_x),
        .sprite3_y(sprite3_y),
        .sprite3_attr(sprite3_attr),
        .sprite4_x(sprite4_x),
        .sprite4_y(sprite4_y),
        .sprite4_attr(sprite4_attr)
    );

    LevelTilemapV3 tile_map (
        .clk(clk),
        .reset(reset),
        .req_valid(tile_req_valid),
        .req_ready(tile_req_ready),
        .req_write(req_write),
        .req_addr(req_address[11:0]),
        .req_wstrb(req_write_strobe),
        .req_wdata(req_write_data),
        .rsp_valid(tile_rsp_valid),
        .rsp_ready(1'b1),
        .rsp_rdata(tile_rsp_data),
        .rsp_error(tile_rsp_error),
        .video_en(tile_video_en),
        .video_addr(tile_video_addr),
        .video_tile(tile_video_data)
    );

    SyncDataMemoryV3 #(
        .BYTES(DATA_BYTES),
        .INIT_FILE(DATA_INIT_FILE),
        .INITIALIZE_TO_ZERO(1)
    ) data_memory (
        .clk(clk),
        .reset(reset),
        .req_valid(ram_req_valid),
        .req_ready(ram_req_ready),
        .req_address(req_address - 32'h0000_4000),
        .req_write(req_write),
        .req_write_strobe(req_write_strobe),
        .req_write_data(req_write_data),
        .rsp_valid(ram_rsp_valid),
        .rsp_read_data(ram_rsp_data),
        .rsp_error(ram_rsp_error)
    );
endmodule

`default_nettype wire
