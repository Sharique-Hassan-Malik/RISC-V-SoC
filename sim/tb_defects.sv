// Regression guards for defects the SoC integration exposed.
//
// Both checks below pass. They were committed failing, which is the point: a
// defect described in prose gets argued about and forgotten, while one with a
// reproducer is a fixed target — and the day someone fixes it, this file says
// so. It said so.
//
//   1. A loop whose body is a single instruction, followed by a backward
//      branch, ran the body once too many. Two or more instructions in the
//      body behaved correctly, which is why the core's own loop test never saw
//      it. Fixed: a redirect now invalidates the fetch still inside the
//      instruction memory, not just the one in IF/ID. See docs/soc.md.
//
//   2. A load from a peripheral reaching the register file. This always
//      worked; it is here to bound what remains. The poll loop in
//      sim/tb_poll.sv uses the same load and still fails, so the defect is not
//      in the peripheral read path — which is what docs/soc.md used to claim.
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
    logic [31:0] peripheral;

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

        // A straight-line load from a peripheral, plus 7. x5 is poisoned with
        // 0xDEAD first, so a load that never lands leaves 0xDEB4 here.
        //
        // This one works, and it is here to bound the remaining defect: the
        // peripheral read path is fine. What fails is the same load inside a
        // poll loop -- see sim/tb_poll.sv.
        peripheral = {dut.u_ram.mem[7], dut.u_ram.mem[6],
                      dut.u_ram.mem[5], dut.u_ram.mem[4]};
        check("a load from a peripheral reaches the register file",
              peripheral == 32'd7);
        if (peripheral != 32'd7)
            $display("    ram[1] = 0x%08h, expected 7", peripheral);

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
