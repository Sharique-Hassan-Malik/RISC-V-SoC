// tb_uart.sv — Self-checking constrained-random testbench for uart_core.
//
// Test structure:
//   1. Direct loopback: tx pin connected to rx pin.
//   2. Random configuration: baud divisor, data bits (5..8), parity,
//      stop bits are randomised each test phase.
//   3. Random payloads: 1..32 bytes per burst, values 0x00..0xFF
//      (masked to the active data-bit width).
//   4. Scoreboard: every transmitted byte is stored in a queue; received
//      bytes are compared in order.
//   5. At the end: verify no framing errors, no parity errors, no overruns.
//
// Run with:
//   vcs -sverilog +define+WAVES uart_core.sv uart_tx.sv uart_rx.sv \
//       sync_fifo.sv tb_uart.sv -o sim_uart && ./sim_uart
//   or:
//   iverilog -g2012 -o tb_uart tb_uart.sv uart_core.sv uart_tx.sv \
//            uart_rx.sv sync_fifo.sv && vvp tb_uart

`timescale 1ns/1ps

module tb_uart;

    localparam CLK_HZ  = 50_000_000;
    localparam CLK_NS  = 1_000_000_000 / CLK_HZ;

    logic        clk = 1'b0;
    logic        rst = 1'b1;
    logic        uart_loop;   // TX→RX loopback

    // APB signals
    logic        psel = 0, penable = 0, pwrite = 0;
    logic [4:0]  paddr  = '0;
    logic [31:0] pwdata = '0;
    logic [31:0] prdata;
    logic        pready;
    logic        irq;

    always #(CLK_NS/2) clk = ~clk;

    // ---- DUT -------------------------------------------------------------
    uart_core #(
        .CLK_HZ(CLK_HZ),
        .TX_FIFO_DEPTH(16),
        .RX_FIFO_DEPTH(16)
    ) dut (
        .clk(clk), .rst(rst),
        .psel(psel), .penable(penable), .pwrite(pwrite),
        .paddr(paddr), .pwdata(pwdata), .prdata(prdata), .pready(pready),
        .uart_tx(uart_loop), .uart_rx(uart_loop),
        .irq(irq)
    );

    // ---- APB helpers -----------------------------------------------------
    task apb_write(input [4:0] addr, input [31:0] data);
        @(posedge clk); #1;
        psel    = 1; pwrite = 1; paddr = addr; pwdata = data;
        @(posedge clk); #1;
        penable = 1;
        @(posedge clk); #1;
        psel = 0; penable = 0; pwrite = 0;
    endtask

    task apb_read(input [4:0] addr, output [31:0] data);
        @(posedge clk); #1;
        psel    = 1; pwrite = 0; paddr = addr;
        @(posedge clk); #1;
        penable = 1;
        @(posedge clk); #1;
        data    = prdata;
        psel    = 0; penable = 0;
    endtask

    // UART register offsets
    localparam DATA_REG = 5'h00;
    localparam STAT_REG = 5'h04;
    localparam DIV_REG  = 5'h08;
    localparam CTRL_REG = 5'h0C;

    // ---- Scoreboard queue -----------------------------------------------
    byte unsigned tx_queue[$];

    // ---- Random stimulus ------------------------------------------------
    // Use a simple LFSR for portability with iverilog (no $urandom in some versions)
    logic [31:0] lfsr = 32'hDEAD_BEEF;
    function automatic logic [31:0] lfsr_next(input logic [31:0] s);
        lfsr_next = {s[30:0], s[31] ^ s[21] ^ s[1] ^ s[0]};
    endfunction

    function automatic int rand_range(input int lo, input int hi);
        lfsr = lfsr_next(lfsr);
        rand_range = lo + (lfsr % (hi - lo + 1));
    endfunction

    // ---- Test tracking --------------------------------------------------
    int tests_ok = 0, tests_fail = 0;

    task check(input string name, input logic cond);
        if (cond) begin
            $display("  PASS: %s", name); tests_ok++;
        end else begin
            $display("  FAIL: %s", name); tests_fail++;
        end
    endtask

    // ---- Configure UART -------------------------------------------------
    task configure(
        input int    div,
        input [2:0]  data_bits,  // 5..8
        input [1:0]  parity,
        input logic  stop2
    );
        logic [5:0] ctrl;
        ctrl = {stop2, parity, data_bits};
        apb_write(DIV_REG,  div);
        apb_write(CTRL_REG, {26'd0, ctrl});
    endtask

    // ---- Transmit a burst and collect received bytes --------------------
    task transmit_burst(
        input int    n_bytes,
        input [2:0]  data_bits,
        input [7:0]  bytes[]
    );
        logic [7:0] mask;
        mask = (8'hFF >> (8 - data_bits));

        for (int i = 0; i < n_bytes; i++) begin
            logic [31:0] stat;
            // Wait until TX FIFO is not full
            do begin
                apb_read(STAT_REG, stat);
            end while (stat[0]);   // bit 0 = tx_full

            apb_write(DATA_REG, {24'd0, bytes[i] & mask});
            tx_queue.push_back(bytes[i] & mask);
        end
    endtask

    // ---- Drain RX FIFO and compare against scoreboard -------------------
    task drain_and_check(input int timeout_cycles = 200_000);
        logic [31:0] stat, rd;
        int timeout;

        while (tx_queue.size() > 0) begin
            timeout = 0;
            // Wait for a byte in the RX FIFO
            do begin
                apb_read(STAT_REG, stat);
                @(posedge clk);
                timeout++;
                if (timeout > timeout_cycles) begin
                    $display("  TIMEOUT waiting for RX byte");
                    tests_fail++;
                    return;
                end
            end while (stat[3]);   // bit 3 = rx_empty

            apb_read(DATA_REG, rd);
            begin
                automatic byte exp = tx_queue.pop_front();
                automatic byte got = rd[7:0];
                if (got !== exp) begin
                    $display("  FAIL: byte mismatch got=0x%02X exp=0x%02X", got, exp);
                    tests_fail++;
                end else begin
                    tests_ok++;
                end
            end

            // Check no error flags
            apb_read(STAT_REG, stat);
            check("No framing error",  !stat[5]);
            check("No parity error",   !stat[6]);
            check("No overrun",        !stat[4]);
        end
    endtask

    // ---- One test phase -------------------------------------------------
    task run_phase(
        input int   phase_num,
        input int   div,
        input [2:0] data_bits,
        input [1:0] parity,
        input logic stop2,
        input int   n_bytes
    );
        static byte payload[];

        $display("\n[Phase %0d] div=%0d data=%0d parity=%0d stop2=%0d bytes=%0d",
                 phase_num, div, data_bits, parity, stop2, n_bytes);

        configure(div, data_bits, parity, stop2);
        // Allow new divider to take effect
        @(posedge clk); @(posedge clk);

        payload = new[n_bytes];
        for (int i = 0; i < n_bytes; i++)
            payload[i] = rand_range(0, 255);

        transmit_burst(n_bytes, data_bits, payload);
        drain_and_check(n_bytes * (div + 1) * 20 * 3);  // generous timeout
    endtask

    // ---- Main -----------------------------------------------------------
    initial begin
        `ifdef WAVES
        $dumpfile("tb_uart.vcd");
        $dumpvars(0, tb_uart);
        `endif

        rst = 1'b1;
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        // ---- Phase 1: 9600 baud 8N1 — reference case --------------------
        run_phase(1,
            CLK_HZ / 9600 - 1,
            3'd8, 2'b00, 1'b0,
            8);

        // ---- Phase 2: High baud rate 921600, 8N1 ------------------------
        run_phase(2,
            CLK_HZ / 921600 - 1,
            3'd8, 2'b00, 1'b0,
            16);

        // ---- Phase 3: 7-bit data, even parity, 2 stop bits -------------
        run_phase(3,
            CLK_HZ / 115200 - 1,
            3'd7, 2'b10, 1'b1,
            10);

        // ---- Phase 4: 5-bit data, odd parity ---------------------------
        run_phase(4,
            CLK_HZ / 57600 - 1,
            3'd5, 2'b01, 1'b0,
            12);

        // ---- Phase 5: Random configuration (10 sub-phases) -------------
        begin
            automatic int div_vals[4] = {
                CLK_HZ/9600-1,
                CLK_HZ/115200-1,
                CLK_HZ/460800-1,
                CLK_HZ/921600-1
            };
            for (int p = 0; p < 10; p++) begin
                int  dv    = div_vals[rand_range(0, 3)];
                int  db    = rand_range(5, 8);
                int  par   = rand_range(0, 2);
                int  s2    = rand_range(0, 1);
                int  nb    = rand_range(1, 24);
                run_phase(5 + p, dv, db[2:0], par[1:0], s2[0], nb);
            end
        end

        // ---- Summary ----------------------------------------------------
        $display("\n════════════════════════════════════");
        $display("  Tests passed : %0d", tests_ok);
        $display("  Tests failed : %0d", tests_fail);
        if (tests_fail == 0)
            $display("  UART SIMULATION PASSED");
        else
            $display("  UART SIMULATION FAILED");
        $display("════════════════════════════════════\n");
        $finish;
    end

    initial begin #500_000_000; $display("TIMEOUT"); $finish; end

endmodule
