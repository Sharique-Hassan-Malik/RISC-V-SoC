// csr_file.sv — Machine-mode CSRs and the trap state machine.
//
// Holds mstatus/mie/mtvec/mepc/mcause/mtval/mscratch, decides when a trap is
// taken, and produces the redirect the fetch follows. See docs/traps.md; that
// document is the specification and this module is held to it.
//
// Everything here happens for the instruction in EX. The argument for that
// stage is in the spec and is worth repeating in one line: an instruction that
// reaches EX has no older unresolved branch in front of it and nothing
// downstream can cancel it, so a CSR write made here is never speculative, and
// an interrupt taken here cancels an instruction that has not yet stored or
// written back.

`include "rv32i_pkg.sv"
import rv32i_pkg::*;

`default_nettype none

module csr_file (
    input  logic        clk,
    input  logic        rst,

    // ---- the instruction in EX -------------------------------------------
    input  ctrl_t       ex_ctrl,
    input  logic [31:0] ex_pc,
    input  logic [11:0] csr_addr,     // instr[31:20], carried in `imm`
    input  logic [31:0] csr_wsrc,     // rs1 value, or the zero-extended uimm
    input  logic [4:0]  csr_rs1,      // the rs1 *field*, to spot "no write"

    // ---- interrupt inputs (levels, from the CLINT and the UART) ----------
    input  logic        irq_timer,
    input  logic        irq_soft,
    input  logic        irq_ext,

    // ---- retirement, for the counters ------------------------------------
    input  logic        instr_retired,

    // ---- outputs ----------------------------------------------------------
    output logic [31:0] csr_rdata,    // old value, written back to rd
    output logic        trap_valid,   // redirect the fetch this cycle
    output logic [31:0] trap_target   // mtvec on entry, mepc on mret
);

    // ---- architectural state ---------------------------------------------
    logic        mstatus_mie, mstatus_mpie;
    logic [31:0] mie_reg;
    logic [31:0] mtvec_reg;
    logic [31:0] mscratch_reg;
    logic [31:0] mepc_reg;
    logic [31:0] mcause_reg;
    logic [31:0] mtval_reg;
    logic [63:0] cycle_count, instret_count;

    // mip is not state: the bits are the peripheral levels, wired straight
    // through. A latched copy would be a second source of truth that the
    // handler could clear while the peripheral still asserted the line.
    logic [31:0] mip_wire;
    always_comb begin
        mip_wire = 32'd0;
        mip_wire[IRQ_SOFT_BIT]  = irq_soft;
        mip_wire[IRQ_TIMER_BIT] = irq_timer;
        mip_wire[IRQ_EXT_BIT]   = irq_ext;
    end

    // ---- interrupt arbitration --------------------------------------------
    // External, then software, then timer — the privileged specification's
    // order. Only meaningful when mstatus.MIE is set; ECALL/EBREAK below are
    // deliberately outside this gate because they are not maskable.
    wire irq_ready   = mstatus_mie;
    wire take_ext    = irq_ready && mie_reg[IRQ_EXT_BIT]   && mip_wire[IRQ_EXT_BIT];
    wire take_soft   = irq_ready && mie_reg[IRQ_SOFT_BIT]  && mip_wire[IRQ_SOFT_BIT];
    wire take_timer  = irq_ready && mie_reg[IRQ_TIMER_BIT] && mip_wire[IRQ_TIMER_BIT];
    wire irq_pending = take_ext || take_soft || take_timer;

    // An interrupt needs a real instruction in EX to be attributed to: mepc
    // has to name something that can be returned to.
    wire take_irq   = irq_pending && ex_ctrl.valid;
    wire take_ecall = ex_ctrl.valid && ex_ctrl.is_ecall;
    wire take_break = ex_ctrl.valid && ex_ctrl.is_ebreak;
    wire take_trap  = take_irq || take_ecall || take_break;
    wire take_mret  = ex_ctrl.valid && ex_ctrl.is_mret;

    logic [31:0] trap_cause;
    always_comb begin
        // Synchronous causes first: an ECALL that arrives with an interrupt
        // pending still names ECALL, because the interrupt will be taken again
        // on the handler's first instruction anyway, whereas the ECALL would
        // be lost.
        if      (take_ecall) trap_cause = CAUSE_ECALL_M;
        else if (take_break) trap_cause = CAUSE_BREAK;
        else if (take_ext)   trap_cause = CAUSE_IRQ_EXT;
        else if (take_soft)  trap_cause = CAUSE_IRQ_SOFT;
        else                 trap_cause = CAUSE_IRQ_TIMER;
    end

    // ---- CSR read ----------------------------------------------------------
    logic [31:0] read_value;
    always_comb begin
        case (csr_addr)
            CSR_MSTATUS:  begin
                read_value = 32'd0;
                read_value[MSTATUS_MIE_BIT]  = mstatus_mie;
                read_value[MSTATUS_MPIE_BIT] = mstatus_mpie;
                read_value[12:11]            = 2'b11;   // MPP: machine, always
            end
            CSR_MIE:      read_value = mie_reg;
            CSR_MTVEC:    read_value = {mtvec_reg[31:2], 2'b00};
            CSR_MSCRATCH: read_value = mscratch_reg;
            CSR_MEPC:     read_value = {mepc_reg[31:2], 2'b00};
            CSR_MCAUSE:   read_value = mcause_reg;
            CSR_MTVAL:    read_value = mtval_reg;
            CSR_MIP:      read_value = mip_wire;
            CSR_MCYCLE:   read_value = cycle_count[31:0];
            CSR_MINSTRET: read_value = instret_count[31:0];
            default:      read_value = 32'd0;
        endcase
    end

    assign csr_rdata = read_value;

    // ---- CSR write value ---------------------------------------------------
    // A set/clear whose source operand is x0 (or a zero uimm) is a *read*, not
    // a write. `csrr rd, mip` is CSRRS rd, mip, x0, and treating it as a write
    // would make every read of a read-only CSR an attempted write.
    wire csr_src_is_zero = ex_ctrl.csr_imm ? (csr_wsrc == 32'd0) : (csr_rs1 == 5'd0);

    logic        csr_we;
    logic [31:0] csr_wdata;
    always_comb begin
        csr_we    = 1'b0;
        csr_wdata = read_value;
        if (ex_ctrl.valid && ex_ctrl.is_csr) begin
            case (ex_ctrl.funct3)
                F3_CSRRW, F3_CSRRWI: begin
                    csr_we    = 1'b1;              // always writes, even from x0
                    csr_wdata = csr_wsrc;
                end
                F3_CSRRS, F3_CSRRSI: begin
                    csr_we    = !csr_src_is_zero;
                    csr_wdata = read_value | csr_wsrc;
                end
                F3_CSRRC, F3_CSRRCI: begin
                    csr_we    = !csr_src_is_zero;
                    csr_wdata = read_value & ~csr_wsrc;
                end
                default: ;
            endcase
        end
    end

    // ---- state update ------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            mstatus_mie   <= 1'b0;
            mstatus_mpie  <= 1'b0;
            mie_reg       <= 32'd0;
            mtvec_reg     <= 32'd0;
            mscratch_reg  <= 32'd0;
            mepc_reg      <= 32'd0;
            mcause_reg    <= 32'd0;
            mtval_reg     <= 32'd0;
            cycle_count   <= 64'd0;
            instret_count <= 64'd0;
        end else begin
            cycle_count <= cycle_count + 64'd1;
            if (instr_retired) instret_count <= instret_count + 64'd1;

            // A trap outranks the CSR write of the instruction it cancels:
            // that instruction is being un-executed, so its write must not land.
            if (take_trap) begin
                mepc_reg     <= {ex_pc[31:2], 2'b00};
                mcause_reg   <= trap_cause;
                mtval_reg    <= 32'd0;
                mstatus_mpie <= mstatus_mie;
                mstatus_mie  <= 1'b0;
            end else if (take_mret) begin
                mstatus_mie  <= mstatus_mpie;
                mstatus_mpie <= 1'b1;
            end else if (csr_we) begin
                case (csr_addr)
                    CSR_MSTATUS: begin
                        mstatus_mie  <= csr_wdata[MSTATUS_MIE_BIT];
                        mstatus_mpie <= csr_wdata[MSTATUS_MPIE_BIT];
                    end
                    CSR_MIE:      mie_reg      <= csr_wdata;
                    // MODE is hardwired to 00 (direct). Accepting a vectored
                    // mode here and then ignoring it in the redirect below
                    // would be the kind of quiet lie the spec forbids.
                    CSR_MTVEC:    mtvec_reg    <= {csr_wdata[31:2], 2'b00};
                    CSR_MSCRATCH: mscratch_reg <= csr_wdata;
                    CSR_MEPC:     mepc_reg     <= {csr_wdata[31:2], 2'b00};
                    CSR_MCAUSE:   mcause_reg   <= csr_wdata;
                    CSR_MTVAL:    mtval_reg    <= csr_wdata;
                    // mip, mcycle and minstret are read-only here.
                    default: ;
                endcase
            end
        end
    end

    // ---- redirect ----------------------------------------------------------
    assign trap_valid  = take_trap || take_mret;
    assign trap_target = take_trap ? {mtvec_reg[31:2], 2'b00}
                                   : {mepc_reg[31:2],  2'b00};

endmodule

`default_nettype wire
