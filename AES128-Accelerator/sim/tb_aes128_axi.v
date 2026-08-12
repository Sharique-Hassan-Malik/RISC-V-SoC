// Testbench: aes128_axi
// Drives the AXI4-Lite slave interface and verifies the FIPS 197 Appendix B vector.

`timescale 1ns/1ps

module tb_aes128_axi;

    localparam ADDR_KEY_W0  = 8'h00;
    localparam ADDR_KEY_W1  = 8'h04;
    localparam ADDR_KEY_W2  = 8'h08;
    localparam ADDR_KEY_W3  = 8'h0C;
    localparam ADDR_DIN_W0  = 8'h10;
    localparam ADDR_DIN_W1  = 8'h14;
    localparam ADDR_DIN_W2  = 8'h18;
    localparam ADDR_DIN_W3  = 8'h1C;
    localparam ADDR_CTRL    = 8'h20;
    localparam ADDR_STATUS  = 8'h24;
    localparam ADDR_DOUT_W0 = 8'h28;
    localparam ADDR_DOUT_W1 = 8'h2C;
    localparam ADDR_DOUT_W2 = 8'h30;
    localparam ADDR_DOUT_W3 = 8'h34;

    reg         clk, rst_n;
    reg  [7:0]  awaddr; reg  awvalid;  wire awready;
    reg  [31:0] wdata;  reg  wvalid;   wire wready;
    wire [1:0]  bresp;  wire bvalid;   reg  bready;
    reg  [7:0]  araddr; reg  arvalid;  wire arready;
    wire [31:0] rdata;  wire [1:0] rresp; wire rvalid; reg rready;

    aes128_axi dut (
        .S_AXI_ACLK   (clk),    .S_AXI_ARESETN(rst_n),
        .S_AXI_AWADDR (awaddr), .S_AXI_AWVALID(awvalid), .S_AXI_AWREADY(awready),
        .S_AXI_WDATA  (wdata),  .S_AXI_WSTRB  (4'hf),
        .S_AXI_WVALID (wvalid), .S_AXI_WREADY (wready),
        .S_AXI_BRESP  (bresp),  .S_AXI_BVALID (bvalid),  .S_AXI_BREADY (bready),
        .S_AXI_ARADDR (araddr), .S_AXI_ARVALID(arvalid), .S_AXI_ARREADY(arready),
        .S_AXI_RDATA  (rdata),  .S_AXI_RRESP  (rresp),
        .S_AXI_RVALID (rvalid), .S_AXI_RREADY (rready)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // AXI write transaction
    task axi_write;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(posedge clk); #1;
            awaddr = addr; awvalid = 1;
            wdata  = data; wvalid  = 1;
            bready = 1;
            // Wait for both handshakes
            wait (awready && wready);
            @(posedge clk); #1;
            awvalid = 0; wvalid = 0;
            wait (bvalid);
            @(posedge clk); #1;
            bready = 0;
        end
    endtask

    // AXI read transaction
    reg [31:0] rd_data;
    task axi_read;
        input  [7:0]  addr;
        output [31:0] data;
        begin
            @(posedge clk); #1;
            araddr = addr; arvalid = 1; rready = 1;
            wait (arready);
            @(posedge clk); #1;
            arvalid = 0;
            wait (rvalid);
            data = rdata;
            @(posedge clk); #1;
            rready = 0;
        end
    endtask

    integer fail_count;
    reg [127:0] key   = 128'h2b7e151628aed2a6abf7158809cf4f3c;
    reg [127:0] plain = 128'h3243f6a8885a308d313198a2e0370734;
    reg [127:0] exp   = 128'h3925841d02dc09fbdc118597196a0b32;
    reg [31:0]  status_val;
    reg [127:0] ctxt;
    integer     timeout;

    initial begin
        fail_count = 0;
        awvalid = 0; wvalid = 0; bready = 0;
        arvalid = 0; rready = 0;
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Write key
        axi_write(ADDR_KEY_W0, key[127:96]);
        axi_write(ADDR_KEY_W1, key[95:64]);
        axi_write(ADDR_KEY_W2, key[63:32]);
        axi_write(ADDR_KEY_W3, key[31:0]);

        // Write plaintext
        axi_write(ADDR_DIN_W0, plain[127:96]);
        axi_write(ADDR_DIN_W1, plain[95:64]);
        axi_write(ADDR_DIN_W2, plain[63:32]);
        axi_write(ADDR_DIN_W3, plain[31:0]);

        // Start
        axi_write(ADDR_CTRL, 32'h1);

        // Poll STATUS (wait up to 200 cycles)
        status_val = 0; timeout = 0;
        while (status_val[0] == 0 && timeout < 200) begin
            axi_read(ADDR_STATUS, status_val);
            timeout = timeout + 1;
        end

        if (!status_val[0]) begin
            $display("FAIL: STATUS never went high (timeout)");
            fail_count = fail_count + 1;
        end else begin
            // Read ciphertext
            axi_read(ADDR_DOUT_W0, ctxt[127:96]);
            axi_read(ADDR_DOUT_W1, ctxt[95:64]);
            axi_read(ADDR_DOUT_W2, ctxt[63:32]);
            axi_read(ADDR_DOUT_W3, ctxt[31:0]);

            if (ctxt !== exp) begin
                $display("FAIL: ciphertext %h  expected %h", ctxt, exp);
                fail_count = fail_count + 1;
            end else begin
                $display("PASS: ciphertext %h", ctxt);
            end
        end

        if (fail_count == 0)
            $display("AXI interface test PASSED.");
        else
            $display("AXI interface test FAILED (%0d error(s)).", fail_count);

        $finish;
    end

    initial begin #500000; $display("TIMEOUT"); $finish; end

endmodule
