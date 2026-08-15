/*
 * regfile.v — C8 register file.
 *
 * 8 × 8-bit registers (R0–R7).
 * R0 is hardwired to 0x00: writes to R0 are silently discarded.
 *
 * Synchronous write (rising edge), asynchronous read.
 */

module regfile (
    input  wire       clk,
    input  wire       wr_en,
    input  wire [2:0] wr_addr,
    input  wire [7:0] wr_data,
    input  wire [2:0] rd_addr1,
    input  wire [2:0] rd_addr2,
    output wire [7:0] rd_data1,
    output wire [7:0] rd_data2
);

    reg [7:0] regs [0:7];

    /* Asynchronous read; R0 always returns 0 */
    assign rd_data1 = (rd_addr1 == 3'd0) ? 8'h00 : regs[rd_addr1];
    assign rd_data2 = (rd_addr2 == 3'd0) ? 8'h00 : regs[rd_addr2];

    always @(posedge clk) begin
        if (wr_en && wr_addr != 3'd0)
            regs[wr_addr] <= wr_data;
    end

    /* Initialise all registers to 0 on synthesis */
    integer i;
    initial begin
        for (i = 0; i < 8; i = i + 1)
            regs[i] = 8'h00;
    end

endmodule
