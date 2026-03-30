// -----------------------------------------------------------------------------
// ecp5_top.sv
//
// Minimal FPGA-friendly top-level wrapper for Lattice ECP5.
//
// This module is intentionally generic (board-agnostic). You must provide:
//   - proper pin constraints (.lpf) for your board
//   - (optionally) a PLL to generate your target system clock
//
// Ports provided here are typical for quick bring-up:
//   - clk_in : board oscillator clock
//   - rst_n  : active-low reset
//   - led[7:0] : debug LEDs (shows dbg_pc bits)
//
// If your board has no LEDs, export dbg_pc via UART/JTAG/ILA instead.
// -----------------------------------------------------------------------------
module ecp5_top #(
    parameter logic [63:0] RESET_PC   = 64'h0000_0000_0000_0000,
    parameter int          MEM_BYTES  = 1<<20,
    parameter string       MEM_INIT_HEX = "",
    parameter int          AES_KEY_BITS = 128
)(
    input  wire        clk_in,
    input  wire        rst_n,
    output wire [7:0]  led
);

    wire rst = ~rst_n;
    wire [63:0] dbg_pc;

    // Small SoC: core + caches + simple RAM
    soc_top #(
        .RESET_PC(RESET_PC),
        .MEM_BYTES(MEM_BYTES),
        .MEM_INIT_HEX(MEM_INIT_HEX),
        .AES_KEY_BITS(AES_KEY_BITS)
    ) u_soc (
        .clk(clk_in),
        .rst(rst),
        .ext_irq(1'b0),
        .dbg_pc(dbg_pc)
    );

    // Map some PC bits to LEDs as a crude "alive" indicator
    assign led = dbg_pc[9:2];

endmodule
