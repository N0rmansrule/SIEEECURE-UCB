// -----------------------------------------------------------------------------
// gpu_tetris_engine.sv
//
// A tiny, FPGA-friendly "GPU" that renders a Tetris board into a VGA pixel
// stream. A small command ROM updates the 10x20 board over time to create a
// simple falling-piece animation.
//
// Two modes:
//   1) Plain ROM: command payloads are unencrypted.
//   2) Encrypted ROM: command entries are SIEEECURE-style ciphertext and are
//      decrypted on the fly using AES-CTR-like keystream generation.
//
// This engine is intentionally small so it can fit alongside multiple CPU
// cores in an ECP5-85K.
// -----------------------------------------------------------------------------
module gpu_tetris_engine #(
    parameter bit ENCRYPTED_ROM = 1'b0,
    parameter int KEY_BITS = 128,
    parameter logic [KEY_BITS-1:0] GPU_KEY  = 128'h00010203_04050607_08090a0b_0c0d0e0f,
    parameter logic [63:0]         GPU_SEED = 64'h11223344_55667788
)(
    input  wire clk,
    input  wire rst,

    // VGA-like output (active-low syncs)
    output logic [7:0] vga_r,
    output logic [7:0] vga_g,
    output logic [7:0] vga_b,
    output logic       vga_hsync,
    output logic       vga_vsync
);
    import gpu_pkg::*;

    // -------------------------------------------------------------------------
    // VGA timing (640x480)
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
    // Board memory: 10x20, 4-bit tiles (very small; implemented as regs/LUTRAM)
    // -------------------------------------------------------------------------
    localparam int BOARD_CELLS = BOARD_W*BOARD_H;
    logic [3:0] board_mem [0:BOARD_CELLS-1];

    // -------------------------------------------------------------------------
    // Command ROM (plaintext or encrypted)
    // -------------------------------------------------------------------------
    logic [7:0]   cmd_pc;
    logic [127:0] rom_entry;

    generate
        if (ENCRYPTED_ROM) begin : GEN_ROM_ENC
            tetris_cmd_rom_enc u_rom (.addr(cmd_pc), .data(rom_entry));
        end else begin : GEN_ROM_PLAIN
            tetris_cmd_rom_plain u_rom (.addr(cmd_pc), .data(rom_entry));
        end
    endgenerate

    // Split ROM entry
    wire [63:0] rom_ctr        = rom_entry[127:64];
    wire [63:0] rom_data64     = rom_entry[63:0]; // payload or enc_payload
    wire [7:0]  rom_opcode_raw = rom_data64[63:56];

    // -------------------------------------------------------------------------
    // AES core (used only when ENCRYPTED_ROM=1)
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
        .key_in(GPU_KEY),
        .key_ready(aes_key_ready),
        .start(aes_start),
        .block_in(aes_block_in),
        .busy(aes_busy),
        .done(aes_done),
        .block_out(aes_block_out)
    );

    // One-cycle key_load pulse after reset
    logic key_pulse;
    always_ff @(posedge clk) begin
        if (rst) key_pulse <= 1'b1;
        else if (key_pulse) key_pulse <= 1'b0;
    end
    always_comb begin
        aes_key_load = key_pulse;
    end

    // -------------------------------------------------------------------------
    // Command processor (very small FSM)
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {S_FETCH, S_AES_WAIT, S_EXEC, S_CLEAR, S_WAIT, S_HALT} state_t;
    state_t state;

    logic [63:0] payload;          // decrypted or plaintext payload
    logic [7:0]  opcode;
    logic [3:0]  arg_val;
    logic [3:0]  arg_x;
    logic [4:0]  arg_y;
    logic [15:0] arg_frames;

    logic [7:0] clear_idx;
    logic [15:0] wait_ctr;


    // AES start pulse control
    logic aes_start_pulse;

    always_comb begin
        aes_start     = 1'b0;
        aes_block_in  = 128'd0;
        aes_start_pulse = 1'b0;

        if (state == S_AES_WAIT) begin
            if (!aes_busy && !aes_done) begin
                aes_start = 1'b1;
                aes_block_in = {GPU_SEED, rom_ctr};
            end
        end
    end

    // Decode helpers (from payload)
    always_comb begin
        opcode = payload[63:56];
        arg_val = payload[55:52];
        arg_x   = payload[51:48];
        arg_y   = payload[47:43];
        arg_frames = payload[15:0];
    end

    integer idx;
    always_ff @(posedge clk) begin
        if (rst) begin
            cmd_pc <= 8'd0;
            state  <= S_FETCH;
            payload <= 64'd0;

            clear_idx <= 8'd0;
            wait_ctr  <= 16'd0;

            // init board to empty
            for (idx = 0; idx < BOARD_CELLS; idx = idx + 1) begin
                board_mem[idx] <= 4'd0;
            end
        end else begin
            case (state)
                S_FETCH: begin
                    if (ENCRYPTED_ROM) begin
                        // Start AES keystream for this command
                        if (aes_key_ready) begin
                            state <= S_AES_WAIT;
                        end
                    end else begin
                        payload <= rom_data64; // plaintext
                        state <= S_EXEC;
                    end
                end

                S_AES_WAIT: begin
                    if (aes_done) begin
                        payload <= rom_data64 ^ aes_block_out[63:0];
                        state <= S_EXEC;
                    end
                end

                S_EXEC: begin
                    unique case (opcode)
                        GPUCMD_NOP: begin
                            cmd_pc <= cmd_pc + 8'd1;
                            state <= S_FETCH;
                        end

                        GPUCMD_CLEAR: begin
                            clear_idx <= 8'd0;
                            state <= S_CLEAR;
                        end

                        GPUCMD_SET_CELL: begin
                            if ((arg_x < BOARD_W) && (arg_y < BOARD_H)) begin
                                // index = y*10 + x = (y<<3)+(y<<1)+x
                                int bi;
                                bi = (arg_y << 3) + (arg_y << 1) + arg_x;
                                board_mem[bi] <= arg_val;
                            end
                            cmd_pc <= cmd_pc + 8'd1;
                            state <= S_FETCH;
                        end

                        GPUCMD_WAIT: begin
                            wait_ctr <= arg_frames;
                            state <= S_WAIT;
                        end

                        GPUCMD_END: begin
                            state <= S_HALT;
                        end

                        default: begin
                            cmd_pc <= cmd_pc + 8'd1;
                            state <= S_FETCH;
                        end
                    endcase
                end

                S_CLEAR: begin
                    board_mem[clear_idx] <= 4'd0;
                    if (clear_idx == BOARD_CELLS-1) begin
                        cmd_pc <= cmd_pc + 8'd1;
                        state <= S_FETCH;
                    end else begin
                        clear_idx <= clear_idx + 8'd1;
                    end
                end

                S_WAIT: begin
                    if (frame_tick) begin
                        if (wait_ctr == 16'd0) begin
                            cmd_pc <= cmd_pc + 8'd1;
                            state <= S_FETCH;
                        end else begin
                            wait_ctr <= wait_ctr - 16'd1;
                        end
                    end
                end

                S_HALT: begin
                    // Hold last frame
                    state <= S_HALT;
                end

                default: state <= S_FETCH;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Pixel renderer (combinational)
    // Uses a power-of-two cell size (16x16) to avoid expensive divides.
    // -------------------------------------------------------------------------
    localparam int CELL_SHIFT = 4;           // 2^4 = 16 px per cell
    localparam int CELL_SIZE  = 1 << CELL_SHIFT;
    localparam int BOARD_PX_W = BOARD_W * CELL_SIZE; // 160
    localparam int BOARD_PX_H = BOARD_H * CELL_SIZE; // 320

    localparam int X0 = 240; // board origin (pixels)
    localparam int Y0 = 80;

    logic [3:0] tile;
    logic [23:0] rgb;

    // Derived cell coordinates (declared at module scope for tool compatibility)
    logic [3:0] cx;
    logic [4:0] cy;
    logic [7:0] bi;

    always_comb begin
        vga_r = 8'h00;
        vga_g = 8'h00;
        vga_b = 8'h00;

        tile = 4'd0;
        rgb  = 24'h000000;

        if (px_active) begin
            // Draw a simple background gradient-ish
            vga_r = {px_x[7:0]};
            vga_g = {px_y[7:0]};
            vga_b = 8'h20;

            // Board region
            if ((px_x >= X0) && (px_x < X0 + BOARD_PX_W) &&
                (px_y >= Y0) && (px_y < Y0 + BOARD_PX_H)) begin

                cx = (px_x - X0) >> CELL_SHIFT; // 0..9
                cy = (px_y - Y0) >> CELL_SHIFT; // 0..19

                bi = (cy << 3) + (cy << 1) + cx; // y*10+x
                tile = board_mem[bi];
                rgb  = tile_to_rgb(tile);

                // Cell borders (grid)
                if (((px_x - X0) & (CELL_SIZE-1)) == 0 || ((px_y - Y0) & (CELL_SIZE-1)) == 0) begin
                    vga_r = 8'h00; vga_g = 8'h00; vga_b = 8'h00;
                end else begin
                    vga_r = rgb[23:16];
                    vga_g = rgb[15:8];
                    vga_b = rgb[7:0];
                end
            end
        end
    end

endmodule
