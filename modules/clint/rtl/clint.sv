// clint.sv — Core-Local Interruptor: the machine timer and software interrupt.
//
// A 64-bit free-running `mtime`, a 64-bit `mtimecmp`, and a one-bit `msip`,
// behind a 32-bit bus. See docs/traps.md for the register map and for why the
// offsets are SiFive's rather than tidier ones.
//
// `mtip` is a *level*, not an event: it is the continuous comparison
// mtime >= mtimecmp, so it stays asserted until the handler moves mtimecmp
// forward. Latching it into a sticky flag instead would let a handler return
// with the comparison still true and the interrupt silently lost, which is the
// worse failure of the two — a missed tick rather than an obvious re-entry.

`default_nettype none

module clint #(
    // Byte offsets within the CLINT window.
    parameter logic [15:0] MSIP_OFF        = 16'h0000,
    parameter logic [15:0] MTIMECMP_LO_OFF = 16'h4000,
    parameter logic [15:0] MTIMECMP_HI_OFF = 16'h4004,
    parameter logic [15:0] MTIME_LO_OFF    = 16'hBFF8,
    parameter logic [15:0] MTIME_HI_OFF    = 16'hBFFC
) (
    input  logic        clk,
    input  logic        rst,

    // 32-bit access. `sel` is the address decode from the SoC; the CLINT does
    // not know where in the address space it lives.
    input  logic        sel,
    input  logic [15:0] addr,      // byte offset within the window
    input  logic        we,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,

    // To the core.
    output logic        mtip,      // machine timer interrupt pending
    output logic        msip       // machine software interrupt pending
);

    logic [63:0] mtime;
    logic [63:0] mtimecmp;
    logic        msip_reg;

    // Word-aligned compare. The two low bits are ignored rather than decoded:
    // every register here is 32 bits wide and word aligned, so a sub-word
    // access would be a firmware bug, and silently aliasing it to the
    // containing word is what the rest of this SoC's peripherals do.
    wire [15:0] word_addr = {addr[15:2], 2'b00};

    // ---- mtime: free-running, one tick per clock -------------------------
    //
    // Deliberately not divided down to a "real" microsecond tick. A divisor
    // would make the timer's rate depend on CLK_HZ, and every test would then
    // have to know the synthesis frequency to predict when an interrupt lands.
    // One tick per cycle makes the timing exact and the firmware's constants
    // the only thing that changes between boards.
    always_ff @(posedge clk) begin
        if (rst) mtime <= 64'd0;
        else     mtime <= mtime + 64'd1;
    end

    // ---- mtimecmp and msip ------------------------------------------------
    //
    // mtimecmp resets to all-ones rather than zero. At zero the comparison
    // mtime >= mtimecmp is true from the first cycle out of reset, so a core
    // that enabled interrupts before ever programming the timer would take an
    // interrupt it never asked for. All-ones means "no deadline set".
    always_ff @(posedge clk) begin
        if (rst) begin
            mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
            msip_reg <= 1'b0;
        end else if (sel && we) begin
            case (word_addr)
                MSIP_OFF:        msip_reg          <= wdata[0];
                MTIMECMP_LO_OFF: mtimecmp[31:0]    <= wdata;
                MTIMECMP_HI_OFF: mtimecmp[63:32]   <= wdata;
                default:         ;   // mtime is read-only
            endcase
        end
    end

    // ---- reads -------------------------------------------------------------
    //
    // Registered, so the word for the address presented on cycle T arrives at
    // T+1. That is the convention the rest of this SoC's slaves follow — RAM
    // and the UART both return data a cycle late, and the bus read mux is
    // registered one cycle behind the select to match.
    //
    // A combinational read here looks correct in isolation and is wrong in the
    // system: by the time the mux selects the CLINT, the address bus has moved
    // on, so the load returns the data for whatever address followed it. A
    // `lw` of mtime then yields the next access's word instead of the time.
    always_ff @(posedge clk) begin
        if (rst) rdata <= 32'd0;
        else begin
            case (word_addr)
                MSIP_OFF:        rdata <= {31'd0, msip_reg};
                MTIMECMP_LO_OFF: rdata <= mtimecmp[31:0];
                MTIMECMP_HI_OFF: rdata <= mtimecmp[63:32];
                MTIME_LO_OFF:    rdata <= mtime[31:0];
                MTIME_HI_OFF:    rdata <= mtime[63:32];
                default:         rdata <= 32'd0;
            endcase
        end
    end

    // ---- interrupt outputs -------------------------------------------------
    assign mtip = (mtime >= mtimecmp);
    assign msip = msip_reg;

endmodule

`default_nettype wire
