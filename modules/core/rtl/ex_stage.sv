// ex_stage.sv — Execute (EX) stage.
//
// Performs the ALU operation, evaluates branch conditions and computes
// jump/branch target addresses.  Data forwarding from MEM and WB stages
// is applied here before the ALU inputs.
//
// Forwarding logic (from hazard_unit.sv):
//   fwd_a / fwd_b:
//     2'b00 = register file value (from ID/EX register)
//     2'b01 = MEM/WB forwarded value (ALU result from MEM stage)
//     2'b10 = WB forwarded value    (result from WB stage)

`include "rv32i_pkg.sv"
import rv32i_pkg::*;

module ex_stage (
    input  logic        clk,
    input  logic        rst,

    // From ID/EX pipeline register
    input  ctrl_t       ctrl,
    input  logic [31:0] pc_ex,
    input  logic [4:0]  rs1_ex,
    input  logic [4:0]  rs2_ex,
    input  logic [4:0]  rd_ex,
    input  logic [31:0] rs1_data,
    input  logic [31:0] rs2_data,
    input  logic [31:0] imm,

    // Data forwarding from MEM and WB stages
    input  logic [1:0]  fwd_a,
    input  logic [1:0]  fwd_b,
    input  logic [31:0] fwd_mem_val,   // ALU result from MEM stage
    input  logic [31:0] fwd_wb_val,    // result from WB stage

    // Branch / jump resolution (to IF stage)
    output logic        ex_branch_valid,
    output logic        ex_branch_taken,
    output logic [31:0] ex_branch_pc,
    output logic [31:0] ex_branch_target,
    output logic        ex_jump_valid,
    output logic [31:0] ex_jump_target,

    // Outputs to MEM/WB pipeline register
    output logic [31:0] alu_result,
    output logic [31:0] rs2_fwd,       // forwarded store data
    output ctrl_t       ctrl_out,
    output logic [4:0]  rd_out,
    output logic [31:0] pc_plus4       // for JAL/JALR return address
);

    // ---- Forwarding muxes ------------------------------------------------
    logic [31:0] alu_a, alu_b_reg;

    always_comb begin
        case (fwd_a)
            2'b01:  alu_a = fwd_mem_val;
            2'b10:  alu_a = fwd_wb_val;
            default: alu_a = rs1_data;
        endcase
        case (fwd_b)
            2'b01:  alu_b_reg = fwd_mem_val;
            2'b10:  alu_b_reg = fwd_wb_val;
            default: alu_b_reg = rs2_data;
        endcase
    end

    // rs2_fwd carries the (possibly forwarded) store data to MEM
    assign rs2_fwd = alu_b_reg;

    // ALU second operand: immediate or register
    wire [31:0] alu_b = ctrl.alu_src ? imm : alu_b_reg;

    // AUIPC: ALU_A is PC, not rs1
    wire [31:0] alu_operand_a = ctrl.auipc ? pc_ex : alu_a;

    // ---- ALU -------------------------------------------------------------
    logic [31:0] alu_out;

    always_comb begin
        case (ctrl.alu_op)
            ALU_ADD:  alu_out = alu_operand_a + alu_b;
            ALU_SUB:  alu_out = alu_operand_a - alu_b;
            ALU_SLL:  alu_out = alu_operand_a << alu_b[4:0];
            ALU_SLT:  alu_out = ($signed(alu_operand_a) < $signed(alu_b)) ? 32'd1 : 32'd0;
            ALU_SLTU: alu_out = (alu_operand_a < alu_b) ? 32'd1 : 32'd0;
            ALU_XOR:  alu_out = alu_operand_a ^ alu_b;
            ALU_SRL:  alu_out = alu_operand_a >> alu_b[4:0];
            ALU_SRA:  alu_out = $signed(alu_operand_a) >>> alu_b[4:0];
            ALU_OR:   alu_out = alu_operand_a | alu_b;
            ALU_AND:  alu_out = alu_operand_a & alu_b;
            ALU_LUI:  alu_out = alu_b;                   // LUI: result = imm
            default:  alu_out = 32'd0;
        endcase
    end

    // (alu_result is assigned once below, after the JAL/JALR return-address mux;
    //  a second driver here would create a multi-driver conflict.)

    // ---- Branch condition evaluation ------------------------------------
    logic branch_cond;

    always_comb begin
        case (ctrl.funct3)
            F3_BEQ:  branch_cond = (alu_out == 32'd0);
            F3_BNE:  branch_cond = (alu_out != 32'd0);
            F3_BLT:  branch_cond = (alu_out == 32'd1);   // ALU_SLT
            F3_BGE:  branch_cond = (alu_out == 32'd0);   // !SLT
            F3_BLTU: branch_cond = (alu_out == 32'd1);   // ALU_SLTU
            F3_BGEU: branch_cond = (alu_out == 32'd0);   // !SLTU
            default: branch_cond = 1'b0;
        endcase
    end

    // ---- Branch / jump target -------------------------------------------
    wire [31:0] branch_target = pc_ex + imm;          // PC-relative branches
    wire [31:0] jalr_target   = (alu_a + imm) & ~32'd1; // JALR: rs1 + imm, clear bit 0

    assign ex_branch_valid  = ctrl.branch;
    assign ex_branch_taken  = branch_cond;
    assign ex_branch_pc     = pc_ex;
    assign ex_branch_target = branch_target;

    assign ex_jump_valid  = ctrl.jal || ctrl.jalr;
    assign ex_jump_target = ctrl.jalr ? jalr_target : branch_target;

    // ---- JAL/JALR return address ----------------------------------------
    assign pc_plus4 = pc_ex + 4;

    // JAL/JALR write PC+4 to rd
    assign alu_result = (ctrl.jal || ctrl.jalr) ? pc_plus4 : alu_out;

    assign ctrl_out = ctrl;
    assign rd_out   = rd_ex;

endmodule
