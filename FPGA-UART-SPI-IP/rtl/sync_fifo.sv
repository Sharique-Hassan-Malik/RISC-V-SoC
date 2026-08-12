// sync_fifo.sv — Parameterized synchronous FIFO.
//
// Single clock domain.  Standard almost-full / almost-empty thresholds
// configurable at elaboration time.
//
// Parameters:
//   WIDTH       Data width in bits.
//   DEPTH       Number of entries (must be a power of two).
//   AFULL_THR   Almost-full threshold: af asserts when count >= AFULL_THR.
//   AEMPTY_THR  Almost-empty threshold: ae asserts when count <= AEMPTY_THR.
//
// Ports:
//   clk, rst    — synchronous reset
//   wr_en       — write enable (ignored when full)
//   wr_data     — write data
//   rd_en       — read enable (ignored when empty); combinational read
//   rd_data     — read data (valid one cycle after rd_en when registered=1)
//   full        — FIFO is full
//   empty       — FIFO is empty
//   almost_full — count >= AFULL_THR
//   almost_empty— count <= AEMPTY_THR
//   count       — current occupancy

`default_nettype none

module sync_fifo #(
    parameter int WIDTH      = 8,
    parameter int DEPTH      = 16,
    parameter int AFULL_THR  = DEPTH - 2,
    parameter int AEMPTY_THR = 2
) (
    input  logic             clk,
    input  logic             rst,

    input  logic             wr_en,
    input  logic [WIDTH-1:0] wr_data,

    input  logic             rd_en,
    output logic [WIDTH-1:0] rd_data,

    output logic             full,
    output logic             empty,
    output logic             almost_full,
    output logic             almost_empty,
    output logic [$clog2(DEPTH):0] count
);

    localparam PTR_W = $clog2(DEPTH);

    logic [WIDTH-1:0] mem [0:DEPTH-1];
    logic [PTR_W:0]   wr_ptr = '0;   // one extra bit for full/empty detection
    logic [PTR_W:0]   rd_ptr = '0;

    assign full         = (count == DEPTH);
    assign empty        = (count == 0);
    assign almost_full  = (count >= AFULL_THR);
    assign almost_empty = (count <= AEMPTY_THR);
    assign count        = wr_ptr - rd_ptr;

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
        end else begin
            if (wr_en && !full) begin
                mem[wr_ptr[PTR_W-1:0]] <= wr_data;
                wr_ptr <= wr_ptr + 1'b1;
            end
            if (rd_en && !empty)
                rd_ptr <= rd_ptr + 1'b1;
        end
    end

    assign rd_data = mem[rd_ptr[PTR_W-1:0]];

endmodule

`default_nettype wire
