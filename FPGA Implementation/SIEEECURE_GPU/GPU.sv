// tetris_gpu.sv
// -----------------------------------------------------------------------------
// "Toy GPU" for a secure handheld Tetris console
// -----------------------------------------------------------------------------
// This GPU is intentionally *simple* and *teachable*:
//
//   - Renders a 10x20 Tetris grid as colored rectangles.
//   - Adds a UI region (right side) for score/next-piece/sensor "fun stuff".
//   - Exposes a small MMIO register file so firmware can update tiles/palette.
//   - Optionally supports a "custom instruction" command port so one CPU core
//     can push GPU commands without going through MMIO.
//
// Why not a full OpenGL/Vulkan-style GPU?
//   A tile/rectangle renderer is plenty for colorful Tetris, and it stays
//   debuggable in both FPGA and early ASIC bring-up.
//
// Video model:
//   A separate timing generator (video_timing.sv) supplies px_x/px_y/px_de.
//   This module computes px_rgb565 for each active pixel.
//   Downstream logic converts RGB565 -> RGB888 (or drives RGB565 LCD directly).
//
// Security model:
//   The GPU does not read system memory. The CPU writes the tilemap explicitly.
//   This avoids "surprising" information flow from secret memory into pixels.
//   (Of course, whatever you display is visible to the user by definition.)
//
// -----------------------------------------------------------------------------
// MMIO register map (offsets within the GPU block)
// -----------------------------------------------------------------------------
// Base address is chosen by the SoC MMIO decode (see periph_top.sv).
//
// 0x0000 GPU_CTRL
//   [0] enable (1 = render; 0 = output background only)
//   [1] clear  (write 1 to clear tilemap to 0, self-clears)
//   [2] invert (demo effect; xor colors)
// 0x0008 GPU_STATUS (RO)
//   [0] frame_toggle (toggles each frame start)
// 0x0010 BG_COLOR (RW)  [3:0] color index into palette
// 0x0018 UI0 (RW)       user-defined (score, etc.)
// 0x0020 UI1 (RW)       user-defined (sensor-derived, etc.)
//
// Palette programming
// 0x0100 PAL_INDEX (RW)  [3:0] index
// 0x0108 PAL_DATA  (RW)  [15:0] RGB565 (write updates palette[PAL_INDEX])
//
// Tilemap programming
// 0x0200 CELL_ADDR (RW)  [15:8]=row (0..19), [7:0]=col (0..9)
// 0x0208 CELL_DATA (RW)  [3:0]=color index (0=empty), write updates cell
//                         Reads return current cell value.
//
// Fast-fill helper (optional)
// 0x0210 FILL_ROW (WO)   wdata[7:0]=row, wdata[11:8]=color
//
// -----------------------------------------------------------------------------
// Custom instruction command port (optional)
// -----------------------------------------------------------------------------
// The CPU can push a command with (ci_op, ci_arg0, ci_arg1). The suggested
// encoding is described in docs/GPU_CUSTOM_ISA.md. The GPU executes the
// command and returns a 64-bit response.
//
// Suggested ci_op codes:
//   0x01: SET_CELL   arg0={row[7:0], col[7:0]} arg1=color_idx[3:0]
//   0x02: CLEAR_ALL  no args
//   0x03: SET_PAL    arg0=index arg1=rgb565
//   0x04: SET_BG     arg0=color_idx
// -----------------------------------------------------------------------------

