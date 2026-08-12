// hazard_unit.sv — Pipeline hazard detection and forwarding control.
//
// ---- Load-use hazard -------------------------------------------------------
// A load followed immediately by an instruction that uses the loaded value
// requires one stall cycle:
//
//   LW x1, 0(x2)   ← load in ID/EX, rd = x1
//   ADD x3, x1, x4  ← uses x1 in ID
//
// Detected by: (EX stage is a load) AND (EX.rd == ID.rs1 OR EX.rd == ID.rs2)
// Action: assert stall_if, stall_id and insert bubble (NOP) into ID/EX.
//
// ---- Data forwarding -------------------------------------------------------
// All other RAW hazards are resolved by forwarding from:
//   MEM/WB:  result of the instruction now in MEM (one cycle old)
//   WB:      result of the instruction now in WB  (two cycles old)
//
// fwd_a / fwd_b for the EX stage ALU inputs:
//   2'b00 — no forward (use ID/EX register file value)
//   2'b01 — forward from MEM stage (MEM/WB.alu_result)
//   2'b10 — forward from WB stage  (WB.data)
//
// MEM forwarding takes priority over WB when both match the same register
// (can happen when two consecutive instructions write the same rd).

`include "rv32i_pkg.sv"
import rv32i_pkg::*;

module hazard_unit (
    // ID/EX register (instruction in EX)
    input  logic       id_ex_mem_read,   // EX stage is a load
    input  logic [4:0] id_ex_rd,

    // ID stage register reads (instruction being decoded)
    input  logic [4:0] id_rs1,
    input  logic [4:0] id_rs2,

    // EX/MEM register (instruction in MEM)
    input  logic       ex_mem_reg_write,
    input  logic [4:0] ex_mem_rd,

    // MEM/WB register (instruction in WB)
    input  logic       mem_wb_reg_write,
    input  logic [4:0] mem_wb_rd,

    // EX stage register reads (for forwarding into EX)
    input  logic [4:0] ex_rs1,
    input  logic [4:0] ex_rs2,

    // Stall control
    output logic       stall_if,
    output logic       stall_id,
    output logic       flush_id_ex_hazard,   // insert bubble on load-use stall

    // Forwarding selects for EX stage
    output logic [1:0] fwd_a,
    output logic [1:0] fwd_b
);

    // ---- Load-use stall --------------------------------------------------
    wire load_use_hazard = id_ex_mem_read &&
                           ((id_ex_rd == id_rs1 && id_rs1 != 5'd0) ||
                            (id_ex_rd == id_rs2 && id_rs2 != 5'd0));

    assign stall_if          = load_use_hazard;
    assign stall_id          = load_use_hazard;
    assign flush_id_ex_hazard = load_use_hazard;

    // ---- Forwarding from MEM stage (priority 1) --------------------------
    wire fwd_a_mem = ex_mem_reg_write && (ex_mem_rd != 5'd0) &&
                     (ex_mem_rd == ex_rs1);
    wire fwd_b_mem = ex_mem_reg_write && (ex_mem_rd != 5'd0) &&
                     (ex_mem_rd == ex_rs2);

    // ---- Forwarding from WB stage (priority 2) ---------------------------
    wire fwd_a_wb  = mem_wb_reg_write && (mem_wb_rd != 5'd0) &&
                     (mem_wb_rd == ex_rs1) && !fwd_a_mem;
    wire fwd_b_wb  = mem_wb_reg_write && (mem_wb_rd != 5'd0) &&
                     (mem_wb_rd == ex_rs2) && !fwd_b_mem;

    assign fwd_a = fwd_a_mem ? 2'b01 :
                   fwd_a_wb  ? 2'b10 : 2'b00;

    assign fwd_b = fwd_b_mem ? 2'b01 :
                   fwd_b_wb  ? 2'b10 : 2'b00;

endmodule
