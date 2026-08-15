// riscv_core.sv — RV32I 5-stage pipelined RISC-V core top level.
//
// Pipeline stages: IF → ID → EX → MEM → WB
// Features:
//   Full RV32I base integer instruction set.
//   5-stage in-order pipeline with data forwarding.
//   Load-use stall (1 cycle bubble inserted).
//   2-bit saturating counter branch predictor (64-entry BHT + BTB).
//   Misprediction flush (2-cycle penalty on mispredicted branch).
//   Performance counters: cycles, instructions retired, branch count,
//                          misprediction count, stall cycles.
//
// Memory interfaces:
//   Instruction memory: 32-bit word-addressed, synchronous read (1-cycle latency).
//   Data memory: 32-bit, byte-enable write, synchronous read (1-cycle latency).
//
// Reset vector: 0x00000000.

`include "rv32i_pkg.sv"
import rv32i_pkg::*;

`default_nettype none

module riscv_core (
    input  logic        clk,
    input  logic        rst,

    // Instruction memory
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_data,

    // Data memory
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic [3:0]  dmem_be,
    output logic        dmem_we,
    input  logic [31:0] dmem_rdata,

    // Performance counter outputs
    output logic [63:0] perf_cycles,
    output logic [63:0] perf_instret,
    output logic [31:0] perf_branches,
    output logic [31:0] perf_mispredicts,
    output logic [31:0] perf_stall_cycles
);

    // ========== Pipeline registers =========================================

    // IF/ID
    logic [31:0] ifid_pc;
    logic [31:0] ifid_instr;

    // ID/EX
    ctrl_t       idex_ctrl;
    logic [31:0] idex_pc;
    logic [4:0]  idex_rs1, idex_rs2, idex_rd;
    logic [31:0] idex_rs1_data, idex_rs2_data;
    logic [31:0] idex_imm;

    // EX/MEM
    ctrl_t       exmem_ctrl;
    logic [31:0] exmem_alu_result;
    logic [31:0] exmem_rs2_data;
    logic [4:0]  exmem_rd;
    logic [31:0] exmem_pc_plus4;

    // MEM/WB
    ctrl_t       memwb_ctrl;
    logic [31:0] memwb_alu_result;
    logic [31:0] memwb_mem_data;
    logic [4:0]  memwb_rd;

    // ========== Hazard / forwarding signals ================================

    logic        stall_if, stall_id;
    logic        flush_if_id, flush_id_ex;
    logic        flush_id_ex_hazard;
    logic [1:0]  fwd_a, fwd_b;

    // Branch / jump resolution
    logic        ex_branch_valid, ex_branch_taken;
    logic [31:0] ex_branch_pc, ex_branch_target;
    logic        ex_jump_valid;
    logic [31:0] ex_jump_target;

    // WB
    logic        wb_reg_write;
    logic [4:0]  wb_rd;
    logic [31:0] wb_data;

    // ========== IF stage ===================================================

    logic [31:0] pc_if;
    logic        flush_if_id_bp, flush_id_ex_bp;

    if_stage u_if (
        .clk(clk), .rst(rst),
        .stall_if(stall_if),
        .ex_branch_valid(ex_branch_valid),
        .ex_branch_taken(ex_branch_taken),
        .ex_branch_pc(ex_branch_pc),
        .ex_branch_target(ex_branch_target),
        .ex_jump_valid(ex_jump_valid),
        .ex_jump_target(ex_jump_target),
        .ex_predicted_taken(idex_predicted),
        .flush_if_id(flush_if_id_bp),
        .flush_id_ex(flush_id_ex_bp),
        .pc_if(pc_if),
        .predict_taken_if(predict_taken_if),
        .imem_addr(imem_addr),
        .imem_data(imem_data)
    );

    // Combine flush sources (branch predictor + hazard)
    assign flush_if_id = flush_if_id_bp;
    assign flush_id_ex = flush_id_ex_bp || flush_id_ex_hazard;

    // ========== IF/ID pipeline register ====================================

    // The instruction memory is a synchronous (1-cycle) read: the word for the
    // address presented on cycle T arrives on imem_data at T+1. So the PC that
    // belongs to the instruction now on imem_data is the fetch PC from one cycle
    // ago. Track it in pc_fetch and pair THAT with the instruction; using the
    // current pc_if would tag every instruction with the next PC (+4), corrupting
    // PC-relative branch targets.
    logic [31:0] pc_fetch;
    // The prediction is made for pc_if, so it has to be delayed by exactly the
    // same cycle as the PC to stay paired with its instruction.
    logic        predict_taken_if;
    logic        predicted_fetch;
    logic        ifid_predicted, idex_predicted;

    always_ff @(posedge clk) begin
        if (rst) begin
            pc_fetch        <= 32'd0;
            predicted_fetch <= 1'b0;
        end else if (!stall_id) begin
            pc_fetch        <= pc_if;
            predicted_fetch <= predict_taken_if;
        end
    end

    always_ff @(posedge clk) begin
        if (rst || flush_if_id) begin
            ifid_pc        <= 32'd0;
            ifid_instr     <= 32'h0000_0013;   // NOP
            ifid_predicted <= 1'b0;
        end else if (!stall_id) begin
            ifid_pc        <= pc_fetch;
            ifid_instr     <= imem_data;
            ifid_predicted <= predicted_fetch;
        end
    end

    // ========== ID stage ===================================================

    id_stage u_id (
        .clk(clk), .rst(rst),
        .instr(ifid_instr),
        .pc_id(ifid_pc),
        .wb_reg_write(wb_reg_write),
        .wb_rd(wb_rd),
        .wb_data(wb_data),
        .rs1(idex_rs1_w), .rs2(idex_rs2_w), .rd(idex_rd_w),
        .rs1_data(id_rs1_data), .rs2_data(id_rs2_data),
        .imm(id_imm),
        .ctrl(id_ctrl)
    );

    // Intermediate wires from ID
    logic [4:0]  idex_rs1_w, idex_rs2_w, idex_rd_w;
    logic [31:0] id_rs1_data, id_rs2_data, id_imm;
    ctrl_t       id_ctrl;

    // ========== ID/EX pipeline register ====================================

    always_ff @(posedge clk) begin
        if (rst || flush_id_ex) begin
            idex_ctrl     <= NOP_CTRL;
            // A flushed slot carries no prediction; leaving the old one would
            // let a killed branch's prediction judge the next real one.
            idex_predicted <= 1'b0;
            idex_pc       <= 32'd0;
            idex_rs1      <= 5'd0;
            idex_rs2      <= 5'd0;
            idex_rd       <= 5'd0;
            idex_rs1_data <= 32'd0;
            idex_rs2_data <= 32'd0;
            idex_imm      <= 32'd0;
        end else begin
            idex_ctrl     <= id_ctrl;
            idex_predicted <= ifid_predicted;
            idex_pc       <= ifid_pc;
            idex_rs1      <= idex_rs1_w;
            idex_rs2      <= idex_rs2_w;
            idex_rd       <= idex_rd_w;
            idex_rs1_data <= id_rs1_data;
            idex_rs2_data <= id_rs2_data;
            idex_imm      <= id_imm;
        end
    end

    // ========== EX stage ===================================================

    logic [31:0] ex_alu_result, ex_rs2_fwd;
    ctrl_t       ex_ctrl_out;
    logic [4:0]  ex_rd_out;
    logic [31:0] ex_pc_plus4;

    ex_stage u_ex (
        .clk(clk), .rst(rst),
        .ctrl(idex_ctrl),
        .pc_ex(idex_pc),
        .rs1_ex(idex_rs1), .rs2_ex(idex_rs2), .rd_ex(idex_rd),
        .rs1_data(idex_rs1_data), .rs2_data(idex_rs2_data),
        .imm(idex_imm),
        .fwd_a(fwd_a), .fwd_b(fwd_b),
        .fwd_mem_val(exmem_alu_result),
        .fwd_wb_val(wb_data),
        .ex_branch_valid(ex_branch_valid),
        .ex_branch_taken(ex_branch_taken),
        .ex_branch_pc(ex_branch_pc),
        .ex_branch_target(ex_branch_target),
        .ex_jump_valid(ex_jump_valid),
        .ex_jump_target(ex_jump_target),
        .alu_result(ex_alu_result),
        .rs2_fwd(ex_rs2_fwd),
        .ctrl_out(ex_ctrl_out),
        .rd_out(ex_rd_out),
        .pc_plus4(ex_pc_plus4)
    );

    // ========== EX/MEM pipeline register ===================================

    always_ff @(posedge clk) begin
        if (rst) begin
            exmem_ctrl       <= NOP_CTRL;
            exmem_alu_result <= 32'd0;
            exmem_rs2_data   <= 32'd0;
            exmem_rd         <= 5'd0;
            exmem_pc_plus4   <= 32'd0;
        end else begin
            exmem_ctrl       <= ex_ctrl_out;
            exmem_alu_result <= ex_alu_result;
            exmem_rs2_data   <= ex_rs2_fwd;
            exmem_rd         <= ex_rd_out;
            exmem_pc_plus4   <= ex_pc_plus4;
        end
    end

    // ========== MEM stage ==================================================

    logic [31:0] mem_read_data, mem_alu_result_out;
    ctrl_t       mem_ctrl_out;
    logic [4:0]  mem_rd_out;

    mem_stage u_mem (
        .clk(clk), .rst(rst),
        .ctrl(exmem_ctrl),
        .alu_result(exmem_alu_result),
        .rs2_data(exmem_rs2_data),
        .rd(exmem_rd),
        .pc_plus4(exmem_pc_plus4),
        .dmem_addr(dmem_addr),
        .dmem_wdata(dmem_wdata),
        .dmem_be(dmem_be),
        .dmem_we(dmem_we),
        .dmem_rdata(dmem_rdata),
        .mem_read_data(mem_read_data),
        .alu_result_out(mem_alu_result_out),
        .ctrl_out(mem_ctrl_out),
        .rd_out(mem_rd_out)
    );

    // ========== MEM/WB pipeline register ===================================

    always_ff @(posedge clk) begin
        if (rst) begin
            memwb_ctrl       <= NOP_CTRL;
            memwb_alu_result <= 32'd0;
            memwb_mem_data   <= 32'd0;
            memwb_rd         <= 5'd0;
        end else begin
            memwb_ctrl       <= mem_ctrl_out;
            memwb_alu_result <= mem_alu_result_out;
            memwb_mem_data   <= mem_read_data;
            memwb_rd         <= mem_rd_out;
        end
    end

    // ========== WB stage ===================================================

    wb_stage u_wb (
        .ctrl(memwb_ctrl),
        .alu_result(memwb_alu_result),
        .mem_read_data(memwb_mem_data),
        .rd(memwb_rd),
        .reg_write(wb_reg_write),
        .rd_out(wb_rd),
        .wb_data(wb_data)
    );

    // ========== Hazard unit ================================================

    hazard_unit u_haz (
        .id_ex_mem_read(idex_ctrl.mem_read),
        .id_ex_rd(idex_rd),
        .id_rs1(idex_rs1_w), .id_rs2(idex_rs2_w),
        .ex_mem_reg_write(exmem_ctrl.reg_write),
        .ex_mem_rd(exmem_rd),
        .mem_wb_reg_write(memwb_ctrl.reg_write),
        .mem_wb_rd(memwb_rd),
        .ex_rs1(idex_rs1), .ex_rs2(idex_rs2),
        .stall_if(stall_if),
        .stall_id(stall_id),
        .flush_id_ex_hazard(flush_id_ex_hazard),
        .fwd_a(fwd_a), .fwd_b(fwd_b)
    );

    // ========== Performance counters =======================================

    always_ff @(posedge clk) begin
        if (rst) begin
            perf_cycles       <= 64'd0;
            perf_instret      <= 64'd0;
            perf_branches     <= 32'd0;
            perf_mispredicts  <= 32'd0;
            perf_stall_cycles <= 32'd0;
        end else begin
            perf_cycles <= perf_cycles + 1;

            // Instruction retired = WB has a non-NOP control word
            if (memwb_ctrl.reg_write || memwb_ctrl.mem_write ||
                memwb_ctrl.branch)
                perf_instret <= perf_instret + 1;

            if (ex_branch_valid)
                perf_branches <= perf_branches + 1;

            if (ex_branch_valid && (ex_branch_taken != |perf_mispredicts[31:31]))
                // simplified: count resolved mispredictions
                perf_mispredicts <= perf_mispredicts;   // updated below

            if (flush_if_id_bp)
                perf_mispredicts <= perf_mispredicts + 1;

            if (stall_if)
                perf_stall_cycles <= perf_stall_cycles + 1;
        end
    end

endmodule

`default_nettype wire
