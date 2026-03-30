// -----------------------------------------------------------------------------
// soc_quad_secure_entropy_gpu_tetris_top.sv
// Quad-core secure SoC top with:
//   - 4x RV64 7-stage SE-capable cores
//   - shared SE key manager with selectable QRNG / photonic entropy source
//   - SE-aware GPU core + RTL Tetris subsystem
//
// This is the integration point for a custom board using:
//   - diode/LNA/ADC QRNG stream into qrng_* ports
//   - photonic / photon-count entropy stream into photon_* ports
//
// entropy_sel:
//   00 = manual/static key path
//   01 = QRNG-selected key path
//   10 = photonic-selected key path
//   11 = mixed QRNG^photonic path
// -----------------------------------------------------------------------------
module soc_quad_secure_entropy_gpu_tetris_top #(
    parameter logic [63:0] RESET_PC   = 64'h0000_0000_0000_0000,
    parameter int          MEM_BYTES  = 1<<20,
    parameter string       MEM_INIT_HEX = "",
    parameter int          AES_KEY_BITS = 128,
    parameter int          IC_LINES = 64,
    parameter int          DC_LINES = 64
)(
    input  wire              clk,
    input  wire              rst,
    input  wire [3:0]        ext_irq,

    // external entropy inputs
    input  wire [1:0]        entropy_sel,
    input  wire              manual_key_load,
    input  wire              manual_key_enable,
    input  wire [AES_KEY_BITS-1:0] manual_key,
    input  wire [63:0]       manual_seed,
    input  wire              qrng_valid,
    input  wire [7:0]        qrng_data,
    input  wire              photon_valid,
    input  wire [7:0]        photon_data,
    input  wire              reseed_req,

    // optional CPU control for tetris
    input  wire              cpu_ctrl_valid,
    input  wire [31:0]       cpu_ctrl_word,
    input  wire              cpu_ctrl_encrypted,
    input  wire [127:0]      cpu_ctrl_ct,
    input  wire [1:0]        tetris_mode_sel,

    output wire [63:0]       dbg_pc0,
    output wire [63:0]       dbg_pc1,
    output wire [63:0]       dbg_pc2,
    output wire [63:0]       dbg_pc3,
    output wire              entropy_ready,

    output wire [7:0]        vga_r,
    output wire [7:0]        vga_g,
    output wire [7:0]        vga_b,
    output wire              vga_hsync,
    output wire              vga_vsync
);
    // -------------------------------------------------------------------------
    // Shared key manager
    // -------------------------------------------------------------------------
    wire              se_key_enable;
    wire              se_key_update;
    wire [AES_KEY_BITS-1:0] se_key;
    wire [63:0]       se_seed;

    se_key_manager #(.KEY_BITS(AES_KEY_BITS)) u_keymgr (
        .clk(clk),
        .rst(rst),
        .entropy_sel(entropy_sel),
        .manual_load(manual_key_load),
        .manual_enable(manual_key_enable),
        .manual_key(manual_key),
        .manual_seed(manual_seed),
        .qrng_valid(qrng_valid),
        .qrng_data(qrng_data),
        .photon_valid(photon_valid),
        .photon_data(photon_data),
        .reseed_req(reseed_req),
        .se_enable(se_key_enable),
        .key_update(se_key_update),
        .key_out(se_key),
        .seed_out(se_seed),
        .entropy_ready(entropy_ready)
    );

    // -------------------------------------------------------------------------
    // Reuse existing quad-core + cache + RAM structure, but feed each core from
    // the shared external key path.
    // -------------------------------------------------------------------------
    // Core/cache buses (same structure as soc_quad_gpu_top)
    wire         imem0_req_valid, imem0_req_ready; wire [63:0]  imem0_req_addr; wire         imem0_resp_valid, imem0_resp_ready; wire [127:0] imem0_resp_rdata; wire         imem0_resp_err;
    wire         dmem0_req_valid, dmem0_req_ready; wire [63:0]  dmem0_req_addr; wire         dmem0_req_write; wire [127:0] dmem0_req_wdata; wire [15:0]  dmem0_req_wstrb; wire         dmem0_resp_valid, dmem0_resp_ready; wire [127:0] dmem0_resp_rdata; wire         dmem0_resp_err; wire fencei0;
    wire         imem1_req_valid, imem1_req_ready; wire [63:0]  imem1_req_addr; wire         imem1_resp_valid, imem1_resp_ready; wire [127:0] imem1_resp_rdata; wire         imem1_resp_err;
    wire         dmem1_req_valid, dmem1_req_ready; wire [63:0]  dmem1_req_addr; wire         dmem1_req_write; wire [127:0] dmem1_req_wdata; wire [15:0]  dmem1_req_wstrb; wire         dmem1_resp_valid, dmem1_resp_ready; wire [127:0] dmem1_resp_rdata; wire         dmem1_resp_err; wire fencei1;
    wire         imem2_req_valid, imem2_req_ready; wire [63:0]  imem2_req_addr; wire         imem2_resp_valid, imem2_resp_ready; wire [127:0] imem2_resp_rdata; wire         imem2_resp_err;
    wire         dmem2_req_valid, dmem2_req_ready; wire [63:0]  dmem2_req_addr; wire         dmem2_req_write; wire [127:0] dmem2_req_wdata; wire [15:0]  dmem2_req_wstrb; wire         dmem2_resp_valid, dmem2_resp_ready; wire [127:0] dmem2_resp_rdata; wire         dmem2_resp_err; wire fencei2;
    wire         imem3_req_valid, imem3_req_ready; wire [63:0]  imem3_req_addr; wire         imem3_resp_valid, imem3_resp_ready; wire [127:0] imem3_resp_rdata; wire         imem3_resp_err;
    wire         dmem3_req_valid, dmem3_req_ready; wire [63:0]  dmem3_req_addr; wire         dmem3_req_write; wire [127:0] dmem3_req_wdata; wire [15:0]  dmem3_req_wstrb; wire         dmem3_resp_valid, dmem3_resp_ready; wire [127:0] dmem3_resp_rdata; wire         dmem3_resp_err; wire fencei3;

    simple_mem_if ic0_mem(); simple_mem_if dc0_mem(); simple_mem_if core0_mem();
    simple_mem_if ic1_mem(); simple_mem_if dc1_mem(); simple_mem_if core1_mem();
    simple_mem_if ic2_mem(); simple_mem_if dc2_mem(); simple_mem_if core2_mem();
    simple_mem_if ic3_mem(); simple_mem_if dc3_mem(); simple_mem_if core3_mem();
    simple_mem_if ram_mem();

    rv64_core_7stage #(.RESET_PC(RESET_PC), .AES_KEY_BITS(AES_KEY_BITS)) u_core0 (
        .clk(clk), .rst(rst),
        .imem_req_valid(imem0_req_valid), .imem_req_ready(imem0_req_ready), .imem_req_addr(imem0_req_addr),
        .imem_resp_valid(imem0_resp_valid), .imem_resp_ready(imem0_resp_ready), .imem_resp_rdata(imem0_resp_rdata), .imem_resp_err(imem0_resp_err),
        .dmem_req_valid(dmem0_req_valid), .dmem_req_ready(dmem0_req_ready), .dmem_req_addr(dmem0_req_addr),
        .dmem_req_write(dmem0_req_write), .dmem_req_wdata(dmem0_req_wdata), .dmem_req_wstrb(dmem0_req_wstrb),
        .dmem_resp_valid(dmem0_resp_valid), .dmem_resp_ready(dmem0_resp_ready), .dmem_resp_rdata(dmem0_resp_rdata), .dmem_resp_err(dmem0_resp_err),
        .ext_irq(ext_irq[0]),
        .se_ext_mode(1'b1), .se_ext_enable(se_key_enable), .se_ext_key_update(se_key_update), .se_ext_key(se_key), .se_ext_seed(se_seed),
        .fencei_pulse(fencei0), .dbg_pc(dbg_pc0)
    );
    rv64_core_7stage #(.RESET_PC(RESET_PC), .AES_KEY_BITS(AES_KEY_BITS)) u_core1 (
        .clk(clk), .rst(rst),
        .imem_req_valid(imem1_req_valid), .imem_req_ready(imem1_req_ready), .imem_req_addr(imem1_req_addr),
        .imem_resp_valid(imem1_resp_valid), .imem_resp_ready(imem1_resp_ready), .imem_resp_rdata(imem1_resp_rdata), .imem_resp_err(imem1_resp_err),
        .dmem_req_valid(dmem1_req_valid), .dmem_req_ready(dmem1_req_ready), .dmem_req_addr(dmem1_req_addr),
        .dmem_req_write(dmem1_req_write), .dmem_req_wdata(dmem1_req_wdata), .dmem_req_wstrb(dmem1_req_wstrb),
        .dmem_resp_valid(dmem1_resp_valid), .dmem_resp_ready(dmem1_resp_ready), .dmem_resp_rdata(dmem1_resp_rdata), .dmem_resp_err(dmem1_resp_err),
        .ext_irq(ext_irq[1]),
        .se_ext_mode(1'b1), .se_ext_enable(se_key_enable), .se_ext_key_update(se_key_update), .se_ext_key(se_key), .se_ext_seed(se_seed),
        .fencei_pulse(fencei1), .dbg_pc(dbg_pc1)
    );
    rv64_core_7stage #(.RESET_PC(RESET_PC), .AES_KEY_BITS(AES_KEY_BITS)) u_core2 (
        .clk(clk), .rst(rst),
        .imem_req_valid(imem2_req_valid), .imem_req_ready(imem2_req_ready), .imem_req_addr(imem2_req_addr),
        .imem_resp_valid(imem2_resp_valid), .imem_resp_ready(imem2_resp_ready), .imem_resp_rdata(imem2_resp_rdata), .imem_resp_err(imem2_resp_err),
        .dmem_req_valid(dmem2_req_valid), .dmem_req_ready(dmem2_req_ready), .dmem_req_addr(dmem2_req_addr),
        .dmem_req_write(dmem2_req_write), .dmem_req_wdata(dmem2_req_wdata), .dmem_req_wstrb(dmem2_req_wstrb),
        .dmem_resp_valid(dmem2_resp_valid), .dmem_resp_ready(dmem2_resp_ready), .dmem_resp_rdata(dmem2_resp_rdata), .dmem_resp_err(dmem2_resp_err),
        .ext_irq(ext_irq[2]),
        .se_ext_mode(1'b1), .se_ext_enable(se_key_enable), .se_ext_key_update(se_key_update), .se_ext_key(se_key), .se_ext_seed(se_seed),
        .fencei_pulse(fencei2), .dbg_pc(dbg_pc2)
    );
    rv64_core_7stage #(.RESET_PC(RESET_PC), .AES_KEY_BITS(AES_KEY_BITS)) u_core3 (
        .clk(clk), .rst(rst),
        .imem_req_valid(imem3_req_valid), .imem_req_ready(imem3_req_ready), .imem_req_addr(imem3_req_addr),
        .imem_resp_valid(imem3_resp_valid), .imem_resp_ready(imem3_resp_ready), .imem_resp_rdata(imem3_resp_rdata), .imem_resp_err(imem3_resp_err),
        .dmem_req_valid(dmem3_req_valid), .dmem_req_ready(dmem3_req_ready), .dmem_req_addr(dmem3_req_addr),
        .dmem_req_write(dmem3_req_write), .dmem_req_wdata(dmem3_req_wdata), .dmem_req_wstrb(dmem3_req_wstrb),
        .dmem_resp_valid(dmem3_resp_valid), .dmem_resp_ready(dmem3_resp_ready), .dmem_resp_rdata(dmem3_resp_rdata), .dmem_resp_err(dmem3_resp_err),
        .ext_irq(ext_irq[3]),
        .se_ext_mode(1'b1), .se_ext_enable(se_key_enable), .se_ext_key_update(se_key_update), .se_ext_key(se_key), .se_ext_seed(se_seed),
        .fencei_pulse(fencei3), .dbg_pc(dbg_pc3)
    );

    icache #(.LINES(IC_LINES)) u_ic0 (.clk(clk), .rst(rst), .req_valid(imem0_req_valid), .req_ready(imem0_req_ready), .req_addr(imem0_req_addr), .resp_valid(imem0_resp_valid), .resp_ready(imem0_resp_ready), .resp_rdata(imem0_resp_rdata), .resp_err(imem0_resp_err), .invalidate(fencei0), .mem(ic0_mem));
    dcache #(.LINES(DC_LINES)) u_dc0 (.clk(clk), .rst(rst), .req_valid(dmem0_req_valid), .req_ready(dmem0_req_ready), .req_addr(dmem0_req_addr), .req_write(dmem0_req_write), .req_wdata(dmem0_req_wdata), .req_wstrb(dmem0_req_wstrb), .resp_valid(dmem0_resp_valid), .resp_ready(dmem0_resp_ready), .resp_rdata(dmem0_resp_rdata), .resp_err(dmem0_resp_err), .invalidate_all(1'b0), .mem(dc0_mem));
    cache_arbiter u_arb0 (.clk(clk), .rst(rst), .ic_port(ic0_mem), .dc_port(dc0_mem), .mem_port(core0_mem));

    icache #(.LINES(IC_LINES)) u_ic1 (.clk(clk), .rst(rst), .req_valid(imem1_req_valid), .req_ready(imem1_req_ready), .req_addr(imem1_req_addr), .resp_valid(imem1_resp_valid), .resp_ready(imem1_resp_ready), .resp_rdata(imem1_resp_rdata), .resp_err(imem1_resp_err), .invalidate(fencei1), .mem(ic1_mem));
    dcache #(.LINES(DC_LINES)) u_dc1 (.clk(clk), .rst(rst), .req_valid(dmem1_req_valid), .req_ready(dmem1_req_ready), .req_addr(dmem1_req_addr), .req_write(dmem1_req_write), .req_wdata(dmem1_req_wdata), .req_wstrb(dmem1_req_wstrb), .resp_valid(dmem1_resp_valid), .resp_ready(dmem1_resp_ready), .resp_rdata(dmem1_resp_rdata), .resp_err(dmem1_resp_err), .invalidate_all(1'b0), .mem(dc1_mem));
    cache_arbiter u_arb1 (.clk(clk), .rst(rst), .ic_port(ic1_mem), .dc_port(dc1_mem), .mem_port(core1_mem));

    icache #(.LINES(IC_LINES)) u_ic2 (.clk(clk), .rst(rst), .req_valid(imem2_req_valid), .req_ready(imem2_req_ready), .req_addr(imem2_req_addr), .resp_valid(imem2_resp_valid), .resp_ready(imem2_resp_ready), .resp_rdata(imem2_resp_rdata), .resp_err(imem2_resp_err), .invalidate(fencei2), .mem(ic2_mem));
    dcache #(.LINES(DC_LINES)) u_dc2 (.clk(clk), .rst(rst), .req_valid(dmem2_req_valid), .req_ready(dmem2_req_ready), .req_addr(dmem2_req_addr), .req_write(dmem2_req_write), .req_wdata(dmem2_req_wdata), .req_wstrb(dmem2_req_wstrb), .resp_valid(dmem2_resp_valid), .resp_ready(dmem2_resp_ready), .resp_rdata(dmem2_resp_rdata), .resp_err(dmem2_resp_err), .invalidate_all(1'b0), .mem(dc2_mem));
    cache_arbiter u_arb2 (.clk(clk), .rst(rst), .ic_port(ic2_mem), .dc_port(dc2_mem), .mem_port(core2_mem));

    icache #(.LINES(IC_LINES)) u_ic3 (.clk(clk), .rst(rst), .req_valid(imem3_req_valid), .req_ready(imem3_req_ready), .req_addr(imem3_req_addr), .resp_valid(imem3_resp_valid), .resp_ready(imem3_resp_ready), .resp_rdata(imem3_resp_rdata), .resp_err(imem3_resp_err), .invalidate(fencei3), .mem(ic3_mem));
    dcache #(.LINES(DC_LINES)) u_dc3 (.clk(clk), .rst(rst), .req_valid(dmem3_req_valid), .req_ready(dmem3_req_ready), .req_addr(dmem3_req_addr), .req_write(dmem3_req_write), .req_wdata(dmem3_req_wdata), .req_wstrb(dmem3_req_wstrb), .resp_valid(dmem3_resp_valid), .resp_ready(dmem3_resp_ready), .resp_rdata(dmem3_resp_rdata), .resp_err(dmem3_resp_err), .invalidate_all(1'b0), .mem(dc3_mem));
    cache_arbiter u_arb3 (.clk(clk), .rst(rst), .ic_port(ic3_mem), .dc_port(dc3_mem), .mem_port(core3_mem));

    mem_arbiter4_rr u_rr (
        .clk(clk), .rst(rst),
        .m0(core0_mem), .m1(core1_mem), .m2(core2_mem), .m3(core3_mem),
        .mem(ram_mem)
    );

    simple_ram #(.MEM_BYTES(MEM_BYTES), .INIT_HEX(MEM_INIT_HEX)) u_ram (
        .clk(clk), .rst(rst), .mem(ram_mem)
    );

    // -------------------------------------------------------------------------
    // Tetris subsystem + GPU output
    // -------------------------------------------------------------------------
    tetris_rtl_system #(.KEY_BITS(AES_KEY_BITS)) u_tetris (
        .clk(clk), .rst(rst), .mode_sel(tetris_mode_sel),
        .se_enable(se_key_enable), .key_update(se_key_update), .key_in(se_key), .seed_in(se_seed),
        .cpu_ctrl_valid(cpu_ctrl_valid), .cpu_ctrl_word(cpu_ctrl_word), .cpu_ctrl_encrypted(cpu_ctrl_encrypted), .cpu_ctrl_ct(cpu_ctrl_ct),
        .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b), .vga_hsync(vga_hsync), .vga_vsync(vga_vsync)
    );
endmodule
