`timescale 1ns/1ps
`default_nettype none

module tb_v3_platform_io;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg async_reset = 1'b1;
    wire reset;
    reg noisy_button = 1'b0;
    wire clean_button;
    reg ps2_clk = 1'b1;
    reg ps2_data = 1'b1;
    wire [4:0] keys;
    wire [7:0] last_scan_code;
    wire scan_valid;
    wire parity_error;

    ResetSynchronizerV3 reset_sync (
        .clk(clk),
        .async_reset(async_reset),
        .reset(reset)
    );

    DebounceInputV3 #(
        .STABLE_CYCLES(4),
        .COUNTER_BITS(3)
    ) debounce (
        .clk(clk),
        .reset(reset),
        .async_input(noisy_button),
        .debounced(clean_button)
    );

    PS2KeyboardV3 keyboard (
        .clk(clk),
        .reset(reset),
        .ps2_clk(ps2_clk),
        .ps2_data(ps2_data),
        .keys(keys),
        .last_scan_code(last_scan_code),
        .scan_valid(scan_valid),
        .parity_error(parity_error)
    );

    task ps2_bit;
        input value;
        begin
            ps2_data = value;
            ps2_clk = 1'b1;
            repeat (12) @(posedge clk);
            ps2_clk = 1'b0;
            repeat (12) @(posedge clk);
            ps2_clk = 1'b1;
            repeat (12) @(posedge clk);
        end
    endtask

    task ps2_byte;
        input [7:0] value;
        integer i;
        reg odd_parity;
        begin
            odd_parity = ~^value;
            ps2_bit(1'b0);
            for (i = 0; i < 8; i = i + 1)
                ps2_bit(value[i]);
            ps2_bit(odd_parity);
            ps2_bit(1'b1);
            ps2_data = 1'b1;
            repeat (20) @(posedge clk);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        if (!reset)
            $fatal(1, "reset must assert asynchronously");

        @(negedge clk);
        async_reset = 1'b0;
        @(posedge clk);
        if (!reset)
            $fatal(1, "reset released too early after first edge");
        @(posedge clk);
        #1;
        if (reset)
            $fatal(1, "reset did not release synchronously after two edges");

        // A short bounce must not change the conditioned level.
        @(negedge clk); noisy_button = 1'b1;
        @(negedge clk); noisy_button = 1'b0;
        @(negedge clk); noisy_button = 1'b1;
        @(negedge clk); noisy_button = 1'b0;
        repeat (5) @(posedge clk);
        if (clean_button)
            $fatal(1, "debouncer accepted a bouncing transition");

        noisy_button = 1'b1;
        repeat (8) @(posedge clk);
        #1;
        if (!clean_button)
            $fatal(1, "debouncer did not accept a stable high level");

        // Extended right-arrow make and break sequences.
        ps2_byte(8'he0);
        ps2_byte(8'h74);
        if (!keys[1] || parity_error || last_scan_code != 8'h74)
            $fatal(1, "PS/2 right-arrow make was not decoded");
        ps2_byte(8'he0);
        ps2_byte(8'hf0);
        ps2_byte(8'h74);
        if (keys[1] || parity_error || last_scan_code != 8'h74)
            $fatal(1, "PS/2 right-arrow break was not decoded");

        $display("PASS: tb_v3_platform_io (reset release, debounce, PS/2 make/break)");
        $finish;
    end
endmodule

`default_nettype wire

