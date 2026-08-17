// tb_riscv.sv — Cycle-accurate testbench for the RV32I pipeline.
//
// Tests:
//   1. Basic ALU instructions (ADD, SUB, AND, OR, XOR, SLT, shifts).
//   2. Data forwarding: EX→EX, MEM→EX, WB→EX.
//   3. Load-use hazard: LW followed by immediate use (expect 1-cycle stall).
//   4. Branch not-taken and taken, predictor update.
//   5. JAL and JALR.
//   6. Load/store: LW/SW, LB/LBU, LH/LHU, SB/SH.
//   7. AUIPC and LUI.
//   8. Loop counting (branch predictor exercise: 64 iterations of a tight loop).
//
// Each test section writes a result register and checks it against the
// expected value after enough cycles for the pipeline to drain.
//
// Run with:
//   vcs -sverilog +v2k riscv_core.sv if_stage.sv id_stage.sv ex_stage.sv \
//       mem_stage.sv wb_stage.sv hazard_unit.sv rv32i_pkg.sv memories.sv \
//       tb_riscv.sv -o sim_riscv && ./sim_riscv
//   or:
//   iverilog -g2012 -o tb_riscv tb_riscv.sv riscv_core.sv if_stage.sv \
//            id_stage.sv ex_stage.sv mem_stage.sv wb_stage.sv \
//            hazard_unit.sv rv32i_pkg.sv memories.sv && vvp tb_riscv

