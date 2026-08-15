// Reproducers for two defects the SoC integration exposed.
//
// These are committed, and they fail. That is the point: a defect described in
// prose gets argued about and forgotten, while one with a reproducer is a
// fixed target — and the day someone fixes it, this file says so.
//
//   1. A loop whose body is a single instruction, followed by a backward
//      branch, runs the body once too many. Two or more instructions in the
//      body behave correctly. The core's own loop test has a two-instruction
//      body, which is why it never saw this.
//
//   2. A load from a peripheral does not reach the register file. Loads from
//      RAM work and writes to peripherals work; only the peripheral read path
//      is affected. The SoC firmware waits a fixed number of cycles rather
//      than polling a status register because of it.
//
// The program is assembled by socgen/firmware.py's sibling in the test harness
// and loaded as program.hex, exactly as the SoC bench is.

`timescale 1ns / 1ps
`include "soc_map.svh"

module tb_defects;

    logic clk = 0;
    logic rst = 1;
    logic uart_rx = 1, uart_tx;
    logic [31:0] dbg_dmem_addr;
    logic        dbg_dmem_we;
    logic [63:0] dbg_cycles, dbg_instret;

    always #5 clk = ~clk;

    soc_top #(.CLK_HZ(100_000_000)) dut (
        .clk(clk), .rst(rst), .uart_tx(uart_tx), .uart_rx(uart_rx),
        .dbg_dmem_addr(dbg_dmem_addr), .dbg_dmem_we(dbg_dmem_we),
        .dbg_cycles(dbg_cycles), .dbg_instret(dbg_instret)
    );

    int passed = 0, failed = 0;

    task check(input string what, input logic condition);
        if (condition) begin passed++; $display("  PASS: %s", what); end
        else           begin failed++; $display("  FAIL: %s", what); end
    endtask

    logic [31:0] counter;

    initial begin
        $display("");
        $display("  Known-defect reproducers");
        $display("");

        repeat (4) @(posedge clk);
        rst = 0;
        repeat (400) @(posedge clk);

        counter = {dut.u_ram.mem[3], dut.u_ram.mem[2],
                   dut.u_ram.mem[1], dut.u_ram.mem[0]};

        // Defect 1: the loop counts to 5, so the store should hold 5.
        check("single-instruction loop body runs the right number of times",
              counter == 32'd5);
        if (counter != 32'd5)
            $display("    counter = %0d, expected 5", counter);

        $display("");
        $display("  ════════════════════════════════════");
        $display("    Tests passed : %0d", passed);
        $display("    Tests failed : %0d", failed);
        if (failed == 0) $display("    DEFECTS FIXED");
        else             $display("    DEFECTS STILL PRESENT");
        $display("  ════════════════════════════════════");
        $display("");
        $finish;
    end

endmodule
