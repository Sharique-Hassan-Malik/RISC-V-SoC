// wb_stage.sv — Write-Back (WB) stage.
//
// Selects between the ALU result and the memory read data for writing
// back to the register file.  The actual register file write port is
// in id_stage.sv; this module provides the select and the data to it.
//
// For JAL/JALR the ALU result already holds PC+4 (set in ex_stage).

`include "rv32i_pkg.sv"
import rv32i_pkg::*;

module wb_stage (
    input  ctrl_t       ctrl,
    input  logic [31:0] alu_result,
    input  logic [31:0] mem_read_data,
    input  logic [4:0]  rd,

    output logic        reg_write,
    output logic [4:0]  rd_out,
    output logic [31:0] wb_data
);

    assign reg_write = ctrl.reg_write;
    assign rd_out    = rd;
    assign wb_data   = ctrl.mem_to_reg ? mem_read_data : alu_result;

endmodule
