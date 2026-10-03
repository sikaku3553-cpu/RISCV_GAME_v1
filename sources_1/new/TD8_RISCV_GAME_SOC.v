`timescale 1ns/1ps
`default_nettype none

// Complete v3.1 game SoC in one 100 MHz clock domain.  The CPU runs every
// clock; VGA cadence and firmware game cadence are independent frame events.
module TD8_RISCV_GAME_SOC #(
    parameter IMEM_INIT_FILE = "firmware/build/imem_game.hex",
    parameter DATA_INIT_FILE = ""
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        cpu_enable,
    input  wire [15:0] switch_state,
    input  wire [4:0]  game_input_state,
    input  wire [7:0]  ps2_scan_code,
    input  wire        ps2_scan_valid,
    input  wire        ps2_parity_error,

    output wire [15:0] led_output,
    output wire [3:0]  vgaRed,
    output wire [3:0]  vgaGreen,
    output wire [3:0]  vgaBlue,
    output wire        Hsync,
    output wire        Vsync,

    output wire        cpu_fault,
    output wire        pipeline_stalled,
    output wire [31:0] debug_pc,
    output wire [31:0] debug_instruction,
    output wire [4:0]  debug_trap_cause,
    output wire [31:0] debug_trap_value,
    output wire [31:0] cycle_count,
    output wire [31:0] instret_count,
    output wire [31:0] stall_count,
    output wire [31:0] flush_count,
    output wire [31:0] frame_count,
    output wire [31:0] active_game_status,
    output wire        frame_tick_out,
    output wire        commit_pending_out
);
    wire        imem_req_valid;
    wire        imem_req_ready;
    wire [31:0] imem_req_address;
    wire        imem_rsp_valid;
    wire [31:0] imem_rsp_data;
    wire        imem_rsp_error;

    wire        dmem_req_valid;
    wire        dmem_req_ready;
    wire [31:0] dmem_req_address;
    wire        dmem_req_write;
    wire [3:0]  dmem_req_write_strobe;
    wire [31:0] dmem_req_write_data;
    wire        dmem_rsp_valid;
    wire [31:0] dmem_rsp_read_data;
    wire        dmem_rsp_error;

    wire [31:0] unused_debug_reg_data;
    wire        unused_retire_valid;
    wire [31:0] unused_retire_pc;
    wire [31:0] unused_retire_instruction;

    TD8_RISCV_V3_Core cpu (
        .clk(clk),
        .reset(reset),
        .cpu_enable(cpu_enable),
        .imem_req_valid(imem_req_valid),
        .imem_req_ready(imem_req_ready),
        .imem_req_address(imem_req_address),
        .imem_rsp_valid(imem_rsp_valid),
        .imem_rsp_data(imem_rsp_data),
        .imem_rsp_error(imem_rsp_error),
        .dmem_req_valid(dmem_req_valid),
        .dmem_req_ready(dmem_req_ready),
        .dmem_req_address(dmem_req_address),
        .dmem_req_write(dmem_req_write),
        .dmem_req_write_strobe(dmem_req_write_strobe),
        .dmem_req_write_data(dmem_req_write_data),
        .dmem_rsp_valid(dmem_rsp_valid),
        .dmem_rsp_read_data(dmem_rsp_read_data),
        .dmem_rsp_error(dmem_rsp_error),
        .debug_reg_addr(5'd0),
        .debug_pc(debug_pc),
        .debug_instruction(debug_instruction),
        .debug_reg_data(unused_debug_reg_data),
        .debug_trap_cause(debug_trap_cause),
        .debug_trap_value(debug_trap_value),
        .fault(cpu_fault),
        .pipeline_stalled(pipeline_stalled),
        .retire_valid(unused_retire_valid),
        .retire_pc(unused_retire_pc),
        .retire_instruction(unused_retire_instruction),
        .cycle_count(cycle_count),
        .instret_count(instret_count),
        .stall_count(stall_count),
        .flush_count(flush_count)
    );

    SyncInstructionMemoryV3 #(
        .WORDS(4096),
        .INIT_FILE(IMEM_INIT_FILE)
    ) instruction_memory (
        .clk(clk),
        .reset(reset),
        .req_valid(imem_req_valid),
        .req_ready(imem_req_ready),
        .req_address(imem_req_address),
        .rsp_valid(imem_rsp_valid),
        .rsp_data(imem_rsp_data),
        .rsp_error(imem_rsp_error)
    );

    wire       pixel_enable;
    wire [9:0] pixel_x;
    wire [9:0] pixel_y;
    wire       video_active;
    wire       timing_hsync;
    wire       timing_vsync;
    wire       frame_tick;

    VGATiming640x480V3 video_timing (
        .clk(clk),
        .reset(reset),
        .pixel_enable(pixel_enable),
        .pixel_x(pixel_x),
        .pixel_y(pixel_y),
        .video_active(video_active),
        .hsync(timing_hsync),
        .vsync(timing_vsync),
        .frame_tick(frame_tick)
    );
    assign frame_tick_out = frame_tick;

    wire        commit_pending;
    wire [11:0] active_camera_x;
    wire [11:0] active_backdrop;
    wire [31:0] active_layer_enable;
    wire [31:0] active_hud_score;
    wire [31:0] active_hud_time;
    wire [31:0] wall_clock_count;
    wire [15:0] sprite0_x;
    wire [15:0] sprite0_y;
    wire [31:0] sprite0_attr;
    wire [15:0] sprite1_x;
    wire [15:0] sprite1_y;
    wire [31:0] sprite1_attr;
    wire [15:0] sprite2_x;
    wire [15:0] sprite2_y;
    wire [31:0] sprite2_attr;
    wire [15:0] sprite3_x;
    wire [15:0] sprite3_y;
    wire [31:0] sprite3_attr;
    wire [15:0] sprite4_x;
    wire [15:0] sprite4_y;
    wire [31:0] sprite4_attr;
    wire        tile_video_en;
    wire [11:0] tile_video_addr;
    wire [7:0]  tile_video_data;

    assign commit_pending_out = commit_pending;

    GameMemorySubsystemV3 #(
        .DATA_BYTES(16384),
        .DATA_INIT_FILE(DATA_INIT_FILE)
    ) memory_subsystem (
        .clk(clk),
        .reset(reset),
        .req_valid(dmem_req_valid),
        .req_ready(dmem_req_ready),
        .req_address(dmem_req_address),
        .req_write(dmem_req_write),
        .req_write_strobe(dmem_req_write_strobe),
        .req_write_data(dmem_req_write_data),
        .rsp_valid(dmem_rsp_valid),
        .rsp_read_data(dmem_rsp_read_data),
        .rsp_error(dmem_rsp_error),
        .switch_state(switch_state),
        .input_state(game_input_state),
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
        .wall_clock_count(wall_clock_count),
        .video_active(video_active),
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
        .sprite4_attr(sprite4_attr),
        .tile_video_en(tile_video_en),
        .tile_video_addr(tile_video_addr),
        .tile_video_data(tile_video_data)
    );

    wire [11:0] unused_vga_rgb;
    TileSpriteRendererV3 renderer (
        .clk(clk),
        .reset(reset),
        .pixel_enable(pixel_enable),
        .pixel_x(pixel_x),
        .pixel_y(pixel_y),
        .video_active(video_active),
        .hsync_in(timing_hsync),
        .vsync_in(timing_vsync),
        .camera_x(active_camera_x),
        .backdrop_color(active_backdrop),
        .layer_enable(active_layer_enable),
        .hud_score(active_hud_score),
        .hud_time(active_hud_time),
        .game_status(active_game_status),
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
        .sprite4_attr(sprite4_attr),
        .tilemap_video_en(tile_video_en),
        .tilemap_video_addr(tile_video_addr),
        .tilemap_video_tile(tile_video_data),
        .vga_rgb(unused_vga_rgb),
        .vga_red(vgaRed),
        .vga_green(vgaGreen),
        .vga_blue(vgaBlue),
        .hsync_out(Hsync),
        .vsync_out(Vsync)
    );
endmodule

`default_nettype wire

