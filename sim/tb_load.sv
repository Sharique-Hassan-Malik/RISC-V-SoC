// Regression guard: a load must return the word at its own address.
//
// Committed failing, fixed, kept. The core sampled `dmem_rdata` at the end of
// MEM, one cycle before a synchronous memory returns it, so every load got the
// word for whatever address the bus carried the cycle before.
//
// It hid for a long time because the obvious tests do not distinguish it. The
// core's own load test stores 42 at address 0 and loads it back, preceded by
// NOPs — and a NOP's `dmem_addr` is its ALU result, which is also 0. The stale
// word is the right word, by accident.
//
// This one makes the previous address different, which is all it takes:
//
//     sw   x2, 0(x1)     ram[0] = AAAA0000
//     sw   x3, 16(x1)    ram[4] = BBBB0000
//     nop x3
//     lw   x4, 16(x1)    <- must be BBBB0000, was AAAA0000
//     nop x3
//     lw   x5, 0(x1)     <- AAAA0000 either way; the control
//     nop x3
//     sw   x5, 32(x1)

`timescale 1ns / 1ps
`include "soc_map.svh"

module tb_load;

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

    logic [31:0] loaded, control, stored;

    initial begin
        $display("");
        $display("  Load returns the word at its own address");
        $display("");

        repeat (4) @(posedge clk);
        rst = 0;
        repeat (300) @(posedge clk);

        loaded  = dut.u_core.u_id.regfile[4];
        control = dut.u_core.u_id.regfile[5];
        stored  = {dut.u_ram.mem[35], dut.u_ram.mem[34],
                   dut.u_ram.mem[33], dut.u_ram.mem[32]};

        check("a load preceded by a different address reads its own word",
              loaded == 32'hBBBB_0000);
        if (loaded != 32'hBBBB_0000)
            $display("    x4 = 0x%08h, expected 0xBBBB0000 (the word at the previous bus address)",
                     loaded);

        check("the same-address control still reads correctly",
              control == 32'hAAAA_0000);
        check("the loaded value reaches memory through the register file",
              stored == 32'hAAAA_0000);

        $display("");
        $display("  ════════════════════════════════════");
        $display("    Tests passed : %0d", passed);
        $display("    Tests failed : %0d", failed);
        if (failed == 0) $display("    LOADS CORRECT");
        else             $display("    LOADS BROKEN");
        $display("  ════════════════════════════════════");
        $display("");
        $finish;
    end

endmodule
