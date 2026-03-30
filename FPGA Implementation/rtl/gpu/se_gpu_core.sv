// -----------------------------------------------------------------------------
// se_gpu_core.sv
// Small SE-aware 2D GPU / display engine.
//
// Purpose:
// - acts as a complement to the CPU for graphics-oriented work
// - accepts normal or encrypted command packets
// - renders a tiny tile/pixel space to VGA-style outputs
// - can share the same external SE key manager as the CPU cores
//
// Command packet format:
//   Plain:      cmd_payload[63:0]
//   Encrypted:  cmd_packet[127:64]=ctr, cmd_packet[63:0]=enc_payload
//
// Supported command payload encoding:
//   [63:56] opcode
//   [55:48] color / tile / misc
//   [47:40] x0
//   [39:32] y0
//   [31:24] x1 / width
//   [23:16] y1 / height
//   [15:0]  misc
//
// Opcodes:
//   0x00 NOP
//   0x01 CLEAR(color)
//   0x02 SET_PIXEL(x0,y0,color)
//   0x03 FILL_RECT(x0,y0,w,h,color)
//   0x04 SET_TILE(x0,y0,color)
//   0x05 PRESENT / fence marker
// -----------------------------------------------------------------------------
module se_gpu_core #(
    parameter int KEY_BITS = 128,
    parameter int FB_W = 64,
    parameter int FB_H = 48
)(
    input  wire         clk,
    input  wire         rst,

    input  wire         se_enable,
    input  wire         key_update,
    input  wire [KEY_BITS-1:0] key_in,
    input  wire [63:0]  seed_in,

    input  wire         cmd_valid,
    output wire         cmd_ready,
    input  wire         cmd_encrypted,
    input  wire [127:0] cmd_packet,

    output logic [7:0]  vga_r,
    output logic [7:0]  vga_g,
    output logic [7:0]  vga_b,
    output logic        vga_hsync,
    output logic        vga_vsync
);
    // -------------------------------------------------------------------------
    // VGA timing (640x480-style reference timing)
    // -------------------------------------------------------------------------
    logic [11:0] px_x, px_y;
    logic px_active;
    logic frame_tick;

    vga_timing u_vga (
        .clk(clk),
        .rst(rst),
        .x(px_x),
        .y(px_y),
        .hsync(vga_hsync),
        .vsync(vga_vsync),
        .active(px_active),
        .frame_tick(frame_tick)
    );

    // -------------------------------------------------------------------------
    // Tiny framebuffer (4-bit indexed color) kept intentionally small.
    // -------------------------------------------------------------------------
    localparam int FB_CELLS = FB_W * FB_H;
    logic [3:0] fb [0:FB_CELLS-1];

    function automatic [23:0] palette(input logic [3:0] c);
        begin
            unique case (c)
                4'h0: palette = 24'h000000;
                4'h1: palette = 24'h00FFFF;
                4'h2: palette = 24'h0000FF;
                4'h3: palette = 24'hFFA500;
                4'h4: palette = 24'hFFFF00;
                4'h5: palette = 24'h00FF00;
                4'h6: palette = 24'h800080;
                4'h7: palette = 24'hFF0000;
                4'h8: palette = 24'h808080;
                4'h9: palette = 24'hFFFFFF;
                default: palette = 24'h202020;
            endcase
        end
    endfunction

    // -------------------------------------------------------------------------
    // AES-based command decrypt (CTR-like, same external key schema as CPU SE).
    // -------------------------------------------------------------------------
    wire aes_key_ready;
    reg  aes_key_load;
    reg  aes_start;
    reg  [127:0] aes_block_in;
    wire aes_busy;
    wire aes_done;
    wire [127:0] aes_block_out;

    aes_enc_core #(.KEY_BITS(KEY_BITS)) u_aes (
        .clk(clk),
        .rst(rst),
        .key_load(aes_key_load),
        .key_in(key_in),
        .key_ready(aes_key_ready),
        .start(aes_start),
        .block_in(aes_block_in),
        .busy(aes_busy),
        .done(aes_done),
        .block_out(aes_block_out)
    );

    always_comb begin
        aes_key_load = key_update;
    end

    typedef enum logic [2:0] {S_IDLE, S_DEC, S_EXEC, S_CLEAR, S_FILL} state_t;
    state_t state;

    logic [127:0] cmd_r;
    logic [63:0]  payload;
    logic [7:0]   opcode;
    logic [3:0]   color;
    logic [7:0]   x0, y0, x1, y1;
    logic [7:0]   cx, cy;

    assign cmd_ready = (state == S_IDLE) && (!cmd_encrypted || aes_key_ready || !se_enable);

    always_comb begin
        aes_start = 1'b0;
        aes_block_in = 128'd0;
        if (state == S_DEC && !aes_busy && !aes_done) begin
            aes_start = 1'b1;
            aes_block_in = {seed_in, cmd_r[127:64]};
        end
    end

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            payload <= 64'd0;
            opcode <= 8'd0;
            color <= 4'd0;
            x0 <= 8'd0; y0 <= 8'd0; x1 <= 8'd0; y1 <= 8'd0;
            cx <= 8'd0; cy <= 8'd0;
            for (i = 0; i < FB_CELLS; i=i+1) fb[i] <= 4'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (cmd_valid && cmd_ready) begin
                        cmd_r <= cmd_packet;
                        if (cmd_encrypted && se_enable) state <= S_DEC;
                        else begin
                            payload <= cmd_packet[63:0];
                            state <= S_EXEC;
                        end
                    end
                end

                S_DEC: begin
                    if (aes_done) begin
                        payload <= cmd_r[63:0] ^ aes_block_out[63:0];
                        state <= S_EXEC;
                    end
                end

                S_EXEC: begin
                    opcode <= payload[63:56];
                    color  <= payload[55:52];
                    x0     <= payload[47:40];
                    y0     <= payload[39:32];
                    x1     <= payload[31:24];
                    y1     <= payload[23:16];

                    unique case (payload[63:56])
                        8'h00: state <= S_IDLE; // NOP
                        8'h01: begin // CLEAR
                            cx <= 8'd0;
                            cy <= 8'd0;
                            state <= S_CLEAR;
                        end
                        8'h02: begin // SET_PIXEL
                            if ((payload[47:40] < FB_W) && (payload[39:32] < FB_H))
                                fb[payload[39:32]*FB_W + payload[47:40]] <= payload[55:52];
                            state <= S_IDLE;
                        end
                        8'h03: begin // FILL_RECT
                            cx <= 8'd0;
                            cy <= 8'd0;
                            state <= S_FILL;
                        end
                        8'h04: begin // SET_TILE (same as SET_PIXEL for this tiny GPU)
                            if ((payload[47:40] < FB_W) && (payload[39:32] < FB_H))
                                fb[payload[39:32]*FB_W + payload[47:40]] <= payload[55:52];
                            state <= S_IDLE;
                        end
                        default: state <= S_IDLE;
                    endcase
                end

                S_CLEAR: begin
                    fb[cy*FB_W + cx] <= color;
                    if (cx == FB_W-1) begin
                        cx <= 8'd0;
                        if (cy == FB_H-1) begin
                            cy <= 8'd0;
                            state <= S_IDLE;
                        end else begin
                            cy <= cy + 8'd1;
                        end
                    end else begin
                        cx <= cx + 8'd1;
                    end
                end

                S_FILL: begin
                    if (((x0 + cx) < FB_W) && ((y0 + cy) < FB_H))
                        fb[(y0 + cy)*FB_W + (x0 + cx)] <= color;

                    if (cx == x1-1) begin
                        cx <= 8'd0;
                        if (cy == y1-1) begin
                            cy <= 8'd0;
                            state <= S_IDLE;
                        end else begin
                            cy <= cy + 8'd1;
                        end
                    end else begin
                        cx <= cx + 8'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Render framebuffer to VGA (pixel doubled / scaled).
    // -------------------------------------------------------------------------
    wire [7:0] fb_x = px_x[9:3]; // divide by 8 -> 80 cols, use first 64
    wire [7:0] fb_y = px_y[8:3]; // divide by 8 -> 60 rows, use first 48
    logic [23:0] rgb;

    always_comb begin
        if (px_active && (fb_x < FB_W) && (fb_y < FB_H)) rgb = palette(fb[fb_y*FB_W + fb_x]);
        else rgb = 24'h000000;
        vga_r = rgb[23:16];
        vga_g = rgb[15:8];
        vga_b = rgb[7:0];
    end
endmodule
