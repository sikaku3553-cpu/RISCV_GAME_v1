`timescale 1ns/1ps
`default_nettype none

module tb_v3_game_soc;
    reg clk;
    reg reset;
    reg [15:0] switch_state;
    reg [4:0] game_input_state;

    wire [15:0] led_output;
    wire [3:0] vga_red;
    wire [3:0] vga_green;
    wire [3:0] vga_blue;
    wire hsync;
    wire vsync;
    wire cpu_fault;
    wire pipeline_stalled;
    wire [31:0] debug_pc;
    wire [31:0] debug_instruction;
    wire [4:0] debug_trap_cause;
    wire [31:0] debug_trap_value;
    wire [31:0] cycle_count;
    wire [31:0] instret_count;
    wire [31:0] stall_count;
    wire [31:0] flush_count;
    wire [31:0] frame_count;
    wire [31:0] active_game_status;
    wire frame_tick;
    wire commit_pending;

    TD8_RISCV_GAME_SOC #(
        .IMEM_INIT_FILE("firmware/build/imem_game.hex")
    ) dut (
        .clk(clk),
        .reset(reset),
        .cpu_enable(1'b1),
        .switch_state(switch_state),
        .game_input_state(game_input_state),
        .ps2_scan_code(8'd0),
        .ps2_scan_valid(1'b0),
        .ps2_parity_error(1'b0),
        .led_output(led_output),
        .vgaRed(vga_red),
        .vgaGreen(vga_green),
        .vgaBlue(vga_blue),
        .Hsync(hsync),
        .Vsync(vsync),
        .cpu_fault(cpu_fault),
        .pipeline_stalled(pipeline_stalled),
        .debug_pc(debug_pc),
        .debug_instruction(debug_instruction),
        .debug_trap_cause(debug_trap_cause),
        .debug_trap_value(debug_trap_value),
        .cycle_count(cycle_count),
        .instret_count(instret_count),
        .stall_count(stall_count),
        .flush_count(flush_count),
        .frame_count(frame_count),
        .active_game_status(active_game_status),
        .frame_tick_out(frame_tick),
        .commit_pending_out(commit_pending)
    );

    always #5 clk = ~clk;

    task fail;
        input [8*120-1:0] message;
        begin
            $display("FAIL: %0s", message);
            $display("  pc=%08x insn=%08x cause=%0d value=%08x cycles=%0d instret=%0d",
                     debug_pc, debug_instruction, debug_trap_cause,
                     debug_trap_value, cycle_count, instret_count);
            $finish(1);
        end
    endtask

    task wait_for_commit;
        input integer maximum_cycles;
        integer count;
        reg found;
        begin
            found = 1'b0;
            for (count = 0; count < maximum_cycles; count = count + 1) begin
                @(posedge clk);
                if (cpu_fault)
                    fail("CPU trapped while firmware was reaching frame commit");
                if (commit_pending) begin
                    found = 1'b1;
                    count = maximum_cycles;
                end
            end
            if (!found)
                fail("firmware did not request a frame commit before timeout");
        end
    endtask

    task inject_frame_tick;
        begin
            // Avoid a 1.68-million-system-clock VGA frame in this functional
            // test while exercising the exact same frame-count/commit paths.
            force dut.frame_tick = 1'b1;
            @(posedge clk);
            #1;
            release dut.frame_tick;
            @(posedge clk);
        end
    endtask

    reg [15:0] initial_player_x;

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        switch_state = 16'd0;
        game_input_state = 5'd0;
        repeat (8) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // This traverses the actual synchronous IMEM, pipeline, data fabric,
        // byte-lane tile writes, RAM, and VGA/sprite register slaves.
        wait_for_commit(500000);

        if (dut.memory_subsystem.tile_map.tile_memory[((13*256)+0)/4][7:0]
            !== 8'h41)
            fail("firmware did not build the solid ground tile");
        if (dut.memory_subsystem.tile_map.tile_memory[((13*256)+20)/4][7:0]
            !== 8'h00)
            fail("firmware did not build the first pit");
        if (dut.memory_subsystem.tile_map.tile_memory[((12*256)+58)/4][23:16]
            !== 8'h90)
            fail("firmware did not build the hazard tile");
        if (dut.memory_subsystem.tile_map.tile_memory[((5*256)+90)/4][23:16]
            !== 8'hcb)
            fail("firmware did not build the goal tile");

        // Publish the initial shadow scene and simultaneously let firmware
        // observe a deterministic right-input frame.
        game_input_state = 5'b00010;
        inject_frame_tick();
        initial_player_x = dut.sprite0_x;
        if (initial_player_x !== 16'd32)
            fail("initial player descriptor was not committed at x=32");
        if (!dut.sprite0_attr[0])
            fail("initial player sprite is not enabled");

        wait_for_commit(100000);
        inject_frame_tick();
        if (dut.sprite0_x <= initial_player_x)
            fail("RV32I frame update did not move the player right");
        if (active_game_status[7:0] !== 8'd0)
            fail("game did not remain in PLAY state");
        if (cpu_fault)
            fail("CPU faulted after the first gameplay frame");
        if (instret_count < 32'd1000)
            fail("unexpectedly few retired instructions");
        if (stall_count == 32'd0)
            fail("synchronous-memory wait counter never advanced");

        $display("PASS: v3 full SoC boots firmware, builds level, commits VGA state, and updates player");
        $display("  cycles=%0d instret=%0d stalls=%0d flushes=%0d player_x=%0d",
                 cycle_count, instret_count, stall_count, flush_count,
                 dut.sprite0_x);
        $finish;
    end
endmodule

`default_nettype wire
