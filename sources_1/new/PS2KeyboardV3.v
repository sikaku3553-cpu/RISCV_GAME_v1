`timescale 1ns/1ps
`default_nettype none

// Receive-only PS/2 keyboard interface. Both external wires pass through
// two flip-flops and an eight-sample digital filter before falling edges are
// accepted. The output is a held-key bitmap suitable for polling through MMIO.
module PS2KeyboardV3 (
    input  wire       clk,
    input  wire       reset,
    input  wire       ps2_clk,
    input  wire       ps2_data,
    output reg  [4:0] keys,
    output reg  [7:0] last_scan_code,
    output reg        scan_valid,
    output reg        parity_error
);
    localparam integer KEY_LEFT    = 0;
    localparam integer KEY_RIGHT   = 1;
    localparam integer KEY_JUMP    = 2;
    localparam integer KEY_DOWN    = 3;
    localparam integer KEY_RESTART = 4;

    (* ASYNC_REG = "TRUE" *) reg ps2_clk_meta;
    (* ASYNC_REG = "TRUE" *) reg ps2_clk_sync;
    (* ASYNC_REG = "TRUE" *) reg ps2_data_meta;
    (* ASYNC_REG = "TRUE" *) reg ps2_data_sync;
    reg [7:0] clk_filter;
    reg [7:0] data_filter;
    reg filtered_clk;
    reg filtered_data;
    reg filtered_clk_d;

    reg [3:0] bit_count;
    reg       start_bit;
    reg [7:0] receive_byte;
    reg       parity_bit;
    reg       extended_code;
    reg       break_code;

    wire ps2_falling = filtered_clk_d && !filtered_clk;
    wire odd_parity_ok = ^{receive_byte, parity_bit};

    always @(posedge clk) begin
        if (reset) begin
            ps2_clk_meta  <= 1'b1;
            ps2_clk_sync  <= 1'b1;
            ps2_data_meta <= 1'b1;
            ps2_data_sync <= 1'b1;
            clk_filter    <= 8'hff;
            data_filter   <= 8'hff;
            filtered_clk  <= 1'b1;
            filtered_data <= 1'b1;
            filtered_clk_d <= 1'b1;
        end else begin
            ps2_clk_meta  <= ps2_clk;
            ps2_clk_sync  <= ps2_clk_meta;
            ps2_data_meta <= ps2_data;
            ps2_data_sync <= ps2_data_meta;

            clk_filter  <= {clk_filter[6:0], ps2_clk_sync};
            data_filter <= {data_filter[6:0], ps2_data_sync};
            if (&clk_filter)
                filtered_clk <= 1'b1;
            else if (~|clk_filter)
                filtered_clk <= 1'b0;
            if (&data_filter)
                filtered_data <= 1'b1;
            else if (~|data_filter)
                filtered_data <= 1'b0;
            filtered_clk_d <= filtered_clk;
        end
    end

    task update_key;
        input integer index;
        begin
            keys[index] <= !break_code;
        end
    endtask

    always @(posedge clk) begin
        scan_valid <= 1'b0;

        if (reset) begin
            bit_count        <= 4'd0;
            start_bit        <= 1'b1;
            receive_byte     <= 8'd0;
            parity_bit       <= 1'b0;
            extended_code    <= 1'b0;
            break_code       <= 1'b0;
            keys             <= 5'd0;
            last_scan_code   <= 8'd0;
            parity_error     <= 1'b0;
        end else if (ps2_falling) begin
            case (bit_count)
                4'd0: begin
                    start_bit <= filtered_data;
                    bit_count <= 4'd1;
                end
                4'd1, 4'd2, 4'd3, 4'd4,
                4'd5, 4'd6, 4'd7, 4'd8: begin
                    receive_byte[bit_count - 1] <= filtered_data;
                    bit_count <= bit_count + 4'd1;
                end
                4'd9: begin
                    parity_bit <= filtered_data;
                    bit_count <= 4'd10;
                end
                default: begin
                    bit_count <= 4'd0;
                    if (!start_bit && filtered_data && odd_parity_ok) begin
                        parity_error   <= 1'b0;
                        last_scan_code <= receive_byte;
                        scan_valid     <= 1'b1;
                        if (receive_byte == 8'he0) begin
                            extended_code <= 1'b1;
                        end else if (receive_byte == 8'hf0) begin
                            break_code <= 1'b1;
                        end else begin
                            if ((extended_code && receive_byte == 8'h6b) ||
                                (!extended_code && receive_byte == 8'h1c))
                                update_key(KEY_LEFT);
                            if ((extended_code && receive_byte == 8'h74) ||
                                (!extended_code && receive_byte == 8'h23))
                                update_key(KEY_RIGHT);
                            if ((extended_code && receive_byte == 8'h75) ||
                                (!extended_code &&
                                 (receive_byte == 8'h1d ||
                                  receive_byte == 8'h29)))
                                update_key(KEY_JUMP);
                            if ((extended_code && receive_byte == 8'h72) ||
                                (!extended_code && receive_byte == 8'h1b))
                                update_key(KEY_DOWN);
                            if (!extended_code &&
                                (receive_byte == 8'h2d ||
                                 receive_byte == 8'h5a))
                                update_key(KEY_RESTART);
                            extended_code <= 1'b0;
                            break_code    <= 1'b0;
                        end
                    end else begin
                        parity_error <= 1'b1;
                    end
                end
            endcase
        end
    end
endmodule

`default_nettype wire
