/*
 * dmem.v — C8 data memory (256 × 8-bit synchronous-write RAM).
 *
 * Read is asynchronous (combinational).
 * Write is synchronous on rising edge when wr_en is asserted.
 */

module dmem (
    input  wire       clk,
    input  wire       wr_en,
    input  wire [7:0] addr,
    input  wire [7:0] wr_data,
    output wire [7:0] rd_data
);

    reg [7:0] mem [0:255];

    assign rd_data = mem[addr];

    always @(posedge clk) begin
        if (wr_en)
            mem[addr] <= wr_data;
    end

    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1)
            mem[i] = 8'h00;
    end

endmodule
