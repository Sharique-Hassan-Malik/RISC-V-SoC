// tb_synth.v — Testbench for synth_top.
//
// Simulates:
//   1. A 12 MHz master clock.
//   2. A MIDI Note On (C4, velocity 100) after 1 ms.
//   3. A MIDI Note Off after 200 ms.
//   4. A second Note On (E4) while the first is still releasing.
//   5. CC 5 (attack rate) and CC 7 (sustain level) changes.
//
// Captures PDM output and writes a raw 1-bit sample file for analysis.
// The sim runs for 500 ms of simulated audio time (24 000 000 clock cycles).
//
// Run with:
//   iverilog -g2012 -o tb_synth tb_synth.v synth_top.v dds_osc.v \
//            adsr_env.v q15_mul.v biquad_df1.v midi_rx.v voice_alloc.v \
//            note_to_phase.v sample_clk.v voice_mixer.v pwm_dac.v \
//            cc_store.v
//   vvp tb_synth
//
// Requires sine1024_q15.hex and note_phase_48k.hex in the working directory
// (generate with: python3 gen_hex.py).

`timescale 1ns/1ps

module tb_synth;

    localparam CLK_PERIOD  = 83;       // ns, ~12 MHz
    localparam MIDI_BIT_NS = 32000;    // 1 / 31250 baud × 1e9 = 32 µs per bit

    reg  clk       = 1'b0;
    reg  midi_rx   = 1'b1;    // idle high
    wire pdm_out;
    wire led0, led1, led2, led3, led4;

    always #(CLK_PERIOD/2) clk = ~clk;

    synth_top dut (
        .clk         (clk),
        .midi_rx_pin (midi_rx),
        .pdm_out_pin (pdm_out),
        .led0(led0), .led1(led1), .led2(led2), .led3(led3), .led4(led4)
    );

    // ---- MIDI byte sender task -------------------------------------------
    task send_midi_byte;
        input [7:0] data;
        integer i;
        begin
            // Start bit
            midi_rx = 1'b0;
            #MIDI_BIT_NS;
            // 8 data bits LSB first
            for (i = 0; i < 8; i = i+1) begin
                midi_rx = data[i];
                #MIDI_BIT_NS;
            end
            // Stop bit
            midi_rx = 1'b1;
            #MIDI_BIT_NS;
        end
    endtask

    task send_note_on;
        input [7:0] note;
        input [7:0] vel;
        begin
            send_midi_byte(8'h90);   // Note On, channel 1
            send_midi_byte(note);
            send_midi_byte(vel);
        end
    endtask

    task send_note_off;
        input [7:0] note;
        begin
            send_midi_byte(8'h80);
            send_midi_byte(note);
            send_midi_byte(8'h40);
        end
    endtask

    task send_cc;
        input [7:0] cc_num;
        input [7:0] cc_val;
        begin
            send_midi_byte(8'hB0);
            send_midi_byte(cc_num);
            send_midi_byte(cc_val);
        end
    endtask

    // ---- PDM capture to file --------------------------------------------
    integer pdm_file;
    initial begin
        pdm_file = $fopen("pdm_out.bin", "wb");
    end

    reg [7:0] pdm_byte;
    reg [2:0] pdm_bit_cnt = 0;
    always @(posedge clk) begin
        pdm_byte = {pdm_out, pdm_byte[7:1]};
        pdm_bit_cnt <= pdm_bit_cnt + 1;
        if (pdm_bit_cnt == 7)
            $fwrite(pdm_file, "%c", pdm_byte);
    end

    // ---- Stimulus --------------------------------------------------------
    integer cc;

    initial begin
        $dumpfile("tb_synth.vcd");
        $dumpvars(0, tb_synth);

        // Wait 1 ms for reset to settle.
        #1_000_000;

        // CC 5: medium attack (value 20 ≈ 10 ms attack).
        send_cc(8'd5, 8'd20);
        #100_000;

        // CC 7: sustain level 80%.
        send_cc(8'd7, 8'd100);
        #100_000;

        // Note On: C4 (MIDI 60), velocity 100.
        $display("[%0t ns] Note On C4", $time);
        send_note_on(8'd60, 8'd100);

        // Hold 150 ms.
        #150_000_000;

        // Note On: E4 (MIDI 64) while C4 still active.
        $display("[%0t ns] Note On E4", $time);
        send_note_on(8'd64, 8'd90);
        #50_000_000;

        // Note Off C4.
        $display("[%0t ns] Note Off C4", $time);
        send_note_off(8'd60);
        #50_000_000;

        // Note On: G4 (MIDI 67).
        $display("[%0t ns] Note On G4", $time);
        send_note_on(8'd67, 8'd80);
        #100_000_000;

        // Note Off E4 and G4.
        send_note_off(8'd64);
        send_note_off(8'd67);

        // Let release finish.
        #100_000_000;

        $fclose(pdm_file);
        $display("Simulation complete. PDM output in pdm_out.bin.");
        $display("Decode with: python3 decode_pdm.py pdm_out.bin");
        $finish;
    end

    // Timeout guard.
    initial begin
        #600_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
