/*
 * cpu.v — C8 single-cycle CPU core.
 *
 * One register file, one ALU, one instruction ROM, one data RAM.
 * All combinational decode and datapath; state registers (PC, SP, FLAGS)
 * update on the rising clock edge.
 *
 * halt is asserted when HLT executes and PC freezes.
 * debug_reg_data exposes any register by debug_reg_sel for testbenches.
 */

`include "alu.v"
`include "regfile.v"
`include "imem.v"
`include "dmem.v"

module cpu (
    input  wire       clk,
    input  wire       rst_n,
    output reg        halt,
    output wire [7:0] debug_pc,
    output wire [3:0] debug_flags,
    /* debug register read port */
    input  wire [2:0] debug_reg_sel,
    output wire [7:0] debug_reg_data
);

    /* ── State registers ────────────────────────────────────────────────── */
    reg [7:0] pc;
    reg [7:0] sp;
    reg [3:0] flags;   /* {V, N, C, Z} */

    /* ── Instruction fetch ──────────────────────────────────────────────── */
    wire [15:0] insn;
    imem u_imem (.addr(pc), .insn(insn));

    /* ── Decode fields ──────────────────────────────────────────────────── */
    wire [3:0] op      = insn[15:12];
    wire [2:0] rd_idx  = insn[11:9];
    wire [2:0] rs1_idx = insn[8:6];
    wire [2:0] rs2_idx = insn[5:3];
    wire [2:0] fn      = insn[2:0];
    wire [7:0] imm8    = insn[7:0];
    wire [7:0] addr8   = insn[7:0];
    wire [5:0] imm6    = insn[5:0];
    wire [2:0] cc      = insn[11:9];
    wire [8:0] imm9    = insn[8:0];

    wire [7:0] imm6_sx = {{2{imm6[5]}}, imm6};   /* sign-extend imm6 → 8 bits */
    wire signed [7:0] off8 = imm9[7:0];           /* branch offset */

    /* ── Register file ──────────────────────────────────────────────────── */
    reg        rf_wr_en;
    reg  [2:0] rf_wr_addr;
    reg  [7:0] rf_wr_data;
    wire [7:0] rs1_val, rs2_val;

    regfile u_rf (
        .clk      (clk),
        .wr_en    (rf_wr_en),
        .wr_addr  (rf_wr_addr),
        .wr_data  (rf_wr_data),
        .rd_addr1 (rs1_idx),
        .rd_addr2 (rs2_idx),
        .rd_data1 (rs1_val),
        .rd_data2 (rs2_val)
    );

    /* Debug read: separate combinational read via a second read port.
     * We reuse the register file's rd_addr2 during non-write cycles.
     * For simplicity the testbench accesses u_rf.regs[] directly. */
    assign debug_reg_data = (debug_reg_sel == 3'd0) ? 8'h00
                          : u_rf.regs[debug_reg_sel];

    /* ── ALU ────────────────────────────────────────────────────────────── */
    wire [7:0] alu_result;
    wire [3:0] alu_flags_out;

    /* B operand: immediate for LDI, rs2 for everything else */
    wire [7:0] alu_b = (op == 4'h8) ? imm8 : rs2_val;

    alu u_alu (
        .op        (op),
        .fn        (fn),
        .a         (rs1_val),
        .b         (alu_b),
        .flags_in  (flags),
        .result    (alu_result),
        .flags_out (alu_flags_out)
    );

    /* ── Condition evaluation ───────────────────────────────────────────── */
    reg branch_taken;
    always @(*) begin
        case (cc)
            3'd0: branch_taken =  flags[0];          /* EQ: Z=1 */
            3'd1: branch_taken = ~flags[0];          /* NE: Z=0 */
            3'd2: branch_taken =  flags[1];          /* LT: N=1 */
            3'd3: branch_taken = ~flags[1];          /* GE: N=0 */
            3'd4: branch_taken =  flags[2];          /* CS: C=1 */
            3'd5: branch_taken = ~flags[2];          /* CC: C=0 */
            3'd6: branch_taken = 1'b1;               /* ALW      */
            3'd7: branch_taken = 1'b0;               /* NEV      */
            default: branch_taken = 1'b0;
        endcase
    end

    /* ── Data memory ────────────────────────────────────────────────────── */
    reg        dm_wr_en;
    reg  [7:0] dm_addr;
    reg  [7:0] dm_wr_data;
    wire [7:0] dm_rd_data;

    dmem u_dmem (
        .clk     (clk),
        .wr_en   (dm_wr_en),
        .addr    (dm_addr),
        .wr_data (dm_wr_data),
        .rd_data (dm_rd_data)
    );

    /* ── Combinational decode / control ─────────────────────────────────── */
    reg [7:0] pc_next;
    reg [7:0] sp_next;
    reg       flag_update;

    always @(*) begin
        /* Defaults */
        pc_next    = pc + 8'd1;
        sp_next    = sp;
        rf_wr_en   = 1'b0;
        rf_wr_addr = rd_idx;
        rf_wr_data = 8'h00;
        dm_wr_en   = 1'b0;
        dm_addr    = 8'h00;
        dm_wr_data = 8'h00;
        flag_update = 1'b0;

        if (!halt) begin
            case (op)
                4'h0: ;   /* NOP */

                4'h1, 4'h2, 4'h3, 4'h4, 4'h5, 4'h6: begin   /* ALU R-type */
                    rf_wr_en    = 1'b1;
                    rf_wr_addr  = rd_idx;
                    rf_wr_data  = alu_result;
                    flag_update = 1'b1;
                end

                4'h7: begin   /* CMP — flags only, no writeback */
                    flag_update = 1'b1;
                end

                4'h8: begin   /* LDI */
                    rf_wr_en   = 1'b1;
                    rf_wr_addr = rd_idx;
                    rf_wr_data = imm8;
                end

                4'h9: begin   /* LD rd, [rs1 + imm6] */
                    dm_addr    = rs1_val + imm6_sx;
                    rf_wr_en   = 1'b1;
                    rf_wr_addr = rd_idx;
                    rf_wr_data = dm_rd_data;
                end

                4'hA: begin   /* ST [rs1 + imm6], rd  (rd = source reg) */
                    dm_addr    = rs1_val + imm6_sx;
                    dm_wr_data = rs2_val;
                    dm_wr_en   = 1'b1;
                end

                4'hB: begin   /* BR cc, off9 */
                    if (branch_taken)
                        pc_next = pc + {{1{off8[7]}}, off8};
                end

                4'hC: begin   /* JMP addr8 */
                    pc_next = addr8;
                end

                4'hD: begin   /* CALL addr8 — push PC+1 then jump */
                    dm_addr    = sp;
                    dm_wr_data = pc + 8'd1;
                    dm_wr_en   = 1'b1;
                    sp_next    = sp - 8'd1;
                    pc_next    = addr8;
                end

                4'hE: begin   /* RET — pop PC */
                    sp_next = sp + 8'd1;
                    dm_addr = sp + 8'd1;
                    pc_next = dm_rd_data;
                end

                4'hF: begin   /* HLT */
                    pc_next = pc;
                end

                default: ;
            endcase
        end
    end

    /* ── Sequential update ──────────────────────────────────────────────── */
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc    <= 8'h00;
            sp    <= 8'hFF;
            flags <= 4'h0;
            halt  <= 1'b0;
        end else if (!halt) begin
            pc <= pc_next;
            sp <= sp_next;
            if (flag_update) flags <= alu_flags_out;
            if (op == 4'hF) halt <= 1'b1;
        end
    end

    /* ── Debug outputs ──────────────────────────────────────────────────── */
    assign debug_pc    = pc;
    assign debug_flags = flags;

endmodule
