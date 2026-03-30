// -----------------------------------------------------------------------------
// vga_timing.sv
// Minimal 640x480@60Hz VGA timing generator (25.175 MHz nominal).
//
// This is "good enough" for most monitors when driven near 25 MHz.
// For HDMI you would feed this pixel stream into a TMDS encoder/serializer.
// -----------------------------------------------------------------------------
module vga_timing #(
    parameter int H_VISIBLE = 640,
    parameter int H_FRONT   = 16,
    parameter int H_SYNC    = 96,
    parameter int H_BACK    = 48,
    parameter int V_VISIBLE = 480,
    parameter int V_FRONT   = 10,
    parameter int V_SYNC    = 2,
    parameter int V_BACK    = 33
)(
    input  wire clk,
    input  wire rst,

    output logic [11:0] x,
    output logic [11:0] y,
    output logic        hsync,
    output logic        vsync,
    output logic        active,

    // One-cycle pulse at the start of each frame (y==0,x==0)
    output logic        frame_tick
);

    localparam int H_TOTAL = H_VISIBLE + H_FRONT + H_SYNC + H_BACK;
    localparam int V_TOTAL = V_VISIBLE + V_FRONT + V_SYNC + V_BACK;

    logic [11:0] hcnt, vcnt;

    always_ff @(posedge clk) begin
        if (rst) begin
            hcnt <= 12'd0;
            vcnt <= 12'd0;
        end else begin
            if (hcnt == H_TOTAL-1) begin
                hcnt <= 12'd0;
                if (vcnt == V_TOTAL-1) vcnt <= 12'd0;
                else vcnt <= vcnt + 12'd1;
            end else begin
                hcnt <= hcnt + 12'd1;
            end
        end
    end

    always_comb begin
        x = hcnt;
        y = vcnt;

        active = (hcnt < H_VISIBLE) && (vcnt < V_VISIBLE);

        // sync pulses are typically active-low
        hsync = ~((hcnt >= (H_VISIBLE + H_FRONT)) && (hcnt < (H_VISIBLE + H_FRONT + H_SYNC)));
        vsync = ~((vcnt >= (V_VISIBLE + V_FRONT)) && (vcnt < (V_VISIBLE + V_FRONT + V_SYNC)));

        frame_tick = (hcnt == 12'd0) && (vcnt == 12'd0);
    end

endmodule