module tetris_gpu #(
    parameter integer SCREEN_W   = 240,
    parameter integer SCREEN_H   = 240,
    parameter integer GRID_COLS  = 10,
    parameter integer GRID_ROWS  = 20,
    parameter integer CELL_W     = 12,   // playfield cell pixel width
    parameter integer CELL_H     = 12,   // playfield cell pixel height
    parameter integer PLAY_W     = GRID_COLS * CELL_W,  // 120 for defaults
    parameter integer PLAY_H     = GRID_ROWS * CELL_H,  // 240 for defaults
    parameter [3:0]  GRIDLINE_COLOR_IDX = 4'hB // gray gridlines
)(
    input  wire        clk,
    input  wire        rst_n,

    // Pixel position/timing
    input  wire [11:0] px_x,
    input  wire [11:0] px_y,
    input  wire        px_de,        // data-enable: 1 when pixel is in active region
    input  wire        frame_start,  // 1-cycle pulse at start of each frame

    output reg  [15:0] px_rgb565,

    // --------------------------
    // MMIO register access
    // --------------------------
    input  wire        mmio_wr_en,
    input  wire [15:0] mmio_addr,     // offset within GPU block
    input  wire [63:0] mmio_wdata,
    input  wire [7:0]  mmio_wstrb,

    input  wire        mmio_rd_en,
    output reg  [63:0] mmio_rdata,

    // --------------------------
    // Custom-instruction command port (optional)
    // --------------------------
    input  wire        ci_valid,
    input  wire [7:0]  ci_op,
    input  wire [63:0] ci_arg0,
    input  wire [63:0] ci_arg1,
    output wire        ci_ready,

    output reg         ci_rsp_valid,
    output reg  [63:0] ci_rsp_data,
    input  wire        ci_rsp_ready
);

    // -------------------------------------------------------------------------
    // Internal memories: tilemap + palette
    // -------------------------------------------------------------------------
    // tilemap stores a 4-bit color index per cell. 0 means "empty".
    reg [3:0] tilemap [0:GRID_ROWS-1][0:GRID_COLS-1];

    // palette stores RGB565 per color index
    reg [15:0] palette [0:15];

    integer r,c;

    // -------------------------------------------------------------------------
    // Control / UI registers
    // -------------------------------------------------------------------------
    reg        gpu_en;
    reg        gpu_invert;
    reg [3:0]  bg_color_idx;
    reg [31:0] ui0;
    reg [31:0] ui1;

    // palette programming regs
    reg [3:0] pal_index;

    // tile programming regs
    reg [7:0] cell_row;
    reg [7:0] cell_col;

    // frame toggle (lets software know we're alive)
    reg frame_tog;

    // -------------------------------------------------------------------------
    // Helper: compute cell coordinate without division
    // -------------------------------------------------------------------------
    function automatic [7:0] calc_cell_x(input [11:0] x);
        integer k;
        begin
            calc_cell_x = 0;
            // This loop unrolls into a small set of compares because CELL_W and
            // GRID_COLS are parameters known at elaboration time.
            for (k=0; k<GRID_COLS; k=k+1)
                if (x >= k*CELL_W)
                    calc_cell_x = k[7:0];
        end
    endfunction

    function automatic [7:0] calc_cell_y(input [11:0] y);
        integer k;
        begin
            calc_cell_y = 0;
            for (k=0; k<GRID_ROWS; k=k+1)
                if (y >= k*CELL_H)
                    calc_cell_y = k[7:0];
        end
    endfunction

    // -------------------------------------------------------------------------
    // MMIO write handling
    // -------------------------------------------------------------------------
    // Note: we intentionally ignore mmio_wstrb for simplicity here; if you want
    // byte-granular writes, extend this logic (it's a great exercise).
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gpu_en       <= 1'b1;
            gpu_invert   <= 1'b0;
            bg_color_idx <= 4'h0;
            ui0          <= 32'h0;
            ui1          <= 32'h0;
            pal_index    <= 4'h0;
            cell_row     <= 8'h0;
            cell_col     <= 8'h0;
            frame_tog    <= 1'b0;

            // Default palette: basic bright colors (RGB565).
            palette[0]  <= 16'h0000; // black
            palette[1]  <= 16'hFFFF; // white
            palette[2]  <= 16'hF800; // red
            palette[3]  <= 16'h07E0; // green
            palette[4]  <= 16'h001F; // blue
            palette[5]  <= 16'hFFE0; // yellow
            palette[6]  <= 16'hF81F; // magenta
            palette[7]  <= 16'h07FF; // cyan
            palette[8]  <= 16'hFD20; // orange-ish
            palette[9]  <= 16'hAFE5; // pastel
            palette[10] <= 16'h5ACB;
            palette[11] <= 16'hC618; // gray
            palette[12] <= 16'h7BEF;
            palette[13] <= 16'h39E7;
            palette[14] <= 16'h18C6;
            palette[15] <= 16'h0000;

            // Clear tilemap
            for (r=0; r<GRID_ROWS; r=r+1)
                for (c=0; c<GRID_COLS; c=c+1)
                    tilemap[r][c] <= 4'h0;

        end else begin
            // Frame toggle for status register
            if (frame_start) frame_tog <= ~frame_tog;

            // MMIO writes
            if (mmio_wr_en) begin
                case (mmio_addr)
                    16'h0000: begin
                        gpu_en     <= mmio_wdata[0];
                        gpu_invert <= mmio_wdata[2];

                        // bit1 "clear" is write-one-to-clear (W1C)
                        if (mmio_wdata[1]) begin
                            for (r=0; r<GRID_ROWS; r=r+1)
                                for (c=0; c<GRID_COLS; c=c+1)
                                    tilemap[r][c] <= 4'h0;
                        end
                    end

                    16'h0010: bg_color_idx <= mmio_wdata[3:0];
                    16'h0018: ui0 <= mmio_wdata[31:0];
                    16'h0020: ui1 <= mmio_wdata[31:0];

                    16'h0100: pal_index <= mmio_wdata[3:0];
                    16'h0108: palette[pal_index] <= mmio_wdata[15:0];

                    16'h0200: begin
                        cell_row <= mmio_wdata[15:8];
                        cell_col <= mmio_wdata[7:0];
                    end
                    16'h0208: begin
                        if (cell_row < GRID_ROWS && cell_col < GRID_COLS)
                            tilemap[cell_row][cell_col] <= mmio_wdata[3:0];
                    end

                    16'h0210: begin
                        // FILL_ROW: wdata[7:0]=row, wdata[11:8]=color
                        if (mmio_wdata[7:0] < GRID_ROWS) begin
                            for (c=0; c<GRID_COLS; c=c+1)
                                tilemap[mmio_wdata[7:0]][c] <= mmio_wdata[11:8];
                        end
                    end
                    default: begin end
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // MMIO read handling (combinational)
    // -------------------------------------------------------------------------
    always @* begin
        mmio_rdata = 64'h0;

        if (mmio_rd_en) begin
            case (mmio_addr)
                16'h0000: mmio_rdata = {61'h0, gpu_invert, 1'b0 /*clear*/, gpu_en};
                16'h0008: mmio_rdata = {63'h0, frame_tog};
                16'h0010: mmio_rdata = {60'h0, bg_color_idx};
                16'h0018: mmio_rdata = {32'h0, ui0};
                16'h0020: mmio_rdata = {32'h0, ui1};

                16'h0100: mmio_rdata = {60'h0, pal_index};
                16'h0108: mmio_rdata = {48'h0, palette[pal_index]};

                16'h0200: mmio_rdata = {48'h0, cell_row, cell_col};
                16'h0208: begin
                    if (cell_row < GRID_ROWS && cell_col < GRID_COLS)
                        mmio_rdata = {60'h0, tilemap[cell_row][cell_col]};
                    else
                        mmio_rdata = 64'h0;
                end
                default: mmio_rdata = 64'h0;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Custom-instruction command handling
    // -------------------------------------------------------------------------
    // Simple single-entry response. ci_ready is high when we are not holding an
    // unconsumed response.
    assign ci_ready = rst_n && (!ci_rsp_valid);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ci_rsp_valid <= 1'b0;
            ci_rsp_data  <= 64'h0;
        end else begin
            // Response consumed?
            if (ci_rsp_valid && ci_rsp_ready)
                ci_rsp_valid <= 1'b0;

            // Accept a new command only if ready
            if (ci_valid && ci_ready) begin
                // Default response: 0 = OK
                ci_rsp_data  <= 64'h0;
                ci_rsp_valid <= 1'b1;

                case (ci_op)
                    8'h01: begin
                        // SET_CELL arg0={row[7:0], col[7:0]} arg1=color_idx[3:0]
                        if (ci_arg0[15:8] < GRID_ROWS && ci_arg0[7:0] < GRID_COLS)
                            tilemap[ci_arg0[15:8]][ci_arg0[7:0]] <= ci_arg1[3:0];
                        else
                            ci_rsp_data <= 64'h1; // error: out of range
                    end

                    8'h02: begin
                        // CLEAR_ALL
                        for (r=0; r<GRID_ROWS; r=r+1)
                            for (c=0; c<GRID_COLS; c=c+1)
                                tilemap[r][c] <= 4'h0;
                    end

                    8'h03: begin
                        // SET_PAL arg0=index arg1=rgb565
                        palette[ci_arg0[3:0]] <= ci_arg1[15:0];
                    end

                    8'h04: begin
                        // SET_BG arg0=color_idx
                        bg_color_idx <= ci_arg0[3:0];
                    end

                    default: begin
                        // unknown op -> return nonzero
                        ci_rsp_data <= 64'hFFFF_FFFF_FFFF_FFFF;
                    end
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // Pixel generation
    // -------------------------------------------------------------------------
    // Playfield region: [0..PLAY_W-1] x [0..PLAY_H-1]
    // UI region:       [PLAY_W..SCREEN_W-1] x [0..SCREEN_H-1]
    //
    // You can expand the UI region to show next-piece sprite, score digits, etc.
    // For now we render sensor bars from ui0/ui1 as a demonstration.
    wire in_play = (px_x < PLAY_W) && (px_y < PLAY_H);
    wire in_ui   = (px_x >= PLAY_W) && (px_x < SCREEN_W) && (px_y < SCREEN_H);

    wire [7:0] cell_x = calc_cell_x(px_x);  // 0..9
    wire [7:0] cell_y = calc_cell_y(px_y);  // 0..19

    // Cell-local coordinates (for drawing grid lines / borders)
    wire [11:0] cell_x_base = cell_x * CELL_W;
    wire [11:0] cell_y_base = cell_y * CELL_H;
    wire [11:0] cell_lx = px_x - cell_x_base;
    wire [11:0] cell_ly = px_y - cell_y_base;
    wire        cell_border = (cell_lx == 12'd0) || (cell_ly == 12'd0) ||
                              (cell_lx == (CELL_W-1)) || (cell_ly == (CELL_H-1));


    reg [3:0]  color_idx;
    reg [15:0] rgb;

    always @* begin
        color_idx = bg_color_idx;

        if (!px_de) begin
            color_idx = 4'h0;
        end else if (!gpu_en) begin
            color_idx = bg_color_idx;
        end else if (in_play) begin
            // cell value selects palette; 0 means empty -> background
            if (cell_y < GRID_ROWS && cell_x < GRID_COLS) begin
                if (cell_border)
                    color_idx = GRIDLINE_COLOR_IDX;
                else if (tilemap[cell_y][cell_x] != 4'h0)
                    color_idx = tilemap[cell_y][cell_x];
                else
                    color_idx = bg_color_idx;
            end else begin
                color_idx = bg_color_idx;
            end
        end else if (in_ui) begin
            // Simple UI: draw two vertical bars based on ui0/ui1
            // ui0[7:0] and ui1[7:0] set bar heights (0..255 mapped to 0..SCREEN_H)
            // left half of UI is ui0, right half is ui1
            integer ui_w;
            integer ui_x;
            integer bar_h0, bar_h1;

            ui_w   = SCREEN_W - PLAY_W;
            ui_x   = px_x - PLAY_W;
            bar_h0 = (ui0[7:0] * SCREEN_H) >> 8;
            bar_h1 = (ui1[7:0] * SCREEN_H) >> 8;

            if (ui_x < (ui_w/2)) begin
                if (px_y >= (SCREEN_H - bar_h0))
                    color_idx = 4'h7; // cyan
                else
                    color_idx = 4'hB; // gray
            end else begin
                if (px_y >= (SCREEN_H - bar_h1))
                    color_idx = 4'h2; // red
                else
                    color_idx = 4'hB; // gray
            end
        end else begin
            color_idx = bg_color_idx;
        end

        rgb = palette[color_idx];

        // Optional demo effect
        if (gpu_invert)
            rgb = ~rgb;

        px_rgb565 = rgb;
    end

endmodule
