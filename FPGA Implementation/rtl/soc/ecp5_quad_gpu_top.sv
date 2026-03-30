// -----------------------------------------------------------------------------
// ecp5_quad_gpu_top.sv
//
// FPGA top-level wrapper for Lattice ECP5 (LFE5U-85F-6BG381C).
// This is a *template* top: you will need to adapt pin names + constraints
// for your custom board.
//
// Inputs:
//   - clk_in   : system clock (recommend ~25 MHz if driving VGA directly)
//   - rst_n    : active-low reset
//
// Outputs:
//   - vga_*    : VGA-style parallel RGB + sync. For HDMI you can feed these
//               into a TMDS encoder/serializer block (not included here).
// -----------------------------------------------------------------------------
module ecp5_quad_gpu_top(
    input  wire clk_in,
    input  wire rst_n,

    // Optional external IRQs per core
    input  wire [3:0] ext_irq,

    // VGA-style video
    output wire [7:0] vga_r,
    output wire [7:0] vga_g,
    output wire [7:0] vga_b,
    output wire       vga_hsync,
    output wire       vga_vsync
);

    wire clk = clk_in;
    wire rst = ~rst_n;

    wire [63:0] dbg_pc0, dbg_pc1, dbg_pc2, dbg_pc3;

    soc_quad_gpu_top #(
        .RESET_PC(64'h0000_0000_0000_0000),
        .MEM_BYTES(1<<20),
        // For a real board you'll usually load RAM via STM32, so default is empty.
        .MEM_INIT_HEX(""),
        .AES_KEY_BITS(128),
        .IC_LINES(64),
        .DC_LINES(64),
        .GPU_ENCRYPTED_ROM(1'b1)
    ) u_soc (
        .clk(clk),
        .rst(rst),
        .ext_irq(ext_irq),
        .dbg_pc0(dbg_pc0),
        .dbg_pc1(dbg_pc1),
        .dbg_pc2(dbg_pc2),
        .dbg_pc3(dbg_pc3),
        .vga_r(vga_r),
        .vga_g(vga_g),
        .vga_b(vga_b),
        .vga_hsync(vga_hsync),
        .vga_vsync(vga_vsync)
    );

endmodule
