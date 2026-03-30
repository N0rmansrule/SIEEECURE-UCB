// -----------------------------------------------------------------------------
// soc_quad_gpu_top.sv
//
// Quad-core SoC top for ECP5-sized FPGA:
//   - 4x rv64_core_7stage (in-order, 7-stage)
//   - per-core I$ + D$ (small direct-mapped caches)
//   - global round-robin arbiter to a shared simple RAM
//   - tiny GPU that renders a Tetris-board demo to VGA-like outputs
//
// Notes on resources (ECP5-85K guidance):
//   - Cache sizes are reduced vs the single-core build to keep LUT/EBR use down.
//   - The GPU is intentionally lightweight (tile renderer, no framebuffer).
// -----------------------------------------------------------------------------
module soc_quad_gpu_top #(
    parameter logic [63:0] RESET_PC   = 64'h0000_0000_0000_0000,
    parameter int          MEM_BYTES  = 1<<20,
    parameter string       MEM_INIT_HEX = "",
    parameter int          AES_KEY_BITS = 128,

    // Cache sizing knobs (reduce for area, increase for performance)
    parameter int IC_LINES = 64,   // 64 lines * 16B = 1KB
    parameter int DC_LINES = 64,   // 1KB

    // GPU: use encrypted ROM (SIEEECURE-style) by default
    parameter bit GPU_ENCRYPTED_ROM = 1'b1
)(
    input  wire clk,
    input  wire rst,
    input  wire [3:0] ext_irq,

    output wire [63:0] dbg_pc0,
    output wire [63:0] dbg_pc1,
    output wire [63:0] dbg_pc2,
    output wire [63:0] dbg_pc3,

    // VGA-like output
    output wire [7:0] vga_r,
    output wire [7:0] vga_g,
    output wire [7:0] vga_b,
    output wire       vga_hsync,
    output wire       vga_vsync
);

    // -------------------------------------------------------------------------
    // GPU (autonomous demo)
    // -------------------------------------------------------------------------
    gpu_tetris_engine #(
        .ENCRYPTED_ROM(GPU_ENCRYPTED_ROM),
        .KEY_BITS(128),
        .GPU_KEY(128'h00010203_04050607_08090a0b_0c0d0e0f),
        .GPU_SEED(64'h11223344_55667788)
    ) u_gpu (
        .clk(clk),
        .rst(rst),
        .vga_r(vga_r),
        .vga_g(vga_g),
        .vga_b(vga_b),
        .vga_hsync(vga_hsync),
        .vga_vsync(vga_vsync)
    );

    // -------------------------------------------------------------------------
    // Core <-> caches (line interfaces) per core
    // -------------------------------------------------------------------------
    // Core0 signals
    wire         imem0_req_valid, imem0_req_ready;
    wire [63:0]  imem0_req_addr;
    wire         imem0_resp_valid, imem0_resp_ready;
    wire [127:0] imem0_resp_rdata;
    wire         imem0_resp_err;

    wire         dmem0_req_valid, dmem0_req_ready;
    wire [63:0]  dmem0_req_addr;
    wire         dmem0_req_write;
    wire [127:0] dmem0_req_wdata;
    wire [15:0]  dmem0_req_wstrb;
    wire         dmem0_resp_valid, dmem0_resp_ready;
    wire [127:0] dmem0_resp_rdata;
    wire         dmem0_resp_err;

    wire fencei0;

    // Core1 signals
    wire         imem1_req_valid, imem1_req_ready;
    wire [63:0]  imem1_req_addr;
    wire         imem1_resp_valid, imem1_resp_ready;
    wire [127:0] imem1_resp_rdata;
    wire         imem1_resp_err;

    wire         dmem1_req_valid, dmem1_req_ready;
    wire [63:0]  dmem1_req_addr;
    wire         dmem1_req_write;
    wire [127:0] dmem1_req_wdata;
    wire [15:0]  dmem1_req_wstrb;
    wire         dmem1_resp_valid, dmem1_resp_ready;
    wire [127:0] dmem1_resp_rdata;
    wire         dmem1_resp_err;

    wire fencei1;

    // Core2 signals
    wire         imem2_req_valid, imem2_req_ready;
    wire [63:0]  imem2_req_addr;
    wire         imem2_resp_valid, imem2_resp_ready;
    wire [127:0] imem2_resp_rdata;
    wire         imem2_resp_err;

    wire         dmem2_req_valid, dmem2_req_ready;
    wire [63:0]  dmem2_req_addr;
    wire         dmem2_req_write;
    wire [127:0] dmem2_req_wdata;
    wire [15:0]  dmem2_req_wstrb;
    wire         dmem2_resp_valid, dmem2_resp_ready;
    wire [127:0] dmem2_resp_rdata;
    wire         dmem2_resp_err;

    wire fencei2;

    // Core3 signals
    wire         imem3_req_valid, imem3_req_ready;
    wire [63:0]  imem3_req_addr;
    wire         imem3_resp_valid, imem3_resp_ready;
    wire [127:0] imem3_resp_rdata;
    wire         imem3_resp_err;

    wire         dmem3_req_valid, dmem3_req_ready;
    wire [63:0]  dmem3_req_addr;
    wire         dmem3_req_write;
    wire [127:0] dmem3_req_wdata;
    wire [15:0]  dmem3_req_wstrb;
    wire         dmem3_resp_valid, dmem3_resp_ready;
    wire [127:0] dmem3_resp_rdata;
    wire         dmem3_resp_err;

    wire fencei3;

    // Cache <-> memory bus interfaces per core
    simple_mem_if ic0_mem();
    simple_mem_if dc0_mem();
    simple_mem_if core0_mem();

    simple_mem_if ic1_mem();
    simple_mem_if dc1_mem();
    simple_mem_if core1_mem();

    simple_mem_if ic2_mem();
    simple_mem_if dc2_mem();
    simple_mem_if core2_mem();

    simple_mem_if ic3_mem();
    simple_mem_if dc3_mem();
    simple_mem_if core3_mem();

    // Shared memory bus
    simple_mem_if mem_bus();

    // -------------------------------------------------------------------------
    // Cores
    // -------------------------------------------------------------------------
    rv64_core_7stage #(.RESET_PC(RESET_PC), .AES_KEY_BITS(AES_KEY_BITS)) u_core0 (
        .clk(clk), .rst(rst),
        .imem_req_valid(imem0_req_valid), .imem_req_ready(imem0_req_ready), .imem_req_addr(imem0_req_addr),
        .imem_resp_valid(imem0_resp_valid), .imem_resp_ready(imem0_resp_ready), .imem_resp_rdata(imem0_resp_rdata), .imem_resp_err(imem0_resp_err),
        .dmem_req_valid(dmem0_req_valid), .dmem_req_ready(dmem0_req_ready), .dmem_req_addr(dmem0_req_addr),
        .dmem_req_write(dmem0_req_write), .dmem_req_wdata(dmem0_req_wdata), .dmem_req_wstrb(dmem0_req_wstrb),
        .dmem_resp_valid(dmem0_resp_valid), .dmem_resp_ready(dmem0_resp_ready), .dmem_resp_rdata(dmem0_resp_rdata), .dmem_resp_err(dmem0_resp_err),
        .ext_irq(ext_irq[0]),
        .se_ext_mode(1'b0),
        .se_ext_enable(1'b0),
        .se_ext_key_update(1'b0),
        .se_ext_key({AES_KEY_BITS{1'b0}}),
        .se_ext_seed(64'd0),
        .fencei_pulse(fencei0),
        .dbg_pc(dbg_pc0)
    );

    rv64_core_7stage #(.RESET_PC(RESET_PC), .AES_KEY_BITS(AES_KEY_BITS)) u_core1 (
        .clk(clk), .rst(rst),
        .imem_req_valid(imem1_req_valid), .imem_req_ready(imem1_req_ready), .imem_req_addr(imem1_req_addr),
        .imem_resp_valid(imem1_resp_valid), .imem_resp_ready(imem1_resp_ready), .imem_resp_rdata(imem1_resp_rdata), .imem_resp_err(imem1_resp_err),
        .dmem_req_valid(dmem1_req_valid), .dmem_req_ready(dmem1_req_ready), .dmem_req_addr(dmem1_req_addr),
        .dmem_req_write(dmem1_req_write), .dmem_req_wdata(dmem1_req_wdata), .dmem_req_wstrb(dmem1_req_wstrb),
        .dmem_resp_valid(dmem1_resp_valid), .dmem_resp_ready(dmem1_resp_ready), .dmem_resp_rdata(dmem1_resp_rdata), .dmem_resp_err(dmem1_resp_err),
        .ext_irq(ext_irq[1]),
        .se_ext_mode(1'b0),
        .se_ext_enable(1'b0),
        .se_ext_key_update(1'b0),
        .se_ext_key({AES_KEY_BITS{1'b0}}),
        .se_ext_seed(64'd0),
        .fencei_pulse(fencei1),
        .dbg_pc(dbg_pc1)
    );

    rv64_core_7stage #(.RESET_PC(RESET_PC), .AES_KEY_BITS(AES_KEY_BITS)) u_core2 (
        .clk(clk), .rst(rst),
        .imem_req_valid(imem2_req_valid), .imem_req_ready(imem2_req_ready), .imem_req_addr(imem2_req_addr),
        .imem_resp_valid(imem2_resp_valid), .imem_resp_ready(imem2_resp_ready), .imem_resp_rdata(imem2_resp_rdata), .imem_resp_err(imem2_resp_err),
        .dmem_req_valid(dmem2_req_valid), .dmem_req_ready(dmem2_req_ready), .dmem_req_addr(dmem2_req_addr),
        .dmem_req_write(dmem2_req_write), .dmem_req_wdata(dmem2_req_wdata), .dmem_req_wstrb(dmem2_req_wstrb),
        .dmem_resp_valid(dmem2_resp_valid), .dmem_resp_ready(dmem2_resp_ready), .dmem_resp_rdata(dmem2_resp_rdata), .dmem_resp_err(dmem2_resp_err),
        .ext_irq(ext_irq[2]),
        .se_ext_mode(1'b0),
        .se_ext_enable(1'b0),
        .se_ext_key_update(1'b0),
        .se_ext_key({AES_KEY_BITS{1'b0}}),
        .se_ext_seed(64'd0),
        .fencei_pulse(fencei2),
        .dbg_pc(dbg_pc2)
    );

    rv64_core_7stage #(.RESET_PC(RESET_PC), .AES_KEY_BITS(AES_KEY_BITS)) u_core3 (
        .clk(clk), .rst(rst),
        .imem_req_valid(imem3_req_valid), .imem_req_ready(imem3_req_ready), .imem_req_addr(imem3_req_addr),
        .imem_resp_valid(imem3_resp_valid), .imem_resp_ready(imem3_resp_ready), .imem_resp_rdata(imem3_resp_rdata), .imem_resp_err(imem3_resp_err),
        .dmem_req_valid(dmem3_req_valid), .dmem_req_ready(dmem3_req_ready), .dmem_req_addr(dmem3_req_addr),
        .dmem_req_write(dmem3_req_write), .dmem_req_wdata(dmem3_req_wdata), .dmem_req_wstrb(dmem3_req_wstrb),
        .dmem_resp_valid(dmem3_resp_valid), .dmem_resp_ready(dmem3_resp_ready), .dmem_resp_rdata(dmem3_resp_rdata), .dmem_resp_err(dmem3_resp_err),
        .ext_irq(ext_irq[3]),
        .se_ext_mode(1'b0),
        .se_ext_enable(1'b0),
        .se_ext_key_update(1'b0),
        .se_ext_key({AES_KEY_BITS{1'b0}}),
        .se_ext_seed(64'd0),
        .fencei_pulse(fencei3),
        .dbg_pc(dbg_pc3)
    );

    // -------------------------------------------------------------------------
    // Per-core caches
    // -------------------------------------------------------------------------
    icache #(.LINES(IC_LINES)) u_icache0 (
        .clk(clk), .rst(rst),
        .req_valid(imem0_req_valid), .req_ready(imem0_req_ready), .req_addr(imem0_req_addr),
        .resp_valid(imem0_resp_valid), .resp_ready(imem0_resp_ready), .resp_rdata(imem0_resp_rdata), .resp_err(imem0_resp_err),
        .invalidate(fencei0),
        .mem(ic0_mem)
    );
    dcache #(.LINES(DC_LINES)) u_dcache0 (
        .clk(clk), .rst(rst),
        .req_valid(dmem0_req_valid), .req_ready(dmem0_req_ready), .req_addr(dmem0_req_addr),
        .req_write(dmem0_req_write), .req_wdata(dmem0_req_wdata), .req_wstrb(dmem0_req_wstrb),
        .resp_valid(dmem0_resp_valid), .resp_ready(dmem0_resp_ready), .resp_rdata(dmem0_resp_rdata), .resp_err(dmem0_resp_err),
        .mem(dc0_mem)
    );
    cache_arbiter u_arb0(.clk(clk), .rst(rst), .ic(ic0_mem), .dc(dc0_mem), .mem(core0_mem));

    icache #(.LINES(IC_LINES)) u_icache1 (
        .clk(clk), .rst(rst),
        .req_valid(imem1_req_valid), .req_ready(imem1_req_ready), .req_addr(imem1_req_addr),
        .resp_valid(imem1_resp_valid), .resp_ready(imem1_resp_ready), .resp_rdata(imem1_resp_rdata), .resp_err(imem1_resp_err),
        .invalidate(fencei1),
        .mem(ic1_mem)
    );
    dcache #(.LINES(DC_LINES)) u_dcache1 (
        .clk(clk), .rst(rst),
        .req_valid(dmem1_req_valid), .req_ready(dmem1_req_ready), .req_addr(dmem1_req_addr),
        .req_write(dmem1_req_write), .req_wdata(dmem1_req_wdata), .req_wstrb(dmem1_req_wstrb),
        .resp_valid(dmem1_resp_valid), .resp_ready(dmem1_resp_ready), .resp_rdata(dmem1_resp_rdata), .resp_err(dmem1_resp_err),
        .mem(dc1_mem)
    );
    cache_arbiter u_arb1(.clk(clk), .rst(rst), .ic(ic1_mem), .dc(dc1_mem), .mem(core1_mem));

    icache #(.LINES(IC_LINES)) u_icache2 (
        .clk(clk), .rst(rst),
        .req_valid(imem2_req_valid), .req_ready(imem2_req_ready), .req_addr(imem2_req_addr),
        .resp_valid(imem2_resp_valid), .resp_ready(imem2_resp_ready), .resp_rdata(imem2_resp_rdata), .resp_err(imem2_resp_err),
        .invalidate(fencei2),
        .mem(ic2_mem)
    );
    dcache #(.LINES(DC_LINES)) u_dcache2 (
        .clk(clk), .rst(rst),
        .req_valid(dmem2_req_valid), .req_ready(dmem2_req_ready), .req_addr(dmem2_req_addr),
        .req_write(dmem2_req_write), .req_wdata(dmem2_req_wdata), .req_wstrb(dmem2_req_wstrb),
        .resp_valid(dmem2_resp_valid), .resp_ready(dmem2_resp_ready), .resp_rdata(dmem2_resp_rdata), .resp_err(dmem2_resp_err),
        .mem(dc2_mem)
    );
    cache_arbiter u_arb2(.clk(clk), .rst(rst), .ic(ic2_mem), .dc(dc2_mem), .mem(core2_mem));

    icache #(.LINES(IC_LINES)) u_icache3 (
        .clk(clk), .rst(rst),
        .req_valid(imem3_req_valid), .req_ready(imem3_req_ready), .req_addr(imem3_req_addr),
        .resp_valid(imem3_resp_valid), .resp_ready(imem3_resp_ready), .resp_rdata(imem3_resp_rdata), .resp_err(imem3_resp_err),
        .invalidate(fencei3),
        .mem(ic3_mem)
    );
    dcache #(.LINES(DC_LINES)) u_dcache3 (
        .clk(clk), .rst(rst),
        .req_valid(dmem3_req_valid), .req_ready(dmem3_req_ready), .req_addr(dmem3_req_addr),
        .req_write(dmem3_req_write), .req_wdata(dmem3_req_wdata), .req_wstrb(dmem3_req_wstrb),
        .resp_valid(dmem3_resp_valid), .resp_ready(dmem3_resp_ready), .resp_rdata(dmem3_resp_rdata), .resp_err(dmem3_resp_err),
        .mem(dc3_mem)
    );
    cache_arbiter u_arb3(.clk(clk), .rst(rst), .ic(ic3_mem), .dc(dc3_mem), .mem(core3_mem));

    // -------------------------------------------------------------------------
    // Global memory arbiter (4 cores -> 1 RAM port)
    // -------------------------------------------------------------------------
    mem_arbiter4_rr u_memarb (
        .clk(clk),
        .rst(rst),
        .m0(core0_mem),
        .m1(core1_mem),
        .m2(core2_mem),
        .m3(core3_mem),
        .mem(mem_bus)
    );

    // Shared RAM
    simple_ram #(
        .MEM_BYTES(MEM_BYTES),
        .INIT_HEX(MEM_INIT_HEX)
    ) u_ram (
        .clk(clk),
        .rst(rst),
        .mem(mem_bus)
    );

endmodule
