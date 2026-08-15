// debounce.v — Synchronous button debouncer.
//
// A 3-stage shift register clocked at CLKDIV_HZ samples the raw button
// input.  The output is set high only when all three stages are high
// (stable pressed) and cleared only when all three are low (stable released).
// This gives approximately 3 / SAMPLE_HZ of hysteresis.
//
// At the default SAMPLE_HZ = 1000 (1 kHz): 3 ms debounce window.
// The SAMPLE_HZ divider is computed from CLK_HZ.

module debounce #(
    parameter CLK_HZ    = 25_000_000,
    parameter SAMPLE_HZ = 1_000
) (
    input  wire clk,
    input  wire rst,
    input  wire btn_raw,
    output reg  btn_out
);

    localparam DIVIDER = CLK_HZ / SAMPLE_HZ;

    reg [$clog2(DIVIDER)-1:0] div_cnt = 0;
    reg                        sample_tick = 1'b0;
    reg [2:0]                  sr = 3'b0;

    always @(posedge clk) begin
        if (rst) begin
            div_cnt    <= 0;
            sample_tick <= 1'b0;
            sr         <= 3'b0;
            btn_out    <= 1'b0;
        end else begin
            if (div_cnt == DIVIDER - 1) begin
                div_cnt     <= 0;
                sample_tick <= 1'b1;
            end else begin
                div_cnt     <= div_cnt + 1;
                sample_tick <= 1'b0;
            end

            if (sample_tick)
                sr <= {sr[1:0], btn_raw};

            if (sr == 3'b111)
                btn_out <= 1'b1;
            else if (sr == 3'b000)
                btn_out <= 1'b0;
        end
    end

endmodule
