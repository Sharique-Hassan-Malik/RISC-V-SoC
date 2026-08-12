// rv32i_pkg.sv — RV32I ISA constants and type definitions.
//
// Included by all pipeline stage modules.
// All identifiers are prefixed to avoid name conflicts when used alongside
// other packages.

`ifndef RV32I_PKG_SV
`define RV32I_PKG_SV
package rv32i_pkg;

    // ---- Instruction formats -------------------------------------------
    // Opcode field [6:0]
    localparam logic [6:0] OP_LUI    = 7'b0110111;
    localparam logic [6:0] OP_AUIPC  = 7'b0010111;
    localparam logic [6:0] OP_JAL    = 7'b1101111;
    localparam logic [6:0] OP_JALR   = 7'b1100111;
    localparam logic [6:0] OP_BRANCH = 7'b1100011;
    localparam logic [6:0] OP_LOAD   = 7'b0000011;
    localparam logic [6:0] OP_STORE  = 7'b0100011;
    localparam logic [6:0] OP_OP_IMM = 7'b0010011;
    localparam logic [6:0] OP_OP     = 7'b0110011;
    localparam logic [6:0] OP_MISC_MEM = 7'b0001111;
    localparam logic [6:0] OP_SYSTEM = 7'b1110011;

    // ---- funct3 codes (used in ALU and branch decode) -------------------
    localparam logic [2:0] F3_ADD_SUB = 3'b000;
    localparam logic [2:0] F3_SLL     = 3'b001;
    localparam logic [2:0] F3_SLT     = 3'b010;
    localparam logic [2:0] F3_SLTU    = 3'b011;
    localparam logic [2:0] F3_XOR     = 3'b100;
    localparam logic [2:0] F3_SRL_SRA = 3'b101;
    localparam logic [2:0] F3_OR      = 3'b110;
    localparam logic [2:0] F3_AND     = 3'b111;

    // funct3 for branches
    localparam logic [2:0] F3_BEQ  = 3'b000;
    localparam logic [2:0] F3_BNE  = 3'b001;
    localparam logic [2:0] F3_BLT  = 3'b100;
    localparam logic [2:0] F3_BGE  = 3'b101;
    localparam logic [2:0] F3_BLTU = 3'b110;
    localparam logic [2:0] F3_BGEU = 3'b111;

    // funct3 for loads
    localparam logic [2:0] F3_LB  = 3'b000;
    localparam logic [2:0] F3_LH  = 3'b001;
    localparam logic [2:0] F3_LW  = 3'b010;
    localparam logic [2:0] F3_LBU = 3'b100;
    localparam logic [2:0] F3_LHU = 3'b101;

    // funct3 for stores
    localparam logic [2:0] F3_SB = 3'b000;
    localparam logic [2:0] F3_SH = 3'b001;
    localparam logic [2:0] F3_SW = 3'b010;

    // ---- funct7 bit 30 (SUB / SRA discriminator) -----------------------
    localparam logic F7_SUB_SRA_BIT = 1'b1;   // bit 30 of instruction

    // ---- ALU operation select (internal encoding) -----------------------
    typedef enum logic [3:0] {
        ALU_ADD  = 4'd0,
        ALU_SUB  = 4'd1,
        ALU_SLL  = 4'd2,
        ALU_SLT  = 4'd3,
        ALU_SLTU = 4'd4,
        ALU_XOR  = 4'd5,
        ALU_SRL  = 4'd6,
        ALU_SRA  = 4'd7,
        ALU_OR   = 4'd8,
        ALU_AND  = 4'd9,
        ALU_LUI  = 4'd10,    // pass B (for LUI: result = imm)
        ALU_AUIPC = 4'd11    // A + B where A = PC (handled in EX)
    } alu_op_t;

    // ---- Pipeline control signals ----------------------------------------
    typedef struct packed {
        logic        reg_write;    // write back to register file
        logic        mem_read;     // load instruction
        logic        mem_write;    // store instruction
        logic        mem_to_reg;   // WB mux: 0 = ALU result, 1 = memory data
        logic        branch;       // conditional branch
        logic        jal;          // JAL
        logic        jalr;         // JALR
        logic        alu_src;      // ALU B input: 0 = rs2, 1 = immediate
        logic        lui;          // LUI (ALU_LUI op)
        logic        auipc;        // AUIPC
        alu_op_t     alu_op;
        logic [2:0]  funct3;       // forwarded for load/store width and branch type
    } ctrl_t;

    // NOP control word
    localparam ctrl_t NOP_CTRL = '{
        reg_write:  1'b0,
        mem_read:   1'b0,
        mem_write:  1'b0,
        mem_to_reg: 1'b0,
        branch:     1'b0,
        jal:        1'b0,
        jalr:       1'b0,
        alu_src:    1'b0,
        lui:        1'b0,
        auipc:      1'b0,
        alu_op:     ALU_ADD,
        funct3:     3'b000
    };

endpackage

`endif
