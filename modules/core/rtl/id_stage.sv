// id_stage.sv — Instruction Decode (ID) stage.
//
// Reads the 32-bit instruction from the IF/ID pipeline register and:
//   1. Decodes control signals (ctrl_t).
//   2. Reads two source registers from the 32×32 register file.
//   3. Sign-extends the immediate operand.
//
// The register file has two asynchronous read ports and one synchronous
// write port (from WB stage).  x0 is hardwired to zero.
//
// Immediate generation covers all RV32I immediate formats:
//   I-type, S-type, B-type, U-type, J-type.

`include "rv32i_pkg.sv"
import rv32i_pkg::*;

module id_stage (
    input  logic        clk,
    input  logic        rst,

    // Instruction and PC from IF/ID pipeline register
    input  logic [31:0] instr,
    input  logic [31:0] pc_id,

    // Write-back port
    input  logic        wb_reg_write,
    input  logic [4:0]  wb_rd,
    input  logic [31:0] wb_data,

    // Decode outputs
    output logic [4:0]  rs1,
    output logic [4:0]  rs2,
    output logic [4:0]  rd,
    output logic [31:0] rs1_data,
    output logic [31:0] rs2_data,
    output logic [31:0] imm,
    output ctrl_t       ctrl
);

    // ---- Register file (32 × 32-bit) -------------------------------------
    logic [31:0] regfile [1:31];   // x0 is implicit zero

    // Synchronous write
    always_ff @(posedge clk) begin
        if (wb_reg_write && wb_rd != 5'd0)
            regfile[wb_rd] <= wb_data;
    end

    // Asynchronous read (with write-through for WB → ID forwarding)
    assign rs1 = instr[19:15];
    assign rs2 = instr[24:20];
    assign rd  = instr[11:7];

    assign rs1_data = (rs1 == 5'd0) ? 32'd0 :
                      (wb_reg_write && wb_rd == rs1) ? wb_data :
                      regfile[rs1];

    assign rs2_data = (rs2 == 5'd0) ? 32'd0 :
                      (wb_reg_write && wb_rd == rs2) ? wb_data :
                      regfile[rs2];

    // ---- Immediate generator ---------------------------------------------
    wire [6:0] opcode  = instr[6:0];
    wire [2:0] funct3  = instr[14:12];
    wire       funct7_30 = instr[30];

    logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;

    assign imm_i = {{20{instr[31]}}, instr[31:20]};
    assign imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    assign imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    assign imm_u = {instr[31:12], 12'd0};
    assign imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

    always_comb begin
        case (opcode)
            OP_LUI, OP_AUIPC:       imm = imm_u;
            OP_JAL:                  imm = imm_j;
            OP_JALR, OP_LOAD,
            OP_OP_IMM:               imm = imm_i;
            OP_BRANCH:               imm = imm_b;
            OP_STORE:                imm = imm_s;
            default:                 imm = 32'd0;
        endcase
    end

    // ---- Control decoder ------------------------------------------------
    always_comb begin
        ctrl = NOP_CTRL;
        ctrl.funct3 = funct3;

        case (opcode)
            OP_LUI: begin
                ctrl.reg_write = 1'b1;
                ctrl.alu_src   = 1'b1;
                ctrl.lui       = 1'b1;
                ctrl.alu_op    = ALU_LUI;
            end
            OP_AUIPC: begin
                ctrl.reg_write = 1'b1;
                ctrl.alu_src   = 1'b1;
                ctrl.auipc     = 1'b1;
                ctrl.alu_op    = ALU_ADD;
            end
            OP_JAL: begin
                ctrl.reg_write = 1'b1;
                ctrl.jal       = 1'b1;
                ctrl.alu_op    = ALU_ADD;
            end
            OP_JALR: begin
                ctrl.reg_write = 1'b1;
                ctrl.jalr      = 1'b1;
                ctrl.alu_src   = 1'b1;
                ctrl.alu_op    = ALU_ADD;
            end
            OP_BRANCH: begin
                ctrl.branch    = 1'b1;
                // ALU performs comparison; result used for taken decision
                case (funct3)
                    F3_BEQ, F3_BNE: ctrl.alu_op = ALU_SUB;
                    F3_BLT:         ctrl.alu_op = ALU_SLT;
                    F3_BGE:         ctrl.alu_op = ALU_SLT;
                    F3_BLTU:        ctrl.alu_op = ALU_SLTU;
                    F3_BGEU:        ctrl.alu_op = ALU_SLTU;
                    default:        ctrl.alu_op = ALU_SUB;
                endcase
            end
            OP_LOAD: begin
                ctrl.reg_write = 1'b1;
                ctrl.mem_read  = 1'b1;
                ctrl.mem_to_reg = 1'b1;
                ctrl.alu_src   = 1'b1;
                ctrl.alu_op    = ALU_ADD;
            end
            OP_STORE: begin
                ctrl.mem_write = 1'b1;
                ctrl.alu_src   = 1'b1;
                ctrl.alu_op    = ALU_ADD;
            end
            OP_OP_IMM: begin
                ctrl.reg_write = 1'b1;
                ctrl.alu_src   = 1'b1;
                case (funct3)
                    F3_ADD_SUB: ctrl.alu_op = ALU_ADD;
                    F3_SLL:     ctrl.alu_op = ALU_SLL;
                    F3_SLT:     ctrl.alu_op = ALU_SLT;
                    F3_SLTU:    ctrl.alu_op = ALU_SLTU;
                    F3_XOR:     ctrl.alu_op = ALU_XOR;
                    F3_SRL_SRA: ctrl.alu_op = funct7_30 ? ALU_SRA : ALU_SRL;
                    F3_OR:      ctrl.alu_op = ALU_OR;
                    F3_AND:     ctrl.alu_op = ALU_AND;
                    default:    ctrl.alu_op = ALU_ADD;
                endcase
            end
            OP_OP: begin
                ctrl.reg_write = 1'b1;
                case (funct3)
                    F3_ADD_SUB: ctrl.alu_op = funct7_30 ? ALU_SUB : ALU_ADD;
                    F3_SLL:     ctrl.alu_op = ALU_SLL;
                    F3_SLT:     ctrl.alu_op = ALU_SLT;
                    F3_SLTU:    ctrl.alu_op = ALU_SLTU;
                    F3_XOR:     ctrl.alu_op = ALU_XOR;
                    F3_SRL_SRA: ctrl.alu_op = funct7_30 ? ALU_SRA : ALU_SRL;
                    F3_OR:      ctrl.alu_op = ALU_OR;
                    F3_AND:     ctrl.alu_op = ALU_AND;
                    default:    ctrl.alu_op = ALU_ADD;
                endcase
            end
            default: ctrl = NOP_CTRL;
        endcase
    end

endmodule
