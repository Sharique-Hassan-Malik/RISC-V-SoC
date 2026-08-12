// memories.sv — Instruction and data memory models for simulation.
//
// Both memories are synthesisable synchronous single-port SRAMs but are
// sized for simulation only (4 KB each).  For hardware replace with
// block-RAM primitives or external SRAM.
//
// Instruction memory:
//   Read-only during normal operation.
//   Initialised from a $readmemh file (program.hex).
//
// Data memory:
//   Supports byte-enable writes (4 × 1-byte enables).
//   Synchronous read (1-cycle latency — the MEM stage accounts for this).

module imem #(
    parameter DEPTH = 1024   // 4 KB of instructions
) (
    input  logic        clk,
    input  logic [31:0] addr,
    output logic [31:0] data
);
    logic [31:0] mem [0:DEPTH-1];

    initial begin
        for (int i = 0; i < DEPTH; i++) mem[i] = 32'h0000_0013;  // NOP (ADDI x0,x0,0)
        $readmemh("program.hex", mem);
    end

    // Synchronous read; word-addressed (ignore byte offset bits 1:0)
    always_ff @(posedge clk)
        data <= mem[addr[31:2] % DEPTH];

endmodule


module dmem #(
    parameter DEPTH = 1024   // 4 KB of data
) (
    input  logic        clk,
    input  logic [31:0] addr,
    input  logic [31:0] wdata,
    input  logic [3:0]  be,
    input  logic        we,
    output logic [31:0] rdata
);
    logic [7:0] mem [0:DEPTH*4-1];

    initial begin
        for (int i = 0; i < DEPTH*4; i++) mem[i] = 8'h00;
    end

    // Byte-enable write
    always_ff @(posedge clk) begin
        if (we) begin
            if (be[0]) mem[{addr[31:2], 2'b00}]     <= wdata[ 7: 0];
            if (be[1]) mem[{addr[31:2], 2'b01}]     <= wdata[15: 8];
            if (be[2]) mem[{addr[31:2], 2'b10}]     <= wdata[23:16];
            if (be[3]) mem[{addr[31:2], 2'b11}]     <= wdata[31:24];
        end
    end

    // Synchronous read (word)
    always_ff @(posedge clk)
        rdata <= {mem[{addr[31:2], 2'b11}],
                  mem[{addr[31:2], 2'b10}],
                  mem[{addr[31:2], 2'b01}],
                  mem[{addr[31:2], 2'b00}]};

endmodule
