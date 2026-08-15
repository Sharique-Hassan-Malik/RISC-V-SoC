/*
 * top.v — iCEstick top-level for the C8 CPU.
 *
 * The iCEstick has:
 *   12 MHz oscillator on pin J3
 *   5 green LEDs on pins 99, 98, 97, 96, 95 (active high)
 *
 * The C8 CPU is clocked at 12 MHz (no PLL).  The demo program (blink.asm)
 * cycles a chasing pattern across the 5 LEDs using R1 as a counter and
 * R2 as the LED output register.  The LED register value is mapped to the
 * five least-significant bits of data-RAM address 0x00.
 *
 * The top-level reads DRAM[0x00] every cycle and drives the LEDs directly.
 * This is possible because DRAM is synchronous-write / async-read, so the
 * LED state is always visible even between CPU writes.
 *
 * Pin constraints are in c8.pcf (iCEstick Lattice format).
 */

module top (
    input  wire       clk12,    /* 12 MHz oscillator */
    output wire [4:0] leds      /* active-high LEDs   */
);

    wire halt;
    wire [7:0] debug_pc;
    wire [3:0] debug_flags;
    wire [7:0] debug_reg_data;

    /* Synchronous reset: hold low for 4 cycles after power-on */
    reg [2:0] rst_cnt = 3'd0;
    reg rst_n = 1'b0;
    always @(posedge clk12) begin
        if (!rst_n) begin
            if (rst_cnt == 3'd4) rst_n <= 1'b1;
            else rst_cnt <= rst_cnt + 3'd1;
        end
    end

    cpu u_cpu (
        .clk          (clk12),
        .rst_n        (rst_n),
        .halt         (halt),
        .debug_pc     (debug_pc),
        .debug_flags  (debug_flags),
        .debug_reg_sel(3'd0),
        .debug_reg_data(debug_reg_data)
    );

    /* Drive LEDs from DRAM address 0 via the CPU's data memory.
     * We expose the LED register via a direct tap into dmem. */
    assign leds = u_cpu.u_dmem.mem[0][4:0];

endmodule
