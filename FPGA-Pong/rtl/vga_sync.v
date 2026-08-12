// vga_sync.v — 640×480 @ 60 Hz VGA sync generator.
//
// Pixel clock: 25 MHz (CLK_HZ parameter).
//
// Horizontal: 640 visible + 16 FP + 96 sync + 48 BP = 800 total
// Vertical:   480 visible + 10 FP +  2 sync + 33 BP = 525 total
// Both sync pulses are active-low (negative polarity).
//
// Outputs:
//   hsync, vsync  — sync signals (active low)
//   active        — high in the visible region
//   hpos          — current horizontal pixel (0..639), valid when active
//   vpos          — current vertical   line  (0..479), valid when active

module vga_sync (
    input  wire        pclk,
    input  wire        rst,
    output wire        hsync,
    output wire        vsync,
    output wire        active,
    output wire [9:0]  hpos,
    output wire [9:0]  vpos
);

    // Horizontal timing
    localparam H_VIS   = 640;
    localparam H_FP    =  16;
    localparam H_SYNC  =  96;
    localparam H_BP    =  48;
    localparam H_TOTAL = 800;

    // Vertical timing
    localparam V_VIS   = 480;
    localparam V_FP    =  10;
    localparam V_SYNC  =   2;
    localparam V_BP    =  33;
    localparam V_TOTAL = 525;

    reg [9:0] hcnt = 10'd0;
    reg [9:0] vcnt = 10'd0;

    always @(posedge pclk) begin
        if (rst) begin
            hcnt <= 10'd0;
            vcnt <= 10'd0;
        end else begin
            if (hcnt == H_TOTAL - 1) begin
                hcnt <= 10'd0;
                vcnt <= (vcnt == V_TOTAL - 1) ? 10'd0 : vcnt + 1;
            end else begin
                hcnt <= hcnt + 1;
            end
        end
    end

    assign hsync  = ~(hcnt >= H_VIS + H_FP && hcnt < H_VIS + H_FP + H_SYNC);
    assign vsync  = ~(vcnt >= V_VIS + V_FP && vcnt < V_VIS + V_FP + V_SYNC);
    assign active =  (hcnt < H_VIS) && (vcnt < V_VIS);
    assign hpos   = hcnt;
    assign vpos   = vcnt;

endmodule
