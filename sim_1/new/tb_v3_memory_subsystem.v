`timescale 1ns/1ps
`default_nettype none

// Focused bus-fabric regression for the game platform.  This test deliberately
// holds a side-effecting COMMIT request through its response cycle: the fabric
// must backpressure it and the scene slave must accept it exactly once.
module tb_v3_memory_subsystem;
    reg clk = 1'b0;
    reg reset = 1'b1;
    always #5 clk = ~clk;

    reg         req_valid = 1'b0;
    wire        req_ready;
    reg  [31:0] req_address = 32'd0;
    reg         req_write = 1'b0;
    reg  [3:0]  req_write_strobe = 4'd0;
    reg  [31:0] req_write_data = 32'd0;
    wire        rsp_valid;
    wire [31:0] rsp_read_data;
    wire        rsp_error;

    reg  [15:0] switch_state = 16'h5aa5;
    reg  [4:0]  input_state = 5'd0;
    reg         frame_tick = 1'b0;
    reg  [7:0]  ps2_scan_code = 8'h1c;
    reg         ps2_scan_valid = 1'b1;
    reg         ps2_parity_error = 1'b0;
    reg  [31:0] cycle_count = 32'h1122_3344;
    reg  [31:0] instret_count = 32'h2233_4455;
    reg  [31:0] stall_count = 32'h3344_5566;
    reg  [31:0] flush_count = 32'h4455_6677;

    wire [15:0] led_output;
    wire [31:0] frame_count;
    wire [31:0] wall_clock_count;

    reg         video_active = 1'b1;
    wire        commit_pending;
    wire [11:0] active_camera_x;
    wire [11:0] active_backdrop;
    wire [31:0] active_layer_enable;
    wire [31:0] active_hud_score;
    wire [31:0] active_hud_time;
    wire [31:0] active_game_status;

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

    reg         tile_video_en = 1'b0;
    reg  [11:0] tile_video_addr = 12'd0;
    wire [7:0]  tile_video_data;

    integer scene_write_accepts = 0;
    integer accepts_before_commit;
    reg [31:0] read_value;
    reg        read_error;

    GameMemorySubsystemV3 #(
        .DATA_BYTES(256)
    ) dut (
        .clk(clk),
        .reset(reset),
        .req_valid(req_valid),
        .req_ready(req_ready),
        .req_address(req_address),
        .req_write(req_write),
        .req_write_strobe(req_write_strobe),
        .req_write_data(req_write_data),
        .rsp_valid(rsp_valid),
        .rsp_read_data(rsp_read_data),
        .rsp_error(rsp_error),
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

    always @(posedge clk) begin
        if (!reset && dut.scene_req_valid && dut.scene_req_ready && req_write)
            scene_write_accepts <= scene_write_accepts + 1;
    end

    task automatic bus_access;
        input  [31:0] address;
        input         write_enable;
        input  [3:0]  write_strobes;
        input  [31:0] write_data;
        output [31:0] response_data;
        output        response_error;
        begin
            @(negedge clk);
            req_address      = address;
            req_write        = write_enable;
            req_write_strobe = write_strobes;
            req_write_data   = write_data;
            req_valid        = 1'b1;

            while (!req_ready)
                @(negedge clk);

            // The request is accepted on this edge.  Every implemented slave
            // produces its registered response immediately after the edge.
            @(posedge clk);
            #1;
            req_valid = 1'b0;
            if (!rsp_valid)
                $fatal(1, "response missing for address %08x", address);
            response_data  = rsp_read_data;
            response_error = rsp_error;
        end
    endtask

    task automatic expect_read;
        input [31:0] address;
        input [31:0] expected;
        begin
            bus_access(address, 1'b0, 4'b0000, 32'd0,
                       read_value, read_error);
            if (read_error)
                $fatal(1, "read at %08x unexpectedly faulted", address);
            if (read_value !== expected)
                $fatal(1, "read at %08x expected %08x, got %08x",
                       address, expected, read_value);
        end
    endtask

    task automatic expect_write_ok;
        input [31:0] address;
        input [3:0]  strobes;
        input [31:0] value;
        begin
            bus_access(address, 1'b1, strobes, value,
                       read_value, read_error);
            if (read_error)
                $fatal(1, "write at %08x unexpectedly faulted", address);
        end
    endtask

    task automatic expect_error;
        input [31:0] address;
        input        write_enable;
        input [3:0]  strobes;
        input [31:0] value;
        begin
            bus_access(address, write_enable, strobes, value,
                       read_value, read_error);
            if (!read_error)
                $fatal(1, "access at %08x should have faulted", address);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // System MMIO reads and a legal full-word LED write.
        expect_read(32'h0000_1000, 32'h0000_5aa5);
        expect_read(32'h0000_1014, 32'h1122_3344);
        expect_read(32'h0000_1024, 32'h3344_5566);
        expect_read(32'h0000_1044, 32'h0001_001c);
        expect_read(32'h0000_1040, 32'd0);
        expect_write_ok(32'h0000_1040, 4'b1111, 32'h0000_a55a);
        expect_read(32'h0000_1040, 32'h0000_a55a);

        // Partial MMIO writes and writes to read-only registers must fault and
        // must not alter the writable state.
        expect_error(32'h0000_1040, 1'b1, 4'b0011, 32'h0000_1234);
        expect_read(32'h0000_1040, 32'h0000_a55a);
        expect_error(32'h0000_1000, 1'b1, 4'b1111, 32'hffff_ffff);
        expect_error(32'h0000_1048, 1'b0, 4'b0000, 32'd0);
        expect_error(32'h0000_3000, 1'b0, 4'b0000, 32'd0);

        // Rising-edge capture and write-one-to-clear behavior.
        @(negedge clk);
        input_state = 5'b00101;
        @(posedge clk);
        #1;
        expect_read(32'h0000_1008, 32'h0000_0005);
        expect_write_ok(32'h0000_1008, 4'b1111, 32'h0000_0001);
        expect_read(32'h0000_1008, 32'h0000_0004);

        // A new edge arriving on the clear handshake must not be lost.
        @(negedge clk);
        input_state = 5'd0;
        @(posedge clk);
        @(negedge clk);
        input_state      = 5'b00010;
        req_address      = 32'h0000_1008;
        req_write        = 1'b1;
        req_write_strobe = 4'b1111;
        req_write_data   = 32'h0000_0004;
        req_valid        = 1'b1;
        if (!req_ready)
            $fatal(1, "edge-clear request unexpectedly backpressured");
        @(posedge clk);
        #1;
        req_valid = 1'b0;
        if (!rsp_valid || rsp_error)
            $fatal(1, "edge-clear request failed");
        expect_read(32'h0000_1008, 32'h0000_0002);

        // Tile RAM byte strobes and synchronous VGA-port readback.
        expect_read(32'h0000_2000, 32'd0);
        expect_write_ok(32'h0000_2000, 4'b1111, 32'h4433_2211);
        expect_write_ok(32'h0000_2001, 4'b0010, 32'h0000_aa00);
        expect_read(32'h0000_2000, 32'h4433_aa11);
        @(negedge clk);
        tile_video_addr = 12'h001;
        tile_video_en   = 1'b1;
        @(posedge clk);
        #1;
        if (tile_video_data !== 8'haa)
            $fatal(1, "VGA tile byte expected aa, got %02x",
                   tile_video_data);
        tile_video_en = 1'b0;

        // Main RAM supports byte writes; an address beyond the configured RAM
        // but still inside its bus aperture must return a slave error.
        expect_write_ok(32'h0000_4000, 4'b1111, 32'hdead_beef);
        expect_write_ok(32'h0000_4002, 4'b0100, 32'h005a_0000);
        expect_read(32'h0000_4000, 32'hde5a_beef);
        expect_error(32'h0000_4100, 1'b0, 4'b0000, 32'd0);

        // Scene read-only and reserved registers have explicit write faults.
        expect_error(32'h0000_1100, 1'b1, 4'b1111, 32'd0);
        expect_error(32'h0000_120c, 1'b1, 4'b1111, 32'd0);
        expect_error(32'h0000_1120, 1'b0, 4'b0000, 32'd0);

        // Stage camera state, then hold COMMIT valid for the complete response
        // cycle.  req_ready must stay low, the request may be accepted only
        // once, and a simultaneous frame tick must clear commit_pending.
        expect_write_ok(32'h0000_1104, 4'b1111, 32'h0000_0abc);
        accepts_before_commit = scene_write_accepts;
        @(negedge clk);
        req_address      = 32'h0000_110c;
        req_write        = 1'b1;
        req_write_strobe = 4'b0001;
        req_write_data   = 32'h0000_0001;
        req_valid        = 1'b1;
        while (!req_ready)
            @(negedge clk);
        @(posedge clk);
        #1;
        if (!rsp_valid || rsp_error || !commit_pending)
            $fatal(1, "COMMIT was not accepted cleanly");
        if (req_ready)
            $fatal(1, "fabric did not backpressure an outstanding request");

        frame_tick = 1'b1;
        @(posedge clk);
        #1;
        req_valid  = 1'b0;
        frame_tick = 1'b0;
        if (commit_pending)
            $fatal(1, "held COMMIT repeated after frame-boundary consume");
        if (scene_write_accepts !== accepts_before_commit + 1)
            $fatal(1, "COMMIT accepted %0d times instead of exactly once",
                   scene_write_accepts - accepts_before_commit);
        if (active_camera_x !== 12'habc)
            $fatal(1, "frame commit did not activate camera: %03x",
                   active_camera_x);

        $display("PASS: v3 memory fabric/MMIO errors, W1C, byte lanes, exact-once backpressure");
        $finish;
    end
endmodule

`default_nettype wire
