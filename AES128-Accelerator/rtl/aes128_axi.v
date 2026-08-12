// AES-128 AXI4-Lite Slave Wrapper
//
// Register map (all registers 32-bit, word-aligned):
//   0x00  KEY_W0     key[127:96]        write-only
//   0x04  KEY_W1     key[95:64]         write-only
//   0x08  KEY_W2     key[63:32]         write-only
//   0x0C  KEY_W3     key[31:0]          write-only
//   0x10  DIN_W0     plaintext[127:96]  write-only
//   0x14  DIN_W1     plaintext[95:64]   write-only
//   0x18  DIN_W2     plaintext[63:32]   write-only
//   0x1C  DIN_W3     plaintext[31:0]    write-only
//   0x20  CTRL       bit 0 = start      write-only
//   0x24  STATUS     bit 0 = output valid (self-clearing on read)
//   0x28  DOUT_W0    ciphertext[127:96] read-only
//   0x2C  DOUT_W1    ciphertext[95:64]  read-only
//   0x30  DOUT_W2    ciphertext[63:32]  read-only
//   0x34  DOUT_W3    ciphertext[31:0]   read-only
//
// Usage:
//   1. Write KEY_W0..W3 (triggers key expansion on CTRL.start).
//   2. Write DIN_W0..W3.
//   3. Write CTRL = 1 (start).  Both key load and encrypt begin.
//   4. Poll STATUS until bit 0 = 1 (11 cycles after start).
//   5. Read DOUT_W0..W3.  STATUS clears on the STATUS read.

