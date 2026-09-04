// tb_traps.sv — a timer interrupt preempts a running program, and it resumes.
//
// The interesting assertion is not "the handler ran". A core that jumped to
// mtvec and never returned would satisfy that. What is checked here is that the
// interrupted loop *keeps counting after* each trap, which is the only evidence
// that mepc was right and mret went back to it.
//
// The firmware is `socgen.firmware.build_timer_demo`, assembled into the
// working directory before the run. Its RAM slots:
//
//   [0] counter incremented by the interrupted loop
//   [1] number of times the handler ran
//   [2] mcause, as the handler read it
//   [3] mepc, as the handler read it

`timescale 1ns/1ps

`include "soc_map.svh"

module tb_traps;

    localparam CLK_NS = 20;

    logic clk = 1'b0, rst = 1'b1;
    always #(CLK_NS/2) clk = ~clk;

    logic uart_tx, uart_rx = 1'b1;
    logic [31:0] dbg_dmem_addr;
    logic        dbg_dmem_we;
    logic [63:0] dbg_cycles, dbg_instret;

    soc_top #(.CLK_HZ(50_000_000)) dut (
        .clk(clk), .rst(rst),
        .uart_tx(uart_tx), .uart_rx(uart_rx),
        .dbg_dmem_addr(dbg_dmem_addr), .dbg_dmem_we(dbg_dmem_we),
        .dbg_cycles(dbg_cycles), .dbg_instret(dbg_instret)
    );

    localparam int SLOT_MAIN   = 0;
    localparam int SLOT_TICKS  = 1;
    localparam int SLOT_CAUSE  = 2;
    localparam int SLOT_RESUME = 3;

    localparam logic [31:0] CAUSE_TIMER = 32'h8000_0007;

    int ok = 0, fail = 0;

    task automatic check(input string what, input logic cond);
        if (cond) begin ok++;   $display("  PASS  %s", what); end
        else      begin fail++; $display("  FAIL  %s", what); end
    endtask

    // The data memory is a byte array, so a word is four entries, little end
    // first. Indexing it by word number returns one byte — which reads as a
    // counter that wraps at 256 rather than an obviously wrong value.
    function automatic logic [31:0] ram(input int word_index);
        return {dut.u_ram.mem[word_index*4 + 3], dut.u_ram.mem[word_index*4 + 2],
                dut.u_ram.mem[word_index*4 + 1], dut.u_ram.mem[word_index*4 + 0]};
    endfunction

    logic [31:0] ticks_a, ticks_b, main_a, main_b, cause, resume_pc;

    initial begin
        repeat (8) @(posedge clk);
        rst = 1'b0;

        // Long enough for several timer periods (400 mtime ticks each).
        repeat (3000) @(posedge clk);

        main_a  = ram(SLOT_MAIN);
        ticks_a = ram(SLOT_TICKS);
        cause   = ram(SLOT_CAUSE);
        resume_pc = ram(SLOT_RESUME);

        $display("  after 3000 cycles: main=%0d ticks=%0d cause=%08x mepc=%08x",
                 main_a, ticks_a, cause, resume_pc);

        // ---- the trap was taken, more than once --------------------------
        check("the timer interrupt fired", ticks_a > 0);
        check("it fired repeatedly (re-arming works)", ticks_a >= 3);

        // ---- it was the right trap ---------------------------------------
        check("mcause is the machine timer interrupt (0x80000007)",
              cause === CAUSE_TIMER);

        // ---- mepc named a real instruction -------------------------------
        // The loop body is three instructions near the end of the program;
        // what matters is that mepc is inside the program and word-aligned,
        // not zero and not somewhere in the handler.
        check("mepc is word-aligned", resume_pc[1:0] === 2'b00);
        check("mepc is not zero", resume_pc !== 32'd0);
        check("mepc is outside the handler (it names the interrupted loop)",
              resume_pc > 32'h40);

        // ---- and the interrupted program resumed --------------------------
        // This is the assertion the whole bench exists for.
        repeat (3000) @(posedge clk);
        main_b  = ram(SLOT_MAIN);
        ticks_b = ram(SLOT_TICKS);
        $display("  after 6000 cycles: main=%0d ticks=%0d", main_b, ticks_b);

        check("the interrupted loop kept running after mret", main_b > main_a);
        check("and the handler kept being entered", ticks_b > ticks_a);

        // The loop must make progress *between* traps, not just once.
        check("the loop advanced by more than the tick count",
              (main_b - main_a) > (ticks_b - ticks_a));

        $display("\n════════════════════════════════════");
        $display("  Tests passed : %0d", ok);
        $display("  Tests failed : %0d", fail);
        if (fail == 0) $display("  TRAPS SIMULATION PASSED");
        else           $display("  TRAPS SIMULATION FAILED");
        $display("════════════════════════════════════\n");
        $finish;
    end

    initial begin #20_000_000; $display("TIMEOUT"); $finish; end

endmodule
