// -----------------------------------------------------------------------------
// soc_top.sv
// Simple SoC wrapper: core + I$ + D$ + arbiter + simple_ram.
//
// This top is intended for simulation and small FPGA prototypes.
// -----------------------------------------------------------------------------
module soc_top #(
    parameter logic [63:0] RESET_PC   = 64'h0000_0000_0000_0000,
    parameter int          MEM_BYTES  = 1<<20,
    parameter string       MEM_INIT_HEX = "",
    parameter int          AES_KEY_BITS = 128
)(
    input  wire clk,
    input  wire rst,
    input  wire ext_irq,
    output wire [63:0] dbg_pc
);
    import rv64_pkg::*;

    // Core <-> caches (line interfaces)
    wire         imem_req_valid;
    wire         imem_req_ready;
    wire [63:0]  imem_req_addr;
    wire         imem_resp_valid;
    wire         imem_resp_ready;
    wire [127:0] imem_resp_rdata;
    wire         imem_resp_err;

    wire         dmem_req_valid;
    wire         dmem_req_ready;
    wire [63:0]  dmem_req_addr;
    wire         dmem_req_write;
    wire [127:0] dmem_req_wdata;
    wire [15:0]  dmem_req_wstrb;
    wire         dmem_resp_valid;
    wire         dmem_resp_ready;
    wire [127:0] dmem_resp_rdata;
    wire         dmem_resp_err;

    wire fencei_pulse;

    // Cache <-> memory bus interfaces
    simple_mem_if ic_mem();
    simple_mem_if dc_mem();
    simple_mem_if mem_bus();

    // Core
    rv64_core_7stage #(
        .RESET_PC(RESET_PC),
        .AES_KEY_BITS(AES_KEY_BITS)
    ) u_core (
        .clk(clk),
        .rst(rst),

        .imem_req_valid(imem_req_valid),
        .imem_req_ready(imem_req_ready),
        .imem_req_addr(imem_req_addr),
        .imem_resp_valid(imem_resp_valid),
        .imem_resp_ready(imem_resp_ready),
        .imem_resp_rdata(imem_resp_rdata),
        .imem_resp_err(imem_resp_err),

        .dmem_req_valid(dmem_req_valid),
        .dmem_req_ready(dmem_req_ready),
        .dmem_req_addr(dmem_req_addr),
        .dmem_req_write(dmem_req_write),
        .dmem_req_wdata(dmem_req_wdata),
        .dmem_req_wstrb(dmem_req_wstrb),
        .dmem_resp_valid(dmem_resp_valid),
        .dmem_resp_ready(dmem_resp_ready),
        .dmem_resp_rdata(dmem_resp_rdata),
        .dmem_resp_err(dmem_resp_err),

        .ext_irq(ext_irq),
        .se_ext_mode(1'b0),
        .se_ext_enable(1'b0),
        .se_ext_key_update(1'b0),
        .se_ext_key({AES_KEY_BITS{1'b0}}),
        .se_ext_seed(64'd0),
        .fencei_pulse(fencei_pulse),
        .dbg_pc(dbg_pc)
    );

    // I$
    icache u_icache (
        .clk(clk),
        .rst(rst),

        .req_valid(imem_req_valid),
        .req_ready(imem_req_ready),
        .req_addr(imem_req_addr),

        .resp_valid(imem_resp_valid),
        .resp_ready(imem_resp_ready),
        .resp_rdata(imem_resp_rdata),
        .resp_err(imem_resp_err),

        .invalidate(fencei_pulse),
        .mem(ic_mem)
    );

    // D$
    dcache u_dcache (
        .clk(clk),
        .rst(rst),

        .req_valid(dmem_req_valid),
        .req_ready(dmem_req_ready),
        .req_addr(dmem_req_addr),
        .req_write(dmem_req_write),
        .req_wdata(dmem_req_wdata),
        .req_wstrb(dmem_req_wstrb),

        .resp_valid(dmem_resp_valid),
        .resp_ready(dmem_resp_ready),
        .resp_rdata(dmem_resp_rdata),
        .resp_err(dmem_resp_err),

        .invalidate_all(1'b0),
        .mem(dc_mem)
    );

    // Arbiter (D$ priority over I$)
    cache_arbiter u_arb (
        .clk(clk),
        .rst(rst),
        .ic_port(ic_mem),
        .dc_port(dc_mem),
        .mem_port(mem_bus)
    );

    // Simple RAM
    simple_ram #(
        .MEM_BYTES(MEM_BYTES),
        .INIT_HEX(MEM_INIT_HEX)
    ) u_ram (
        .clk(clk),
        .rst(rst),
        .mem(mem_bus)
    );

endmodule
