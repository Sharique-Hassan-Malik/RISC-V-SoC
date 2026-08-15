/*
 * imem.v — C8 instruction memory (256 × 16-bit ROM).
 *
 * Loaded from "prog.hex" at simulation time via $readmemh.
 * For synthesis the hex file is mapped to iCE40 block RAM or LUTs
 * by the toolchain (Yosys / nextpnr).
 *
 * Asynchronous read (combinational ROM).
 */

module imem (
    input  wire [7:0]  addr,
    output wire [15:0] insn
);

    reg [15:0] mem [0:255];

    initial begin
        $readmemh("prog.hex", mem);
    end

    assign insn = mem[addr];

endmodule
