// -----------------------------------------------------------------------------
// ecp5_quad_entropy_gpu_tetris_top.sv
// FPGA wrapper for the quad-core + entropy-select + SE-GPU + RTL-Tetris build.
// Pin-map with LPF for a custom ECP5 board.
// -----------------------------------------------------------------------------
module ecp5_quad_entropy_gpu_tetris_top #(
    parameter logic [63:0] RESET_PC   = 64'h0000_0000_0000_0000,
    parameter int          MEM_BYTES  = 1<<20,
    parameter string       MEM_INIT_HEX = "",
    parameter int          AES_KEY_BITS = 128
)(
    input  wire              clk_in,
    input  wire              rst_n,
    input  wire [1:0]        entropy_sel,
    input  wire              qrng_valid,
    input  wire [7:0]        qrng_data,
    input  wire              photon_valid,
    input  wire [7:0]        photon_data,
    input  wire              reseed_req,
    input  wire [1:0]        tetris_mode_sel,
    input  wire              cpu_ctrl_valid,
    input  wire [31:0]       cpu_ctrl_word,
    input  wire              cpu_ctrl_encrypted,
    input  wire [127:0]      cpu_ctrl_ct,
    output wire [7:0]        led,
    output wire [7:0]        vga_r,
    output wire [7:0]        vga_g,
    output wire [7:0]        vga_b,
    output wire              vga_hsync,
    output wire              vga_vsync
);
    wire rst = ~rst_n;
    wire [63:0] dbg_pc0, dbg_pc1, dbg_pc2, dbg_pc3;
    wire entropy_ready;

    soc_quad_secure_entropy_gpu_tetris_top #(
        .RESET_PC(RESET_PC), .MEM_BYTES(MEM_BYTES), .MEM_INIT_HEX(MEM_INIT_HEX), .AES_KEY_BITS(AES_KEY_BITS)
    ) u_soc (
        .clk(clk_in), .rst(rst), .ext_irq(4'b0000),
        .entropy_sel(entropy_sel),
        .manual_key_load(1'b0), .manual_key_enable(1'b0), .manual_key({AES_KEY_BITS{1'b0}}), .manual_seed(64'd0),
        .qrng_valid(qrng_valid), .qrng_data(qrng_data),
        .photon_valid(photon_valid), .photon_data(photon_data),
        .reseed_req(reseed_req),
        .cpu_ctrl_valid(cpu_ctrl_valid), .cpu_ctrl_word(cpu_ctrl_word), .cpu_ctrl_encrypted(cpu_ctrl_encrypted), .cpu_ctrl_ct(cpu_ctrl_ct),
        .tetris_mode_sel(tetris_mode_sel),
        .dbg_pc0(dbg_pc0), .dbg_pc1(dbg_pc1), .dbg_pc2(dbg_pc2), .dbg_pc3(dbg_pc3),
        .entropy_ready(entropy_ready),
        .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b), .vga_hsync(vga_hsync), .vga_vsync(vga_vsync)
    );

    assign led = {entropy_ready, dbg_pc0[4], dbg_pc1[4], dbg_pc2[4], dbg_pc3[4], entropy_sel};
endmodule