module aes128_axi #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 8
)(
    input  wire                            S_AXI_ACLK,
    input  wire                            S_AXI_ARESETN,
    // Write address
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]  S_AXI_AWADDR,
    input  wire                            S_AXI_AWVALID,
    output reg                             S_AXI_AWREADY,
    // Write data
    input  wire [C_S_AXI_DATA_WIDTH-1:0]  S_AXI_WDATA,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0]S_AXI_WSTRB,
    input  wire                            S_AXI_WVALID,
    output reg                             S_AXI_WREADY,
    // Write response
    output reg  [1:0]                      S_AXI_BRESP,
    output reg                             S_AXI_BVALID,
    input  wire                            S_AXI_BREADY,
    // Read address
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]  S_AXI_ARADDR,
    input  wire                            S_AXI_ARVALID,
    output reg                             S_AXI_ARREADY,
    // Read data
    output reg  [C_S_AXI_DATA_WIDTH-1:0]  S_AXI_RDATA,
    output reg  [1:0]                      S_AXI_RRESP,
    output reg                             S_AXI_RVALID,
    input  wire                            S_AXI_RREADY
);
    // ── Internal registers ────────────────────────────────────────────────────
    reg [127:0] reg_key;
    reg [127:0] reg_din;
    reg [127:0] reg_dout;
    reg         reg_status;     // 1 = ciphertext ready

    // ── AES core signals ──────────────────────────────────────────────────────
    wire        core_valid_o;
    wire [127:0]core_ctxt;
    reg         core_load_key;
    reg         core_valid_i;

    aes128_core u_core (
        .clk         (S_AXI_ACLK),
        .rst_n       (S_AXI_ARESETN),
        .load_key    (core_load_key),
        .key_i       (reg_key),
        .valid_i     (core_valid_i),
        .plaintext_i (reg_din),
        .valid_o     (core_valid_o),
        .ciphertext_o(core_ctxt)
    );

    // Capture output
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            reg_dout   <= 128'b0;
            reg_status <= 1'b0;
        end else begin
            core_load_key <= 1'b0;
            core_valid_i  <= 1'b0;
            if (core_valid_o) begin
                reg_dout   <= core_ctxt;
                reg_status <= 1'b1;
            end
        end
    end

    // ── AXI write channel ─────────────────────────────────────────────────────
    reg [C_S_AXI_ADDR_WIDTH-1:0] aw_addr;
    reg                           aw_en;

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            S_AXI_AWREADY <= 1'b0; aw_en <= 1'b1;
        end else begin
            if (~S_AXI_AWREADY && S_AXI_AWVALID && S_AXI_WVALID && aw_en) begin
                S_AXI_AWREADY <= 1'b1; aw_addr <= S_AXI_AWADDR; aw_en <= 1'b0;
            end else begin
                S_AXI_AWREADY <= 1'b0;
                if (S_AXI_BVALID && S_AXI_BREADY) aw_en <= 1'b1;
            end
        end
    end

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            S_AXI_WREADY <= 1'b0;
        end else begin
            S_AXI_WREADY <= (~S_AXI_WREADY && S_AXI_WVALID && S_AXI_AWVALID && aw_en) ? 1'b1 : 1'b0;
        end
    end

    // Register write
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            reg_key <= 128'b0; reg_din <= 128'b0;
            core_load_key <= 1'b0; core_valid_i <= 1'b0;
        end else if (S_AXI_AWREADY && S_AXI_AWVALID && S_AXI_WREADY && S_AXI_WVALID) begin
            core_load_key <= 1'b0; core_valid_i <= 1'b0;
            case (aw_addr[7:2])
                6'h00: reg_key[127:96] <= S_AXI_WDATA;
                6'h01: reg_key[95:64]  <= S_AXI_WDATA;
                6'h02: reg_key[63:32]  <= S_AXI_WDATA;
                6'h03: reg_key[31:0]   <= S_AXI_WDATA;
                6'h04: reg_din[127:96] <= S_AXI_WDATA;
                6'h05: reg_din[95:64]  <= S_AXI_WDATA;
                6'h06: reg_din[63:32]  <= S_AXI_WDATA;
                6'h07: reg_din[31:0]   <= S_AXI_WDATA;
                6'h08: begin            // CTRL — start
                    if (S_AXI_WDATA[0]) begin
                        core_load_key <= 1'b1;
                        core_valid_i  <= 1'b1;
                        reg_status    <= 1'b0;
                    end
                end
                default: ;
            endcase
        end
    end

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            S_AXI_BVALID <= 1'b0; S_AXI_BRESP <= 2'b00;
        end else if (S_AXI_AWREADY && S_AXI_AWVALID && S_AXI_WREADY && S_AXI_WVALID && ~S_AXI_BVALID) begin
            S_AXI_BVALID <= 1'b1; S_AXI_BRESP <= 2'b00;
        end else if (S_AXI_BVALID && S_AXI_BREADY) begin
            S_AXI_BVALID <= 1'b0;
        end
    end

    // ── AXI read channel ──────────────────────────────────────────────────────
    reg [C_S_AXI_ADDR_WIDTH-1:0] ar_addr;

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            S_AXI_ARREADY <= 1'b0; ar_addr <= 0;
        end else if (~S_AXI_ARREADY && S_AXI_ARVALID) begin
            S_AXI_ARREADY <= 1'b1; ar_addr <= S_AXI_ARADDR;
        end else begin
            S_AXI_ARREADY <= 1'b0;
        end
    end

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            S_AXI_RVALID <= 1'b0; S_AXI_RRESP <= 2'b00;
        end else if (S_AXI_ARREADY && S_AXI_ARVALID && ~S_AXI_RVALID) begin
            S_AXI_RVALID <= 1'b1; S_AXI_RRESP <= 2'b00;
        end else if (S_AXI_RVALID && S_AXI_RREADY) begin
            S_AXI_RVALID <= 1'b0;
        end
    end

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            S_AXI_RDATA <= 32'b0;
        end else if (S_AXI_ARREADY && S_AXI_ARVALID && ~S_AXI_RVALID) begin
            case (ar_addr[7:2])
                6'h09: begin
                    S_AXI_RDATA  <= {31'b0, reg_status};
                    reg_status   <= 1'b0;  // self-clearing on read
                end
                6'h0A: S_AXI_RDATA <= reg_dout[127:96];
                6'h0B: S_AXI_RDATA <= reg_dout[95:64];
                6'h0C: S_AXI_RDATA <= reg_dout[63:32];
                6'h0D: S_AXI_RDATA <= reg_dout[31:0];
                default: S_AXI_RDATA <= 32'hdeadbeef;
            endcase
        end
    end

endmodule
