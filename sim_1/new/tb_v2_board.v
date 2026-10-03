`timescale 1ns/1ps
`default_nettype none

// Board-level regression for the TD8-compatible v2 wrapper.
// CLOCK_HZ=10 and clksel=1 make the 10 Hz enable stay asserted after its
// first setup clock, so eight retired instructions are reached quickly.
module tb_v2_board;
    reg        clk;
    reg        reset;
    reg  [7:0] in;
    reg        clksel;
    wire [7:0] out;
    wire [3:0] clk_ind;
    wire [6:0] seg;
    wire [3:0] an;
    integer errors;
    integer cycles;

    TD4_TOP #(.CLOCK_HZ(10)) dut (
        .clk(clk),
        .reset(reset),
        .in(in),
        .clksel(clksel),
        .out(out),
        .clk_ind(clk_ind),
        .seg(seg),
        .an(an)
    );

    always #5 clk = ~clk;

    initial begin
        clk    = 1'b0;
        reset  = 1'b1;
        in     = 8'h05;
        clksel = 1'b1;
        errors = 0;

        repeat (2) @(posedge clk);
        #1;

        if (out !== 8'h00) begin
            $display("ERROR: reset board out=%h expected=00", out);
            errors = errors + 1;
        end
        if (clk_ind !== 4'h0) begin
            $display("ERROR: reset clk_ind=%h expected=0", clk_ind);
            errors = errors + 1;
        end

        @(negedge clk);
        reset = 1'b0;

        // Pipeline fill and two load-use dependencies consume extra enable
        // cycles. Wait for eight architectural retirements instead of
        // assuming one retirement per enabled edge.
        cycles = 0;
        while ((clk_ind != 4'd8) && (cycles < 64)) begin
            @(posedge clk);
            #1;
            cycles = cycles + 1;
        end
        if (clk_ind != 4'd8)
            $fatal(1, "timeout waiting for eight board retirements");

        // 0x05 XOR 0x5a = 0x5f; shifting left by one produces 0xbe.
        // The demo stores byte 0xbe at RAM byte address 1, loads it with LBU,
        // then writes it to the word-only output MMIO register.
        if (out !== 8'hBE) begin
            $display("ERROR: board out=%h expected=BE", out);
            errors = errors + 1;
        end
        if (seg !== 7'b0000110) begin
            $display("ERROR: SEG7=%b expected active-low encoding for E", seg);
            errors = errors + 1;
        end
        if (an !== 4'b1110) begin
            $display("ERROR: an=%b expected=1110", an);
            errors = errors + 1;
        end
        if (clk_ind !== 4'h8) begin
            $display("ERROR: clk_ind=%h expected=8 retired instructions", clk_ind);
            errors = errors + 1;
        end
        if (dut.implementation.core_fault !== 1'b0) begin
            $display("ERROR: core fault asserted during board demo");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: tb_v2_board");
        else
            $fatal(1, "FAIL: tb_v2_board errors=%0d", errors);
        $finish;
    end

    initial begin
        #2000;
        $fatal(1, "TIMEOUT: tb_v2_board");
    end
endmodule

`default_nettype wire
