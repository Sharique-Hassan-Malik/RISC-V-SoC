// Memory-mapped registers around the AES-128 core.
//
// The accelerator arrived with an AXI-lite wrapper, which is the right
// interface for a real bus and the wrong one for this SoC: the core here has a
// single-cycle load/store port, not AXI, and putting an AXI bridge between them
// to reach a block that needs four write cycles would be more interconnect than
// design.
//
// So this is the adapter: the register layout from socgen/memmap.py over the
// core's plain address/data port. Key and plaintext arrive 32 bits at a time
// because the bus is 32 bits wide and the block is 128.

`include "soc_map.svh"

module aes_regs (
    input  logic        clk,
    input  logic        rst,

    // Simple bus, matching the core's data port
    input  logic        sel,
    input  logic [11:0] addr,        // offset within the peripheral window
    input  logic [31:0] wdata,
    input  logic        we,
    output logic [31:0] rdata
);

    logic [127:0] key_q, data_q, cipher_q;
    logic         start_q, busy_q, done_q;

    logic         core_valid_o;
    logic [127:0] core_cipher_o;
    logic         load_key_q;

    aes128_core u_aes (
        .clk          (clk),
        .rst_n        (~rst),
        .load_key     (load_key_q),
        .key_i        (key_q),
        .valid_i      (start_q),
        .plaintext_i  (data_q),
        .valid_o      (core_valid_o),
        .ciphertext_o (core_cipher_o)
    );

    // -- writes --------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (rst) begin
            key_q      <= '0;
            data_q     <= '0;
            start_q    <= 1'b0;
            load_key_q <= 1'b0;
            busy_q     <= 1'b0;
            done_q     <= 1'b0;
            cipher_q   <= '0;
        end else begin
            // Both are single-cycle strobes.
            start_q    <= 1'b0;
            load_key_q <= 1'b0;

            if (sel && we) begin
                case (addr[7:0])
                    8'h00: begin key_q[31:0]    <= wdata; load_key_q <= 1'b1; end
                    8'h04: begin key_q[63:32]   <= wdata; load_key_q <= 1'b1; end
                    8'h08: begin key_q[95:64]   <= wdata; load_key_q <= 1'b1; end
                    8'h0C: begin key_q[127:96]  <= wdata; load_key_q <= 1'b1; end
                    8'h10: data_q[31:0]         <= wdata;
                    8'h14: data_q[63:32]        <= wdata;
                    8'h18: data_q[95:64]        <= wdata;
                    8'h1C: data_q[127:96]       <= wdata;
                    8'h20: if (wdata[0]) begin
                        // Starting clears done, so software polling STATUS
                        // cannot read the previous block's completion and walk
                        // off with stale ciphertext.
                        start_q <= 1'b1;
                        busy_q  <= 1'b1;
                        done_q  <= 1'b0;
                    end
                    default: ;   // writes to unmapped offsets are dropped
                endcase
            end

            if (core_valid_o) begin
                cipher_q <= core_cipher_o;
                busy_q   <= 1'b0;
                done_q   <= 1'b1;
            end
        end
    end

    // -- reads ---------------------------------------------------------------
    //
    // Registered, because the RAM on the same bus reads synchronously and the
    // core samples read data the cycle *after* it drives the address. A
    // combinational mux here returns this peripheral's value one cycle early —
    // by the time the core looks, the address has moved on and the read
    // returns whatever the next address decodes to. The symptom is a status
    // poll that never sees `done` and a program that spins forever.

    always_ff @(posedge clk) begin
        if (rst) begin
            rdata <= 32'h0;
        end else begin
            case (addr[7:0])
                8'h20:   rdata <= {31'b0, busy_q};
                8'h24:   rdata <= {31'b0, done_q};
                8'h30:   rdata <= cipher_q[31:0];
                8'h34:   rdata <= cipher_q[63:32];
                8'h38:   rdata <= cipher_q[95:64];
                8'h3C:   rdata <= cipher_q[127:96];
                default: rdata <= 32'h0;
            endcase
        end
    end

endmodule