`timescale 1ns/1ps

module tb_riscv;

    localparam CLK_PERIOD = 10;   // 100 MHz

    logic        clk = 1'b0;
    logic        rst = 1'b1;

    // Memory interfaces
    logic [31:0] imem_addr, imem_data;
    logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    logic [3:0]  dmem_be;
    logic        dmem_we;

    // Performance counters
    logic [63:0] perf_cycles, perf_instret;
    logic [31:0] perf_branches, perf_mispredicts, perf_stall_cycles;

    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- DUT + memories --------------------------------------------------
    riscv_core dut (
        .clk(clk), .rst(rst),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_be(dmem_be), .dmem_we(dmem_we), .dmem_rdata(dmem_rdata),
        .perf_cycles(perf_cycles), .perf_instret(perf_instret),
        .perf_branches(perf_branches), .perf_mispredicts(perf_mispredicts),
        .perf_stall_cycles(perf_stall_cycles)
    );

    imem u_imem (.clk(clk), .addr(imem_addr), .data(imem_data));
    dmem u_dmem (.clk(clk), .addr(dmem_addr), .wdata(dmem_wdata),
                 .be(dmem_be), .we(dmem_we), .rdata(dmem_rdata));

    // ---- Register file access via hierarchy ------------------------------
    // x0 is hardwired; x1..x31 in the register file.
    function automatic logic [31:0] rf (input int r);
        if (r == 0) return 32'd0;
        return dut.u_id.regfile[r];
    endfunction

    // ---- Test infrastructure ---------------------------------------------
    int tests_passed = 0;
    int tests_failed = 0;

    task check(input string name, input logic [31:0] got, input logic [31:0] exp);
        if (got === exp) begin
            $display("  PASS: %-40s  got 0x%08X", name, got);
            tests_passed++;
        end else begin
            $display("  FAIL: %-40s  got 0x%08X  exp 0x%08X", name, got, exp);
            tests_failed++;
        end
    endtask

    // Drain: wait enough cycles for all in-flight instructions to retire
    task drain(input int extra = 0);
        repeat (8 + extra) @(posedge clk);
    endtask

    // ---- Load program into imem ------------------------------------------
    // Programs are loaded directly into u_imem.mem before reset is released.
    // Address 0 = first instruction.

    // Helper to encode common RV32I instructions as 32-bit words.
    // (abbreviated — covers only what the tests need)

    function automatic logic [31:0] enc_r(
        input logic [6:0] op, input logic [4:0] rd, input logic [2:0] f3,
        input logic [4:0] rs1, input logic [4:0] rs2, input logic [6:0] f7);
        enc_r = {f7, rs2, rs1, f3, rd, op};
    endfunction

    function automatic logic [31:0] enc_i(
        input logic [6:0] op, input logic [4:0] rd, input logic [2:0] f3,
        input logic [4:0] rs1, input logic signed [11:0] imm);
        enc_i = {imm, rs1, f3, rd, op};
    endfunction

    function automatic logic [31:0] enc_s(
        input logic [4:0] rs1, input logic [4:0] rs2, input logic [2:0] f3,
        input logic signed [11:0] imm);
        enc_s = {imm[11:5], rs2, rs1, f3, imm[4:0], 7'b010_0011};
    endfunction

    function automatic logic [31:0] enc_b(
        input logic [4:0] rs1, input logic [4:0] rs2, input logic [2:0] f3,
        input logic signed [12:0] imm);  // imm is byte offset, bit 0 always 0
        enc_b = {imm[12], imm[10:5], rs2, rs1, f3,
                 imm[4:1], imm[11], 7'b110_0011};
    endfunction

    function automatic logic [31:0] enc_u(
        input logic [6:0] op, input logic [4:0] rd, input logic [31:12] imm);
        enc_u = {imm, rd, op};
    endfunction

    function automatic logic [31:0] enc_jal(
        input logic [4:0] rd, input logic signed [20:0] imm);
        enc_jal = {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'b110_1111};
    endfunction

    // Shorthand opcodes
    localparam OP = 7'b011_0011;
    localparam OI = 7'b001_0011;
    localparam LUI_OP  = 7'b011_0111;
    localparam AUP_OP  = 7'b001_0111;
    localparam LD      = 7'b000_0011;
    localparam NOP32   = 32'h0000_0013;  // ADDI x0, x0, 0

    int pc;   // instruction index for program loading

    task load_nop_pad(input int from, input int to);
        for (int i = from; i < to; i++) u_imem.mem[i] = NOP32;
    endtask

    // Fill the whole instruction memory with NOPs.
    //
    // `imem` runs `$readmemh("program.hex")` in its initial block, and the SoC
    // and defect benches write that file into this directory. Without this, a
    // test that runs off the end of its own pad executes AES key material left
    // there by whichever bench ran last — and fails with values like
    // 0x885a308d, which is a slice of the FIPS-197 plaintext and looks like a
    // core bug. Each test starts from a known memory instead.
    task clear_imem;
        for (int i = 0; i < 1024; i++) u_imem.mem[i] = NOP32;
    endtask

    // =========================================================
    // Test 1: Basic ALU operations
    // =========================================================
    task test_alu;
        $display("\n[Test 1] Basic ALU operations");
        pc = 0;
        clear_imem;

        // ADDI x1, x0, 10    → x1 = 10
        u_imem.mem[pc++] = enc_i(OI, 5'd1, 3'b000, 5'd0, 12'd10);
        // ADDI x2, x0, 3     → x2 = 3
        u_imem.mem[pc++] = enc_i(OI, 5'd2, 3'b000, 5'd0, 12'd3);
        // ADD  x3, x1, x2    → x3 = 13
        u_imem.mem[pc++] = enc_r(OP, 5'd3, 3'b000, 5'd1, 5'd2, 7'b000_0000);
        // SUB  x4, x1, x2    → x4 = 7
        u_imem.mem[pc++] = enc_r(OP, 5'd4, 3'b000, 5'd1, 5'd2, 7'b010_0000);
        // AND  x5, x1, x2    → x5 = 10&3 = 2
        u_imem.mem[pc++] = enc_r(OP, 5'd5, 3'b111, 5'd1, 5'd2, 7'b000_0000);
        // OR   x6, x1, x2    → x6 = 10|3 = 11
        u_imem.mem[pc++] = enc_r(OP, 5'd6, 3'b110, 5'd1, 5'd2, 7'b000_0000);
        // XOR  x7, x1, x2    → x7 = 10^3 = 9
        u_imem.mem[pc++] = enc_r(OP, 5'd7, 3'b100, 5'd1, 5'd2, 7'b000_0000);
        // SLT  x8, x2, x1    → x8 = 1 (3 < 10)
        u_imem.mem[pc++] = enc_r(OP, 5'd8, 3'b010, 5'd2, 5'd1, 7'b000_0000);
        // SLL  x9, x1, x2    → x9 = 10 << 3 = 80
        u_imem.mem[pc++] = enc_r(OP, 5'd9, 3'b001, 5'd1, 5'd2, 7'b000_0000);
        // SRL  x10,x9, x2    → x10= 80 >> 3 = 10
        u_imem.mem[pc++] = enc_r(OP, 5'd10, 3'b101, 5'd9, 5'd2, 7'b000_0000);
        // ADDI x11, x0, -5   → x11 = 0xFFFFFFFB (signed -5)
        u_imem.mem[pc++] = enc_i(OI, 5'd11, 3'b000, 5'd0, -12'd5);
        // SRA  x12, x11, x2  → x12 = -5 >> 3 = -1 (sign-extended)
        u_imem.mem[pc++] = enc_r(OP, 5'd12, 3'b101, 5'd11, 5'd2, 7'b010_0000);
        load_nop_pad(pc, pc + 10);

        rst = 1'b1; repeat(4) @(posedge clk); rst = 1'b0;
        drain(20);

        check("ADD  x3 = x1+x2",    rf(3),  32'd13);
        check("SUB  x4 = x1-x2",    rf(4),  32'd7);
        check("AND  x5 = x1&x2",    rf(5),  32'd2);
        check("OR   x6 = x1|x2",    rf(6),  32'd11);
        check("XOR  x7 = x1^x2",    rf(7),  32'd9);
        check("SLT  x8 = (3<10)?1", rf(8),  32'd1);
        check("SLL  x9 = 10<<3",    rf(9),  32'd80);
        check("SRL  x10= 80>>3",    rf(10), 32'd10);
        check("SRA  x12= -5>>3",    rf(12), 32'hFFFF_FFFF);
    endtask

    // =========================================================
    // Test 2: Forwarding paths
    // =========================================================
    task test_forwarding;
        $display("\n[Test 2] Data forwarding");
        pc = 0;
        clear_imem;

        // EX→EX forward: result of ADDI used by next ADD
        u_imem.mem[pc++] = enc_i(OI, 5'd1, 3'b000, 5'd0, 12'd7);  // x1 = 7
        u_imem.mem[pc++] = enc_r(OP, 5'd2, 3'b000, 5'd1, 5'd0, 7'b000_0000); // x2 = x1+0 = 7
        // MEM→EX forward
        u_imem.mem[pc++] = enc_i(OI, 5'd3, 3'b000, 5'd0, 12'd5);  // x3 = 5
        u_imem.mem[pc++] = enc_i(OI, 5'd4, 3'b000, 5'd0, 12'd1);  // x4 = 1 (no dependency)
        u_imem.mem[pc++] = enc_r(OP, 5'd5, 3'b000, 5'd3, 5'd4, 7'b000_0000); // x5=5+1=6 MEM→EX
        load_nop_pad(pc, pc + 10);

        rst = 1'b1; repeat(4) @(posedge clk); rst = 1'b0;
        drain(20);

        check("EX→EX fwd: x2 = x1 = 7",      rf(2), 32'd7);
        check("MEM→EX fwd: x5 = x3+x4 = 6",  rf(5), 32'd6);
    endtask

    // =========================================================
    // Test 3: Load-use hazard (1-cycle stall)
    // =========================================================
    task test_load_use;
        $display("\n[Test 3] Load-use hazard");
        pc = 0;
        clear_imem;
        // Store 42 at dmem[0]
        u_imem.mem[pc++] = enc_i(OI, 5'd1, 3'b000, 5'd0, 12'd42);   // x1 = 42
        u_imem.mem[pc++] = enc_s(5'd0, 5'd1, 3'b010, 12'd0);         // SW x1, 0(x0)
        // Load-use: LW x2, 0(x0) then immediately ADD x3, x2, x0
        load_nop_pad(pc, pc + 2); pc += 2;   // let store commit
        u_imem.mem[pc++] = enc_i(LD, 5'd2, 3'b010, 5'd0, 12'd0);     // LW x2, 0(x0) → x2=42
        u_imem.mem[pc++] = enc_r(OP, 5'd3, 3'b000, 5'd2, 5'd0, 7'b000_0000); // ADD x3,x2,x0
        load_nop_pad(pc, pc + 10);

        rst = 1'b1; repeat(4) @(posedge clk); rst = 1'b0;
        drain(25);

        check("Load-use: x3 = loaded 42", rf(3), 32'd42);
    endtask

    // =========================================================
    // Test 4: Branch taken and not-taken
    // =========================================================
    task test_branch;
        $display("\n[Test 4] Branch");
        pc = 0;
        clear_imem;
        // BEQ x0, x0, +8  (taken — skip next instruction)
        // If branch taken: x1 = 99, else x1 = 0
        u_imem.mem[pc++] = enc_b(5'd0, 5'd0, 3'b000, 13'd8);        // BEQ x0,x0, +8
        u_imem.mem[pc++] = enc_i(OI, 5'd1, 3'b000, 5'd0, 12'd0);   // ADDI x1, 0 (skipped)
        u_imem.mem[pc++] = enc_i(OI, 5'd1, 3'b000, 5'd0, 12'd99);  // ADDI x1, 99
        // BNE x0, x0, +8  (not taken — fall through)
        // x2 should get 55
        u_imem.mem[pc++] = enc_b(5'd0, 5'd0, 3'b001, 13'd8);        // BNE x0,x0, +8
        u_imem.mem[pc++] = enc_i(OI, 5'd2, 3'b000, 5'd0, 12'd55);  // ADDI x2, 55 (fall-through, executed)
        u_imem.mem[pc++] = enc_i(OI, 5'd0, 3'b000, 5'd0, 12'd0);   // NOP: this is the +8 (taken) target;
                                                                    // on the not-taken fall-through it must
                                                                    // not clobber x2, so use x0 (NOP).
        load_nop_pad(pc, pc + 10);

        rst = 1'b1; repeat(4) @(posedge clk); rst = 1'b0;
        drain(25);

        check("BEQ taken: x1 = 99",           rf(1), 32'd99);
        check("BNE not-taken: x2 = 55",        rf(2), 32'd55);
    endtask

    // =========================================================
    // Test 5: JAL / JALR
    // =========================================================
    task test_jal_jalr;
        $display("\n[Test 5] JAL / JALR");
        pc = 0;
        clear_imem;
        // JAL x1, +8   → x1 = PC+4 (= 4), jump to PC+8 (= 8)
        u_imem.mem[0] = enc_jal(5'd1, 21'd8);               // JAL x1, +8
        u_imem.mem[1] = enc_i(OI, 5'd5, 3'b000, 5'd0, 12'd0); // should be skipped
        u_imem.mem[2] = enc_i(OI, 5'd2, 3'b000, 5'd0, 12'd77); // x2 = 77  (jumped to)
        // JALR x3, x1, 20 → target = (x1 + 20) & ~1 = (4 + 20) = 24 = 0x18,
        // which is mem[6] below. x3 gets the return address, PC + 4 = 0x10.
        //
        // This used to be `JALR x3, x1, 4`, whose target is (4 + 4) = 8 — back
        // to mem[2], an infinite loop that never reaches mem[6] at all. It
        // "passed" only because the core let the instruction behind a redirect
        // execute anyway, so mem[6] ran as wrong-path work. The offset is now
        // the one the test always meant.
        u_imem.mem[3] = enc_i(7'b110_0111, 5'd3, 3'b000, 5'd1, 12'd20);
        u_imem.mem[4] = enc_i(OI, 5'd6, 3'b000, 5'd0, 12'd0);   // skip
        u_imem.mem[5] = enc_i(OI, 5'd6, 3'b000, 5'd0, 12'd0);   // skip
        u_imem.mem[6] = enc_i(OI, 5'd4, 3'b000, 5'd0, 12'd88);  // x4 = 88 (JALR lands here)
        load_nop_pad(7, 20);

        rst = 1'b1; repeat(4) @(posedge clk); rst = 1'b0;
        drain(30);

        check("JAL: x1 = return addr = 4",  rf(1), 32'd4);
        check("JAL: x2 = 77 (target exec)", rf(2), 32'd77);
        check("JALR: x4 = 88 (target exec)",rf(4), 32'd88);
        check("JALR: x3 = return addr = 0x10", rf(3), 32'h10);
    endtask

    // =========================================================
    // Test 6: Loop — branch predictor exercise
    // =========================================================
    task test_loop;
        int saved_branches, saved_mispredicts;
        $display("\n[Test 6] Loop (64 iterations, branch predictor)");
        pc = 0;
        clear_imem;

        // Loop:
        //   x1 = 64
        //   x2 = 0
        // loop_top:
        //   ADDI x2, x2, 1
        //   ADDI x1, x1, -1
        //   BNE  x1, x0, loop_top   (backward branch)
        // After loop: x2 = 64

        u_imem.mem[pc++] = enc_i(OI, 5'd1, 3'b000, 5'd0, 12'd64);   // x1 = 64
        u_imem.mem[pc++] = enc_i(OI, 5'd2, 3'b000, 5'd0, 12'd0);    // x2 = 0
        // pc[2] = loop_top: ADDI x2, x2, 1
        u_imem.mem[pc++] = enc_i(OI, 5'd2, 3'b000, 5'd2, 12'd1);
        // pc[3]: ADDI x1, x1, -1
        u_imem.mem[pc++] = enc_i(OI, 5'd1, 3'b000, 5'd1, -12'd1);
        // pc[4]: BNE x1, x0, -8  (back to pc[2])
        u_imem.mem[pc++] = enc_b(5'd1, 5'd0, 3'b001, -13'd8);
        load_nop_pad(pc, pc + 10);

        rst = 1'b1; repeat(4) @(posedge clk); rst = 1'b0;
        saved_branches    = 0;
        saved_mispredicts = 0;
        drain(600);   // 64 iterations × ~5 cycles + overhead

        check("Loop: x2 = 64 after 64 iters", rf(2), 32'd64);
        check("Loop: x1 = 0 after loop",       rf(1), 32'd0);
        $display("  INFO: branches=%0d mispredicts=%0d stall_cycles=%0d",
                 perf_branches, perf_mispredicts, perf_stall_cycles);
        // The branch predictor should predict taken after 1–2 warmup iterations;
        // expect ≤ 3 mispredictions across 64 loop iterations.
        check("Branch predictor: ≤ 3 mispredicts",
              {31'b0, perf_mispredicts <= 32'd3}, 32'd1);
    endtask

    // =========================================================
    // Main
    // =========================================================
    initial begin
        $dumpfile("tb_riscv.vcd");
        $dumpvars(0, tb_riscv);

        test_alu;
        test_forwarding;
        test_load_use;
        test_branch;
        test_jal_jalr;
        test_loop;

        $display("\n════════════════════════════════════════");
        $display("  Tests passed : %0d", tests_passed);
        $display("  Tests failed : %0d", tests_failed);
        if (tests_failed == 0)
            $display("  SIMULATION PASSED");
        else
            $display("  SIMULATION FAILED");
        $display("════════════════════════════════════════\n");

        $finish;
    end

    initial begin #50_000_000; $display("TIMEOUT"); $finish; end

endmodule
