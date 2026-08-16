// Reproducer: a status poll never sees `done`.
//
// This is committed failing. The firmware in socgen/firmware.py waits a fixed
// number of cycles instead of polling, with a comment pointing here.
//
// What is NOT wrong, measured on the bus:
//
//   * the AES block completes and sets done_q -- the ciphertext is correct;
//   * dmem_rdata carries 0x00000001 on exactly the cycle the core samples it;
//   * a straight-line load from the same register lands correctly, which
//     sim/tb_defects.sv checks.
//
// What is wrong is in the predictor. The poll is
//
//     0x7c   lw  x2, 0x24(x1)
//     0x80   beq x2, x0, -4
//
// and BTB index 31 -- PC[7:2] of 0x7c, the *load* -- holds 0x78 with a
// matching tag, so the load is predicted taken and the fetch is redirected
// backwards to the CTRL write. The branch at 0x80 is never reached: it never
// appears in ID/EX at all. Which branch resolution wrote that entry is not yet
// established; no instruction at 0x7c is a branch.
//
// The tag check and the bogus-redirect correction added to if_stage.sv fixed
// the aliasing case this looks like, and did not fix this one, so it is
// something else.

`timescale 1ns / 1ps
`include "soc_map.svh"

module tb_poll;

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
    logic [31:0] marker;

    task check(input string what, input logic condition);
        if (condition) begin passed++; $display("  PASS: %s", what); end
        else           begin failed++; $display("  FAIL: %s", what); end
    endtask

    initial begin
        $display("");
        $display("  Poll-loop reproducer");
        $display("");

        repeat (4) @(posedge clk);
        rst = 0;
        repeat (2000) @(posedge clk);

        // The program polls AES STATUS.done and, once it sees it, stores a
        // marker to RAM word 0. Reaching the store at all is the whole test.
        marker = {dut.u_ram.mem[3], dut.u_ram.mem[2],
                  dut.u_ram.mem[1], dut.u_ram.mem[0]};

        check("a status poll terminates and reaches the store",
              marker == 32'hA5A5_0001);
        if (marker != 32'hA5A5_0001)
            $display("    ram[0] = 0x%08h, expected 0xA5A50001 -- the poll never ended",
                     marker);

        $display("");
        $display("  ════════════════════════════════════");
        $display("    Tests passed : %0d", passed);
        $display("    Tests failed : %0d", failed);
        if (failed == 0) $display("    POLL FIXED");
        else             $display("    POLL STILL BROKEN");
        $display("  ════════════════════════════════════");
        $display("");
        $finish;
    end

endmodule
