// tb_spi.sv — Self-checking constrained-random testbench for spi_core.
//
// Test structure:
//   1. MISO is connected to MOSI (loopback), so each received word should
//      equal the transmitted word.
//   2. All four SPI modes (0..3) are exercised.
//   3. Transfer widths 4..32 bits are randomised.
//   4. Both MSB-first and LSB-first are tested.
//   5. Multiple clock divider settings are tested.
//
// Run with:
//   iverilog -g2012 -o tb_spi tb_spi.sv spi_core.sv spi_master.sv \
//            sync_fifo.sv && vvp tb_spi

`timescale 1ns/1ps

module tb_spi;

    localparam CLK_HZ = 50_000_000;
    localparam CLK_NS = 20;

    logic clk = 1'b0, rst = 1'b1;
    always #(CLK_NS/2) clk = ~clk;

    // APB
    logic        psel='0, penable='0, pwrite='0;
    logic [4:0]  paddr='0;
    logic [31:0] pwdata='0, prdata;
    logic        pready;
    logic        irq;

    // SPI loopback
    logic sck, mosi, miso_fb;
    logic [0:0] cs_n;
    assign miso_fb = mosi;   // loopback: MISO = MOSI

    spi_core #(
        .CLK_HZ(CLK_HZ),
        .TX_FIFO_DEPTH(8),
        .RX_FIFO_DEPTH(8),
        .CS_COUNT(1),
        .DIV_W(8),
        .DATA_W(32)
    ) dut (
        .clk(clk), .rst(rst),
        .psel(psel), .penable(penable), .pwrite(pwrite),
        .paddr(paddr), .pwdata(pwdata), .prdata(prdata), .pready(pready),
        .sck(sck), .mosi(mosi), .miso(miso_fb), .cs_n(cs_n),
        .irq(irq)
    );

    // ---- APB helpers -----------------------------------------------------
    task apb_write(input [4:0] addr, input [31:0] data);
        @(posedge clk); #1;
        psel=1; pwrite=1; paddr=addr; pwdata=data;
        @(posedge clk); #1; penable=1;
        @(posedge clk); #1;
        psel=0; penable=0; pwrite=0;
    endtask

    task apb_read(input [4:0] addr, output [31:0] data);
        @(posedge clk); #1;
        psel=1; pwrite=0; paddr=addr;
        @(posedge clk); #1; penable=1;
        @(posedge clk); #1; data=prdata;
        psel=0; penable=0;
    endtask

    localparam DATA_TX = 5'h00;
    localparam DATA_RX = 5'h04;
    localparam STAT    = 5'h08;
    localparam CTRL    = 5'h0C;

    // ---- Scoreboard -------------------------------------------------------
    logic [31:0] tx_q[$];
    int tests_ok = 0, tests_fail = 0;

    task check(input string name, input logic cond);
        if (cond) begin $display("  PASS: %s", name); tests_ok++; end
        else       begin $display("  FAIL: %s", name); tests_fail++; end
    endtask

    // ---- LFSR random -------------------------------------------------------
    logic [31:0] lfsr = 32'hA5A5_1234;
    function automatic logic [31:0] lfsr_next(input logic [31:0] s);
        lfsr_next = {s[30:0], s[31]^s[21]^s[1]^s[0]};
    endfunction

    function automatic int rand_range(input int lo, input int hi);
        lfsr = lfsr_next(lfsr);
        rand_range = lo + (lfsr % (hi - lo + 1));
    endfunction

    // ---- Configure SPI ---------------------------------------------------
    task configure(
        input [7:0] div,
        input [1:0] mode,
        input [5:0] bits,
        input logic lsb_first
    );
        // CTRL layout: [7:0]=div [9:8]=mode [15:10]=bits [16]=lsb_first
        // [19:17]=cs_sel [20]=cs_pol
        logic [31:0] ctrl_val;
        ctrl_val = {11'd0, 1'b0, 3'd0, lsb_first, bits, mode, div};
        apb_write(CTRL, ctrl_val);
    endtask

    // ---- One transfer phase -----------------------------------------------
    task run_phase(
        input int phase_num,
        input [7:0] div,
        input [1:0] mode,
        input [5:0] n_bits,
        input logic lsb_first,
        input int   n_words
    );
        logic [31:0] mask;
        logic [31:0] stat, rx_word;
        int          timeout;

        mask = (n_bits == 32) ? 32'hFFFF_FFFF : (32'd1 << n_bits) - 1;

        $display("\n[Phase %0d] div=%0d mode=%0d bits=%0d lsb=%0d words=%0d",
                 phase_num, div, mode, n_bits, lsb_first, n_words);

        configure(div, mode, n_bits, lsb_first);
        @(posedge clk); @(posedge clk);

        for (int i = 0; i < n_words; i++) begin
            logic [31:0] word;
            lfsr  = lfsr_next(lfsr);
            word  = lfsr & mask;
            apb_write(DATA_TX, word);
            tx_q.push_back(word);
        end

        // Drain RX and check
        while (tx_q.size() > 0) begin
            timeout = 0;
            do begin
                apb_read(STAT, stat);
                @(posedge clk);
                timeout++;
                if (timeout > 200_000) begin
                    $display("  TIMEOUT"); tests_fail++; return;
                end
            end while (stat[3]);   // rx_empty

            apb_read(DATA_RX, rx_word);
            begin
                automatic logic [31:0] exp = tx_q.pop_front() & mask;
                automatic logic [31:0] got = rx_word & mask;
                if (got !== exp) begin
                    $display("  FAIL: word=0x%08X exp=0x%08X", got, exp);
                    tests_fail++;
                end else tests_ok++;
            end
        end
    endtask

    // ---- Main -------------------------------------------------------------
    initial begin
        rst = 1'b1; repeat(4) @(posedge clk); rst = 1'b0; repeat(2) @(posedge clk);

        // ---- Modes 0..3 --------------------------------------------------
        for (int m = 0; m < 4; m++)
            run_phase(m+1, 8'd4, m[1:0], 6'd8, 1'b0, 8);

        // ---- Variable word lengths ---------------------------------------
        for (int b = 4; b <= 32; b += 4)
            run_phase(10 + b/4, 8'd3, 2'b00, b[5:0], 1'b0, 4);

        // ---- LSB-first ---------------------------------------------------
        run_phase(20, 8'd2, 2'b00, 6'd16, 1'b1, 8);
        run_phase(21, 8'd2, 2'b11, 6'd8,  1'b1, 8);

        // ---- Random phases -----------------------------------------------
        for (int p = 0; p < 10; p++) begin
            automatic int dv  = rand_range(1, 15);
            automatic int md  = rand_range(0,  3);
            automatic int nb  = rand_range(4, 32);
            automatic int lsb = rand_range(0,  1);
            automatic int nw  = rand_range(1,  6);
            run_phase(30+p, dv[7:0], md[1:0], nb[5:0], lsb[0], nw);
        end

        $display("\n════════════════════════════════════");
        $display("  Tests passed : %0d", tests_ok);
        $display("  Tests failed : %0d", tests_fail);
        if (tests_fail == 0) $display("  SPI SIMULATION PASSED");
        else                 $display("  SPI SIMULATION FAILED");
        $display("════════════════════════════════════\n");
        $finish;
    end

    initial begin #200_000_000; $display("TIMEOUT"); $finish; end

endmodule
