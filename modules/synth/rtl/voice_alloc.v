// voice_alloc.v — 4-voice MIDI note allocator.
//
// Receives note-on / note-off messages from midi_rx and assigns them to
// one of VOICES voice slots.  Implements round-robin allocation with
// steal-oldest on overflow (the voice that has been active the longest
// is stolen when all slots are busy).
//
// Outputs:
//   voice_gate[v]      1 when voice v is active (envelope gate signal)
//   voice_note[v*8+:8] MIDI note number for voice v
//   voice_vel[v*8+:8]  Velocity for voice v (for future amplitude scaling)
//
// VOICES must be a power of two.  Default 4.

module voice_alloc #(
    parameter VOICES = 4
) (
    input  wire                  clk,
    input  wire                  rst,
    // From midi_rx
    input  wire [1:0]            msg_type,   // 01=NoteOn 10=NoteOff 11=CC
    input  wire [7:0]            msg_b1,     // note or CC number
    input  wire [7:0]            msg_b2,     // velocity or CC value
    input  wire                  msg_valid,
    // Voice assignment outputs
    output reg  [VOICES-1:0]     voice_gate,
    output reg  [VOICES*8-1:0]   voice_note,
    output reg  [VOICES*8-1:0]   voice_vel
);

    localparam V_BITS = $clog2(VOICES);

    // Age counter per voice — increments each sample; newer voices have
    // higher counters.  The voice with the highest counter is "oldest"
    // in the sense that it was assigned the longest ago.
    reg [15:0] age [0:VOICES-1];
    reg [7:0]  note_held [0:VOICES-1];   // note number per voice
    reg        active [0:VOICES-1];      // 1 = voice is gated

    integer i;

    // ---- Find oldest active voice (for stealing) -------------------------
    reg [V_BITS-1:0] oldest_voice;
    reg [15:0]       oldest_age;
    reg              any_free;
    reg [V_BITS-1:0] free_voice;

    // ---- Allocation logic ------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            voice_gate <= {VOICES{1'b0}};
            voice_note <= {VOICES*8{1'b0}};
            voice_vel  <= {VOICES*8{1'b0}};
            for (i = 0; i < VOICES; i = i+1) begin
                age[i]       <= 16'h0;
                note_held[i] <= 8'h0;
                active[i]    <= 1'b0;
            end
        end else begin

            // Age all active voices.
            for (i = 0; i < VOICES; i = i+1)
                if (active[i]) age[i] <= age[i] + 1;

            if (msg_valid) begin

                if (msg_type == 2'b01) begin
                    // ---- Note On ----------------------------------------
                    // Search for a free voice first; if none, steal oldest.
                    any_free    = 1'b0;
                    free_voice  = {V_BITS{1'b0}};
                    oldest_age  = 16'h0;
                    oldest_voice = {V_BITS{1'b0}};

                    for (i = 0; i < VOICES; i = i+1) begin
                        if (!active[i] && !any_free) begin
                            any_free   = 1'b1;
                            free_voice = i[V_BITS-1:0];
                        end
                        if (active[i] && age[i] > oldest_age) begin
                            oldest_age   = age[i];
                            oldest_voice = i[V_BITS-1:0];
                        end
                    end

                    begin
                        integer v;
                        v = any_free ? free_voice : oldest_voice;
                        active[v]                        <= 1'b1;
                        age[v]                           <= 16'h0;
                        note_held[v]                     <= msg_b1;
                        voice_gate[v]                    <= 1'b1;
                        voice_note[v*8 +: 8]             <= msg_b1;
                        voice_vel [v*8 +: 8]             <= msg_b2;
                    end

                end else if (msg_type == 2'b10) begin
                    // ---- Note Off ---------------------------------------
                    for (i = 0; i < VOICES; i = i+1) begin
                        if (active[i] && note_held[i] == msg_b1) begin
                            voice_gate[i] <= 1'b0;
                            active[i]     <= 1'b0;
                        end
                    end
                end
            end
        end
    end

endmodule
