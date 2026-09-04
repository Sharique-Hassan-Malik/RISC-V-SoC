// tb_clint.sv — Self-checking testbench for the CLINT.
//
// What is worth testing here is not "can a register be written and read back".
// It is the three properties the trap specification depends on:
//
//   1. mtip is a level, so it stays high until mtimecmp moves past mtime.
//   2. mtimecmp resets to all-ones, so a core that enables interrupts before
//      programming the timer is not immediately interrupted.
//   3. The low-then-high write order can produce a spurious interrupt, and the
//      documented order cannot. This is asserted rather than described,
//      because it is the reason the firmware writes the halves in that order.
//
// Run with:
//   iverilog -g2012 -o tb_clint tb_clint.sv clint.sv && vvp tb_clint

`timescale 1ns/1ps

module tb_clint;

    localparam CLK_NS = 20;

    logic clk = 1'b0, rst = 1'b1;
    always #(CLK_NS/2) clk = ~clk;

    logic        sel = 1'b0, we = 1'b0;
    logic [15:0] addr = 16'd0;
    logic [31:0] wdata = 32'd0, rdata;
    logic        mtip, msip;

    clint dut (
        .clk(clk), .rst(rst),
        .sel(sel), .addr(addr), .we(we), .wdata(wdata), .rdata(rdata),
        .mtip(mtip), .msip(msip)
    );

    localparam logic [15:0] MSIP_OFF        = 16'h0000;
    localparam logic [15:0] MTIMECMP_LO_OFF = 16'h4000;
    localparam logic [15:0] MTIMECMP_HI_OFF = 16'h4004;
    localparam logic [15:0] MTIME_LO_OFF    = 16'hBFF8;
    localparam logic [15:0] MTIME_HI_OFF    = 16'hBFFC;

    int ok = 0, fail = 0;

    task automatic check(input string what, input logic cond);
        if (cond) begin
            ok++;
            $display("  PASS  %s", what);
        end else begin
            fail++;
            $display("  FAIL  %s", what);
        end
    endtask

    task automatic bus_write(input logic [15:0] a, input logic [31:0] d);
        @(negedge clk);
        sel = 1'b1; we = 1'b1; addr = a; wdata = d;
        @(negedge clk);
        sel = 1'b0; we = 1'b0;
    endtask

    // The read is synchronous: the address is presented for a clock edge and
    // the word arrives after it. Sampling in the same cycle would test a
    // combinational read the SoC's bus mux cannot use — see clint.sv.
    task automatic bus_read(input logic [15:0] a, output logic [31:0] d);
        @(negedge clk);
        sel = 1'b1; we = 1'b0; addr = a;
        @(negedge clk);
        d = rdata;
        sel = 1'b0;
    endtask

    logic [31:0] v;
    logic [31:0] first, after, now_lo, now_hi;

    initial begin
        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(negedge clk);

        // ---- 2. no deadline out of reset ---------------------------------
        check("mtip is low out of reset (mtimecmp is all-ones)", mtip === 1'b0);
        bus_read(MTIMECMP_LO_OFF, v);
        check("mtimecmp low reads all-ones", v === 32'hFFFF_FFFF);
        bus_read(MTIMECMP_HI_OFF, v);
        check("mtimecmp high reads all-ones", v === 32'hFFFF_FFFF);

        // ---- mtime advances ----------------------------------------------
        bus_read(MTIME_LO_OFF, v);
        first = v;
        repeat (10) @(posedge clk);
        bus_read(MTIME_LO_OFF, v);
        check("mtime advances", v > first);

        // ---- msip is a plain read/write bit ------------------------------
        check("msip is low out of reset", msip === 1'b0);
        bus_write(MSIP_OFF, 32'd1);
        check("msip rises when written 1", msip === 1'b1);
        bus_read(MSIP_OFF, v);
        check("msip reads back as 1", v === 32'd1);
        bus_write(MSIP_OFF, 32'd0);
        check("msip clears when written 0", msip === 1'b0);

        // ---- 1. mtip is a level, not an event ----------------------------
        // Arm for a time already past: the comparison is true immediately.
        bus_write(MTIMECMP_HI_OFF, 32'd0);
        bus_write(MTIMECMP_LO_OFF, 32'd1);
        @(posedge clk);
        check("mtip asserts when mtime >= mtimecmp", mtip === 1'b1);

        repeat (20) @(posedge clk);
        check("mtip STAYS high while mtimecmp is unchanged (it is a level)",
              mtip === 1'b1);

        // Moving the deadline forward is the only thing that clears it.
        bus_read(MTIME_LO_OFF, v);
        bus_write(MTIMECMP_LO_OFF, v + 32'd1000);
        @(posedge clk);
        check("mtip clears only when mtimecmp moves past mtime", mtip === 1'b0);

        // ---- mtime is read-only ------------------------------------------
        bus_read(MTIME_LO_OFF, v);
        bus_write(MTIME_LO_OFF, 32'd0);
        bus_read(MTIME_LO_OFF, after);
        check("writing mtime does not reset it", after > v);

        // ---- 3. the write-order hazard is real ---------------------------
        // Park the deadline far in the future, then move it to a *smaller*
        // high half. Writing the low half first passes through
        // (old_high, new_low) — a pair that is already in the past.
        bus_write(MTIMECMP_HI_OFF, 32'd0);
        bus_write(MTIMECMP_LO_OFF, 32'hFFFF_FF00);
        @(posedge clk);
        check("armed far ahead: mtip low", mtip === 1'b0);

        // The wrong order, asserted so the hazard cannot quietly go away.
        bus_write(MTIMECMP_LO_OFF, 32'd1);           // (high=0, low=1) -> past
        @(posedge clk);
        check("low-half-first briefly arms a past deadline (the hazard)",
              mtip === 1'b1);

        // Parking the low half at ZERO is the plausible-looking version, and it
        // is wrong the same way: (any_high, 0) is the smallest pair there is.
        // Asserted so the backwards intuition cannot quietly return.
        bus_write(MTIMECMP_HI_OFF, 32'd0);
        bus_write(MTIMECMP_LO_OFF, 32'hFFFF_FF00);
        @(posedge clk);
        check("re-armed far ahead", mtip === 1'b0);
        bus_write(MTIMECMP_LO_OFF, 32'd0);       // "disarm first" -- fires
        @(posedge clk);
        check("low-half-to-ZERO also arms a past deadline (same hazard)",
              mtip === 1'b1);

        // The specification's order: park the low half at ALL-ONES, so the
        // intermediate pair is never smaller than either the old or new value.
        bus_read(MTIME_HI_OFF, now_hi);
        bus_read(MTIME_LO_OFF, now_lo);
        bus_write(MTIMECMP_LO_OFF, 32'hFFFF_FFFF);   // step 1: low = -1
        @(posedge clk);
        check("step 1 (low = -1) clears the pending compare", mtip === 1'b0);
        bus_write(MTIMECMP_HI_OFF, now_hi);          // step 2: high
        @(posedge clk);
        check("step 2 (high) does not fire", mtip === 1'b0);
        bus_write(MTIMECMP_LO_OFF, now_lo + 32'd500);   // step 3: low
        @(posedge clk);
        check("step 3 (low) leaves the deadline ahead, still low",
              mtip === 1'b0);

        // And it does eventually fire, so the sequence armed something real.
        repeat (600) @(posedge clk);
        check("the armed deadline does fire once mtime reaches it",
              mtip === 1'b1);

        $display("\n════════════════════════════════════");
        $display("  Tests passed : %0d", ok);
        $display("  Tests failed : %0d", fail);
        if (fail == 0) $display("  CLINT SIMULATION PASSED");
        else           $display("  CLINT SIMULATION FAILED");
        $display("════════════════════════════════════\n");
        $finish;
    end

    initial begin #10_000_000; $display("TIMEOUT"); $finish; end

endmodule
