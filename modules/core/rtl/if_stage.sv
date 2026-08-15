// if_stage.sv — Instruction Fetch (IF) stage.
//
// Maintains the Program Counter and interfaces with the instruction memory.
// Implements a 2-bit saturating counter branch predictor (BHT, 64 entries,
// indexed by PC[7:2]).
//
// Branch resolution:
//   When the EX stage resolves a branch (ex_branch_valid), the predictor
//   is updated and the PC is corrected if the prediction was wrong.
//   Misprediction flushes the IF/ID and ID/EX pipeline registers via
//   `flush_if_id` and `flush_id_ex` signals driven from this stage.
//
// Jump resolution:
//   JAL and JALR targets are computed in EX and redirected here immediately,
//   always flushing the two in-flight instructions.
//
// PC increment: PC + 4 by default (no compressed instructions).

`include "rv32i_pkg.sv"
import rv32i_pkg::*;

module if_stage (
    input  logic        clk,
    input  logic        rst,

    // Stall from hazard unit (load-use)
    input  logic        stall_if,

    // Branch resolution from EX stage
    input  logic        ex_branch_valid,   // a branch instruction resolved
    input  logic        ex_branch_taken,   // actual outcome
    input  logic [31:0] ex_branch_pc,      // PC of the branch instruction
    input  logic [31:0] ex_branch_target,  // branch target address

    // Jump resolution from EX stage
    input  logic        ex_jump_valid,     // JAL / JALR resolved
    input  logic [31:0] ex_jump_target,

    // The prediction that was made for the branch now resolving, carried down
    // the pipeline with it. See `mispredicted` below for why the BHT's current
    // contents cannot be used instead.
    input  logic        ex_predicted_taken,

    // Flush controls (to pipeline registers)
    output logic        flush_if_id,
    output logic        flush_id_ex,

    // PC output (to instruction memory and ID stage)
    output logic [31:0] pc_if,

    // The prediction made for the instruction being fetched this cycle. The
    // core pipelines it alongside the instruction.
    output logic        predict_taken_if,

    // Instruction memory interface
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_data
);

    // ---- 2-bit Saturating Counter BHT (Branch History Table) -------------
    // 64 entries, indexed by PC[7:2] (discards byte-offset bits 1:0).
    // State encoding: 00=Strongly Not Taken, 01=Weakly Not Taken,
    //                 10=Weakly Taken, 11=Strongly Taken.
    // Prediction: taken when state[1] = 1.
    localparam BHT_ENTRIES = 64;
    localparam BHT_IDX_W   = $clog2(BHT_ENTRIES);

    logic [1:0] bht [0:BHT_ENTRIES-1];
    logic [BHT_IDX_W-1:0] bht_idx_fetch;   // index for current PC
    logic [BHT_IDX_W-1:0] bht_idx_update;  // index for resolving branch

    assign bht_idx_fetch  = pc_if[BHT_IDX_W+1:2];
    assign bht_idx_update = ex_branch_pc[BHT_IDX_W+1:2];

    wire predict_taken = bht[bht_idx_fetch][1];

    // ---- Branch target buffer (BTB) — simple direct-mapped cache ---------
    // Stores the last-seen target for each BHT index.
    // Used to predict the target address when predict_taken is asserted.
    logic [31:0] btb [0:BHT_ENTRIES-1];

    // ---- PC register -----------------------------------------------------
    logic [31:0] pc_next;
    logic [31:0] pc_reg;

    always_ff @(posedge clk) begin
        if (rst) begin
            pc_reg <= 32'h0000_0000;
            for (int i = 0; i < BHT_ENTRIES; i++) begin
                bht[i] <= 2'b01;   // initialise to Weakly Not Taken
                btb[i] <= 32'h4;   // harmless default
            end
        end else begin
            // BHT update on branch resolution
            if (ex_branch_valid) begin
                btb[bht_idx_update] <= ex_branch_target;
                if (ex_branch_taken)
                    bht[bht_idx_update] <= (bht[bht_idx_update] == 2'b11)
                                          ? 2'b11 : bht[bht_idx_update] + 1;
                else
                    bht[bht_idx_update] <= (bht[bht_idx_update] == 2'b00)
                                          ? 2'b00 : bht[bht_idx_update] - 1;
            end

            if (!stall_if)
                pc_reg <= pc_next;
        end
    end

    // ---- PC mux ----------------------------------------------------------
    // Priority: jump > misprediction correction > prediction > PC+4
    logic mispredicted;
    // Compare the outcome against the prediction *that was actually made for
    // this branch*, not against the BHT's contents now.
    //
    // Those differ whenever the same branch is in flight more than once, which
    // is exactly what a tight loop does: an earlier iteration resolves and
    // updates the BHT entry while a later iteration is still in the pipeline.
    // Reading the entry at resolution time then says "we predicted taken" about
    // an instruction that was fetched under a not-taken prediction — the
    // mismatch is invisible, no flush happens, and the speculatively fetched
    // instruction commits. The symptom is a single-instruction loop body
    // executing once too many.
    assign mispredicted = ex_branch_valid && (ex_branch_taken != ex_predicted_taken);

    always_comb begin
        if (ex_jump_valid)
            pc_next = ex_jump_target;
        else if (mispredicted)
            pc_next = ex_branch_taken ? ex_branch_target : ex_branch_pc + 4;
        else if (predict_taken)
            pc_next = btb[bht_idx_fetch];
        else
            pc_next = pc_reg + 4;
    end

    // ---- Flush signals ---------------------------------------------------
    // Flush whenever the fetched path was wrong.
    assign flush_if_id = ex_jump_valid || mispredicted;
    assign flush_id_ex = ex_jump_valid || mispredicted;

    // ---- Outputs ---------------------------------------------------------
    assign pc_if           = pc_reg;
    assign imem_addr       = pc_reg;
    assign predict_taken_if = predict_taken;

endmodule
