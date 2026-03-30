// -----------------------------------------------------------------------------
// simple_ram.sv
// A small 16-byte line memory model implementing simple_mem_if.
//
// - Byte-addressed memory.
// - Line reads return 16 bytes at aligned req_addr.
// - Writes apply byte strobes.
// - One request in-flight; one-cycle latency from accept to response.
// - Loads optional init hex file via parameter INIT_HEX or +MEMHEX=<file>.
// -----------------------------------------------------------------------------
module simple_ram #(
    parameter int    MEM_BYTES = 1<<20, // 1 MiB
    parameter string INIT_HEX  = ""
)(
    input  wire clk,
    input  wire rst,
    simple_mem_if.slave mem
);
    // Byte-addressed storage
    logic [7:0] mem_array [0:MEM_BYTES-1];

// Optional init
// - Simulation: can also load via +MEMHEX=<file>
// - Synthesis: uses INIT_HEX parameter only (plusargs are not synthesizable)
`ifndef SYNTHESIS
  string hexfile;
  initial begin
      hexfile = INIT_HEX;
      if (hexfile == "") begin
          void'($value$plusargs("MEMHEX=%s", hexfile));
      end
      if (hexfile != "") begin
          $display("simple_ram: loading %s", hexfile);
          $readmemh(hexfile, mem_array);
      end
  end
`else
  initial begin
      if (INIT_HEX != "") begin
          $readmemh(INIT_HEX, mem_array);
      end
  end
`endif

    // Pending request latch (one outstanding)
    logic        pend;
    logic [63:0] pend_addr;
    logic        pend_write;
    logic [127:0] pend_wdata;
    logic [15:0]  pend_wstrb;

    // Response regs
    logic        resp_v;
    logic [127:0] resp_data;
    logic        resp_err;

    assign mem.req_ready  = !pend;
    assign mem.resp_valid = resp_v;
    assign mem.resp_rdata = resp_data;
    assign mem.resp_err   = resp_err;

    function automatic [127:0] read_line(input [63:0] a);
        integer i;
        reg [127:0] tmp;
        begin
            tmp = 128'd0;
            for (i = 0; i < 16; i=i+1) begin
                if ((a + i) < MEM_BYTES)
                    tmp[i*8 +: 8] = mem_array[a + i];
                else
                    tmp[i*8 +: 8] = 8'h00;
            end
            read_line = tmp;
        end
    endfunction

    task automatic write_line(input [63:0] a, input [127:0] wd, input [15:0] ws);
        integer i;
        begin
            for (i = 0; i < 16; i=i+1) begin
                if (ws[i] && ((a + i) < MEM_BYTES)) begin
                    mem_array[a + i] = wd[i*8 +: 8];
                end
            end
        end
    endtask

    always_ff @(posedge clk) begin
        if (rst) begin
            pend <= 1'b0;
            pend_addr <= 64'd0;
            pend_write <= 1'b0;
            pend_wdata <= 128'd0;
            pend_wstrb <= 16'd0;

            resp_v <= 1'b0;
            resp_data <= 128'd0;
            resp_err <= 1'b0;
        end else begin
            // Consume response
            if (resp_v && mem.resp_ready) begin
                resp_v <= 1'b0;
            end

            // Accept request
            if (mem.req_valid && mem.req_ready) begin
                pend <= 1'b1;
                pend_addr <= mem.req_addr;
                pend_write <= mem.req_write;
                pend_wdata <= mem.req_wdata;
                pend_wstrb <= mem.req_wstrb;
            end

            // Complete pending into response (one-cycle latency), if response slot free
            if (pend && !resp_v) begin
                if (pend_addr >= MEM_BYTES) begin
                    resp_err  <= 1'b1;
                    resp_data <= 128'd0;
                end else begin
                    resp_err <= 1'b0;
                    if (pend_write) begin
                        write_line(pend_addr, pend_wdata, pend_wstrb);
                        resp_data <= 128'd0;
                    end else begin
                        resp_data <= read_line(pend_addr);
                    end
                end
                resp_v <= 1'b1;
                pend   <= 1'b0;
            end
        end
    end
endmodule
