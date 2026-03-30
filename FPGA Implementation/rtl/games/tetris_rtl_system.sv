// -----------------------------------------------------------------------------
// tetris_rtl_system.sv
// Standalone RTL Tetris subsystem that can operate in three ways:
//   mode_sel = 2'b00 : pure RTL / GPU-only autoplay (no CPU assist)
//   mode_sel = 2'b01 : CPU-assisted controls via plaintext mailbox
//   mode_sel = 2'b10 : encrypted CPU-assisted controls via ciphertext mailbox
//   mode_sel = 2'b11 : hybrid CPU+GPU mode (CPU feeds controls, GPU renders)
//
// This file instantiates se_gpu_core so the game can render using the same SE
// key/seed domain as the CPUs. The game logic itself remains small to preserve
// fit in an ECP5-85K.
// -----------------------------------------------------------------------------
module tetris_rtl_system #(
    parameter int KEY_BITS = 128
)(
    input  wire              clk,
    input  wire              rst,
    input  wire [1:0]        mode_sel,

    // shared SE key domain
    input  wire              se_enable,
    input  wire              key_update,
    input  wire [KEY_BITS-1:0] key_in,
    input  wire [63:0]       seed_in,

    // CPU control mailbox
    input  wire              cpu_ctrl_valid,
    input  wire [31:0]       cpu_ctrl_word,
    input  wire              cpu_ctrl_encrypted,
    input  wire [127:0]      cpu_ctrl_ct,

    // video out
    output wire [7:0]        vga_r,
    output wire [7:0]        vga_g,
    output wire [7:0]        vga_b,
    output wire              vga_hsync,
    output wire              vga_vsync
);
    localparam int BOARD_W = 10;
    localparam int BOARD_H = 20;

    // Simple board RAM (4-bit tiles)
    logic [3:0] board [0:BOARD_W*BOARD_H-1];

    // Active piece state (kept intentionally tiny: uses O-piece and I-piece only)
    logic [3:0] piece_id;       // 1=O, 2=I
    logic [3:0] piece_color;
    logic [4:0] piece_x;
    logic [4:0] piece_y;
    logic       piece_rot;      // used by I-piece only

    // Frame tick from GPU timing reused through local counter
    logic [19:0] frame_div;
    wire game_tick = (frame_div == 20'd0);
    always_ff @(posedge clk) begin
        if (rst) frame_div <= 20'd0;
        else frame_div <= frame_div + 20'd1;
    end

    // Control decode: bit0 left, bit1 right, bit2 rotate, bit3 soft-drop
    logic ctrl_left, ctrl_right, ctrl_rot, ctrl_drop;

    // CPU encrypted control decrypt (reuse simple AES-CTR schema)
    wire aes_key_ready;
    reg  aes_key_load;
    reg  aes_start;
    reg  [127:0] aes_block_in;
    wire aes_busy;
    wire aes_done;
    wire [127:0] aes_block_out;
    reg  [127:0] ctrl_ct_r;
    reg  ctrl_dec_pending;

    aes_enc_core #(.KEY_BITS(KEY_BITS)) u_ctrl_aes (
        .clk(clk), .rst(rst),
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
        aes_start = 1'b0;
        aes_block_in = 128'd0;
        if (ctrl_dec_pending && !aes_busy && !aes_done) begin
            aes_start = 1'b1;
            aes_block_in = {seed_in, ctrl_ct_r[127:64]};
        end
    end

    // GPU command generation
    logic gpu_cmd_valid;
    logic gpu_cmd_encrypted;
    logic [127:0] gpu_cmd_packet;
    wire  gpu_cmd_ready;

    se_gpu_core #(.KEY_BITS(KEY_BITS), .FB_W(64), .FB_H(48)) u_gpu (
        .clk(clk),
        .rst(rst),
        .se_enable(se_enable),
        .key_update(key_update),
        .key_in(key_in),
        .seed_in(seed_in),
        .cmd_valid(gpu_cmd_valid),
        .cmd_ready(gpu_cmd_ready),
        .cmd_encrypted(gpu_cmd_encrypted),
        .cmd_packet(gpu_cmd_packet),
        .vga_r(vga_r),
        .vga_g(vga_g),
        .vga_b(vga_b),
        .vga_hsync(vga_hsync),
        .vga_vsync(vga_vsync)
    );

    // helpers
    function automatic int idx(input int x, input int y);
        idx = y*BOARD_W + x;
    endfunction

    function automatic logic cell_occupied(input int x, input int y);
        begin
            if (x < 0 || x >= BOARD_W || y < 0 || y >= BOARD_H) cell_occupied = 1'b1;
            else cell_occupied = (board[idx(x,y)] != 4'd0);
        end
    endfunction

    // Return 1 if block cell exists for current piece at local cell coordinates
    function automatic logic piece_has_block(
        input logic [3:0] pid,
        input logic rot,
        input int lx,
        input int ly
    );
        begin
            piece_has_block = 1'b0;
            case (pid)
                4'd1: begin // O piece
                    piece_has_block = (lx < 2) && (ly < 2);
                end
                4'd2: begin // I piece
                    if (!rot) piece_has_block = (ly == 0) && (lx < 4);
                    else      piece_has_block = (lx == 0) && (ly < 4);
                end
                default: piece_has_block = 1'b0;
            endcase
        end
    endfunction

    function automatic logic collides(
        input logic [3:0] pid,
        input logic rot,
        input int nx,
        input int ny
    );
        logic hit;
        begin
            hit = 1'b0;
            for (int yy = 0; yy < 4; yy++) begin
                for (int xx = 0; xx < 4; xx++) begin
                    if (piece_has_block(pid, rot, xx, yy)) begin
                        if (cell_occupied(nx + xx, ny + yy)) hit = 1'b1;
                    end
                end
            end
            collides = hit;
        end
    endfunction

    task automatic lock_piece;
        begin
            for (int yy = 0; yy < 4; yy++) begin
                for (int xx = 0; xx < 4; xx++) begin
                    if (piece_has_block(piece_id, piece_rot, xx, yy)) begin
                        if ((piece_x + xx) < BOARD_W && (piece_y + yy) < BOARD_H)
                            board[idx(piece_x + xx, piece_y + yy)] <= piece_color;
                    end
                end
            end
        end
    endtask

    task automatic clear_lines;
        int y, x, yy;
        logic full;
        begin
            for (y = 0; y < BOARD_H; y++) begin
                full = 1'b1;
                for (x = 0; x < BOARD_W; x++) begin
                    if (board[idx(x,y)] == 4'd0) full = 1'b0;
                end
                if (full) begin
                    for (yy = y; yy > 0; yy--) begin
                        for (x = 0; x < BOARD_W; x++) board[idx(x,yy)] <= board[idx(x,yy-1)];
                    end
                    for (x = 0; x < BOARD_W; x++) board[idx(x,0)] <= 4'd0;
                end
            end
        end
    endtask

    task automatic spawn_piece;
        begin
            // simple alternating piece generator
            if (piece_id == 4'd1) begin
                piece_id    <= 4'd2;
                piece_color <= 4'd1;
            end else begin
                piece_id    <= 4'd1;
                piece_color <= 4'd4;
            end
            piece_x   <= 5'd3;
            piece_y   <= 5'd0;
            piece_rot <= 1'b0;
        end
    endtask

    // command packet helper (plaintext path)
    function automatic [127:0] mk_plain_cmd(
        input [7:0] opcode,
        input [3:0] color,
        input [7:0] x0,
        input [7:0] y0,
        input [7:0] x1,
        input [7:0] y1
    );
        begin
            mk_plain_cmd = {64'd0, opcode, color, 4'd0, x0, y0, x1, y1, 16'd0};
        end
    endfunction

    // very small command scheduler for drawing board to GPU
    logic [7:0] draw_x, draw_y;
    logic [2:0] draw_state;
    localparam DS_IDLE=3'd0, DS_CLEAR=3'd1, DS_BOARD=3'd2, DS_PIECE=3'd3;

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < BOARD_W*BOARD_H; i=i+1) board[i] <= 4'd0;
            piece_id <= 4'd1;
            piece_color <= 4'd4;
            piece_x <= 5'd3;
            piece_y <= 5'd0;
            piece_rot <= 1'b0;
            ctrl_left <= 1'b0; ctrl_right <= 1'b0; ctrl_rot <= 1'b0; ctrl_drop <= 1'b0;
            ctrl_ct_r <= 128'd0;
            ctrl_dec_pending <= 1'b0;
            gpu_cmd_valid <= 1'b0;
            gpu_cmd_encrypted <= 1'b0;
            gpu_cmd_packet <= 128'd0;
            draw_x <= 8'd0; draw_y <= 8'd0; draw_state <= DS_CLEAR;
        end else begin
            // defaults
            ctrl_left <= 1'b0; ctrl_right <= 1'b0; ctrl_rot <= 1'b0; ctrl_drop <= 1'b0;
            gpu_cmd_valid <= 1'b0;
            gpu_cmd_encrypted <= 1'b0;

            // CPU control mailbox
            if (cpu_ctrl_valid) begin
                if (!cpu_ctrl_encrypted) begin
                    ctrl_left  <= cpu_ctrl_word[0];
                    ctrl_right <= cpu_ctrl_word[1];
                    ctrl_rot   <= cpu_ctrl_word[2];
                    ctrl_drop  <= cpu_ctrl_word[3];
                end else begin
                    ctrl_ct_r <= cpu_ctrl_ct;
                    ctrl_dec_pending <= 1'b1;
                end
            end

            if (ctrl_dec_pending && aes_done) begin
                ctrl_left  <= (cpu_ctrl_ct[63:0] ^ aes_block_out[63:0])[0];
                ctrl_right <= (cpu_ctrl_ct[63:0] ^ aes_block_out[63:0])[1];
                ctrl_rot   <= (cpu_ctrl_ct[63:0] ^ aes_block_out[63:0])[2];
                ctrl_drop  <= (cpu_ctrl_ct[63:0] ^ aes_block_out[63:0])[3];
                ctrl_dec_pending <= 1'b0;
            end

            // Game logic tick
            if (game_tick) begin
                logic [4:0] nx, ny;
                logic nrot;
                nx = piece_x;
                ny = piece_y;
                nrot = piece_rot;

                if (mode_sel != 2'b00) begin
                    if (ctrl_left  && !collides(piece_id, piece_rot, piece_x - 1, piece_y)) nx = piece_x - 1;
                    if (ctrl_right && !collides(piece_id, piece_rot, piece_x + 1, piece_y)) nx = piece_x + 1;
                    if (ctrl_rot   && !collides(piece_id, ~piece_rot, nx, piece_y)) nrot = ~piece_rot;
                end

                if (ctrl_drop && !collides(piece_id, nrot, nx, piece_y + 1)) ny = piece_y + 1;
                else if (!collides(piece_id, nrot, nx, piece_y + 1)) ny = piece_y + 1;
                else begin
                    lock_piece();
                    clear_lines();
                    spawn_piece();
                end

                piece_x <= nx;
                piece_y <= ny;
                piece_rot <= nrot;
            end

            // Draw to GPU: always plaintext inside this minimal system, but the
            // GPU itself can be configured for encrypted command ingress by a CPU
            // or external producer. Here we use normal commands for area.
            if (gpu_cmd_ready) begin
                case (draw_state)
                    DS_CLEAR: begin
                        gpu_cmd_valid <= 1'b1;
                        gpu_cmd_packet <= mk_plain_cmd(8'h01, 4'd0, 0,0,0,0);
                        draw_x <= 8'd0;
                        draw_y <= 8'd0;
                        draw_state <= DS_BOARD;
                    end
                    DS_BOARD: begin
                        gpu_cmd_valid <= 1'b1;
                        gpu_cmd_packet <= mk_plain_cmd(8'h04, board[draw_y*BOARD_W + draw_x], draw_x, draw_y, 0, 0);
                        if (draw_x == BOARD_W-1) begin
                            draw_x <= 8'd0;
                            if (draw_y == BOARD_H-1) begin
                                draw_y <= 8'd0;
                                draw_state <= DS_PIECE;
                            end else draw_y <= draw_y + 8'd1;
                        end else draw_x <= draw_x + 8'd1;
                    end
                    DS_PIECE: begin
                        // overlay active piece one cell at a time
                        logic found;
                        found = 1'b0;
                        for (int yy = 0; yy < 4; yy++) begin
                            for (int xx = 0; xx < 4; xx++) begin
                                if (!found && piece_has_block(piece_id, piece_rot, xx, yy)) begin
                                    gpu_cmd_valid <= 1'b1;
                                    gpu_cmd_packet <= mk_plain_cmd(8'h04, piece_color, piece_x + xx, piece_y + yy, 0, 0);
                                    found = 1'b1;
                                end
                            end
                        end
                        draw_state <= DS_CLEAR;
                    end
                    default: draw_state <= DS_CLEAR;
                endcase
            end
        end
    end
endmodule
