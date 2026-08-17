// mem_stage.sv — Memory Access (MEM) stage.
//
// Issues read/write requests to the data memory.
// Handles byte (LB/LBU/SB), halfword (LH/LHU/SH) and word (LW/SW) access.
//
// The data memory is modelled as a synchronous read port (result available
// on the next clock).  This module presents the address and write data to
// the memory combinationally; the memory register returns data one cycle
// later, which is consumed in the WB stage.
//
// Byte-enable logic for stores:
//   SB: write only the addressed byte (be = 4'b0001 shifted by addr[1:0])
//   SH: write addressed halfword (be = 4'b0011 shifted by addr[1] * 2)
//   SW: write all four bytes     (be = 4'b1111)
//
// Load extension (applied combinationally after memory read):
//   LB / LH: sign-extend
//   LBU / LHU: zero-extend

`include "rv32i_pkg.sv"
import rv32i_pkg::*;

module mem_stage (
    input  logic        clk,
    input  logic        rst,

    // From EX/MEM pipeline register
    input  ctrl_t       ctrl,
    input  logic [31:0] alu_result,   // effective address for loads/stores
    input  logic [31:0] rs2_data,     // store data
    input  logic [4:0]  rd,
    input  logic [31:0] pc_plus4,

    // Data memory interface
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic [3:0]  dmem_be,      // byte enables
    output logic        dmem_we,

    // Outputs to MEM/WB pipeline register
    output logic [31:0] alu_result_out,
    output ctrl_t       ctrl_out,
    output logic [4:0]  rd_out
);

    // ---- Store byte-enable and write data --------------------------------
    always_comb begin
        dmem_addr  = alu_result;
        dmem_we    = ctrl.mem_write;
        dmem_wdata = 32'd0;
        dmem_be    = 4'b0000;

        if (ctrl.mem_write) begin
            case (ctrl.funct3)
                F3_SB: begin
                    dmem_be    = 4'b0001 << alu_result[1:0];
                    dmem_wdata = {4{rs2_data[7:0]}};
                end
                F3_SH: begin
                    dmem_be    = alu_result[1] ? 4'b1100 : 4'b0011;
                    dmem_wdata = {2{rs2_data[15:0]}};
                end
                F3_SW: begin
                    dmem_be    = 4'b1111;
                    dmem_wdata = rs2_data;
                end
                default: begin
                    dmem_be    = 4'b1111;
                    dmem_wdata = rs2_data;
                end
            endcase
        end
    end

    // The load's data is NOT read here.
    //
    // The data memory is synchronous: the address issued this cycle returns
    // its word on `dmem_rdata` in the *next* cycle, when the load has already
    // moved to WB. Reading it here samples whatever the previous access left
    // on the bus — which is why a load preceded by an access to a different
    // address returned the wrong word, and why the core's own load test never
    // saw it: that test loads from address 0 preceded by NOPs, whose
    // dmem_addr is also 0, so the stale word is the right one by accident.
    //
    // riscv_core formats it in WB with rv32i_pkg::load_extend.

    assign alu_result_out = alu_result;
    assign ctrl_out       = ctrl;
    assign rd_out         = rd;

endmodule
