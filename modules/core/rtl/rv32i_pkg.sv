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

    // ---- SYSTEM (opcode 0x73) -------------------------------------------
    // funct3 == 000 selects a privileged operation, named by funct12; every
    // other funct3 is a CSR access. See docs/traps.md.
    localparam logic [2:0] F3_PRIV   = 3'b000;
    localparam logic [2:0] F3_CSRRW  = 3'b001;
    localparam logic [2:0] F3_CSRRS  = 3'b010;
    localparam logic [2:0] F3_CSRRC  = 3'b011;
    localparam logic [2:0] F3_CSRRWI = 3'b101;
    localparam logic [2:0] F3_CSRRSI = 3'b110;
    localparam logic [2:0] F3_CSRRCI = 3'b111;

    localparam logic [11:0] F12_ECALL  = 12'h000;
    localparam logic [11:0] F12_EBREAK = 12'h001;
    localparam logic [11:0] F12_MRET   = 12'h302;

    // ---- Machine-mode CSR addresses --------------------------------------
    localparam logic [11:0] CSR_MSTATUS  = 12'h300;
    localparam logic [11:0] CSR_MIE      = 12'h304;
    localparam logic [11:0] CSR_MTVEC    = 12'h305;
    localparam logic [11:0] CSR_MSCRATCH = 12'h340;
    localparam logic [11:0] CSR_MEPC     = 12'h341;
    localparam logic [11:0] CSR_MCAUSE   = 12'h342;
    localparam logic [11:0] CSR_MTVAL    = 12'h343;
    localparam logic [11:0] CSR_MIP      = 12'h344;
    localparam logic [11:0] CSR_MCYCLE   = 12'hB00;
    localparam logic [11:0] CSR_MINSTRET = 12'hB02;

    // ---- Bit positions within mstatus / mie / mip -------------------------
    localparam int MSTATUS_MIE_BIT  = 3;
    localparam int MSTATUS_MPIE_BIT = 7;
    localparam int IRQ_SOFT_BIT     = 3;    // MSIE / MSIP
    localparam int IRQ_TIMER_BIT    = 7;    // MTIE / MTIP
    localparam int IRQ_EXT_BIT      = 11;   // MEIE / MEIP

    // ---- Trap causes ------------------------------------------------------
    localparam logic [31:0] CAUSE_IRQ_SOFT  = 32'h8000_0003;
    localparam logic [31:0] CAUSE_IRQ_TIMER = 32'h8000_0007;
    localparam logic [31:0] CAUSE_IRQ_EXT   = 32'h8000_000B;
    localparam logic [31:0] CAUSE_ECALL_M   = 32'h0000_0008;
    localparam logic [31:0] CAUSE_BREAK     = 32'h0000_0003;

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
        // `valid` distinguishes a real instruction from a flushed slot. A trap
        // must not be taken on a bubble: mepc would name the zeroed PC of a
        // killed instruction, and mret would return into nothing.
        logic        valid;
        logic        is_csr;       // a CSR read/modify/write
        logic        csr_imm;      // operand is uimm[4:0] rather than rs1
        logic        is_ecall;
        logic        is_ebreak;
        logic        is_mret;
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
        funct3:     3'b000,
        valid:      1'b0,
        is_csr:     1'b0,
        csr_imm:    1'b0,
        is_ecall:   1'b0,
        is_ebreak:  1'b0,
        is_mret:    1'b0
    };

    // ---- Load alignment and extension ------------------------------------
    //
    // A pure function of the returned word, the funct3 and the two low address
    // bits. It lives here rather than in mem_stage because the data memory is
    // synchronous: the word for the address issued in MEM does not arrive
    // until WB, so the formatting has to happen a stage later than the access.
    function automatic logic [31:0] load_extend(
        input logic [2:0]  funct3,
        input logic [1:0]  offset,
        input logic [31:0] word
    );
        case (funct3)
            F3_LB: case (offset)
                2'b00: load_extend = {{24{word[ 7]}}, word[ 7: 0]};
                2'b01: load_extend = {{24{word[15]}}, word[15: 8]};
                2'b10: load_extend = {{24{word[23]}}, word[23:16]};
                2'b11: load_extend = {{24{word[31]}}, word[31:24]};
            endcase
            F3_LBU: case (offset)
                2'b00: load_extend = {24'd0, word[ 7: 0]};
                2'b01: load_extend = {24'd0, word[15: 8]};
                2'b10: load_extend = {24'd0, word[23:16]};
                2'b11: load_extend = {24'd0, word[31:24]};
            endcase
            F3_LH:  load_extend = offset[1] ? {{16{word[31]}}, word[31:16]}
                                            : {{16{word[15]}}, word[15: 0]};
            F3_LHU: load_extend = offset[1] ? {16'd0, word[31:16]}
                                            : {16'd0, word[15: 0]};
            default: load_extend = word;      // F3_LW
        endcase
    endfunction

endpackage

`endif
