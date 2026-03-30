// -----------------------------------------------------------------------------
// simple_mem_if.sv
// A lightweight, FPGA-friendly 16-byte line memory interface.
//
// Request:
//   req_valid/req_ready handshake
//   req_addr  : 16-byte aligned address
//   req_write : 0=read, 1=write
//   req_wdata : 16-byte write data
//   req_wstrb : byte strobes (one per byte)
//
// Response:
//   resp_valid/resp_ready handshake
//   resp_rdata : 16-byte read data (valid for reads; for writes may be don't-care)
//   resp_err   : indicates fault (unmapped / bus error)
//
// This interface is used between caches and the external memory model/controller.
// -----------------------------------------------------------------------------
interface simple_mem_if;
    logic        req_valid;
    logic        req_ready;
    logic [63:0] req_addr;
    logic        req_write;
    logic [127:0] req_wdata;
    logic [15:0]  req_wstrb;

    logic        resp_valid;
    logic        resp_ready;
    logic [127:0] resp_rdata;
    logic        resp_err;

    modport master (
        output req_valid, output req_addr, output req_write, output req_wdata, output req_wstrb,
        input  req_ready,
        input  resp_valid, input resp_rdata, input resp_err,
        output resp_ready
    );

    modport slave (
        input  req_valid, input req_addr, input req_write, input req_wdata, input req_wstrb,
        output req_ready,
        output resp_valid, output resp_rdata, output resp_err,
        input  resp_ready
    );
endinterface
