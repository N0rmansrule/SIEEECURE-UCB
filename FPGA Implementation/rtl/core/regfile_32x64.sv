// -----------------------------------------------------------------------------
// regfile_32x64.sv
// 32 x 64-bit integer register file.
// - 2 async read ports
// - 1 sync write port
// - x0 is hardwired to zero
// -----------------------------------------------------------------------------
module regfile_32x64(
    input  wire        clk,
    input  wire        rst,

    input  wire [4:0]  raddr1,
    input  wire [4:0]  raddr2,
    output wire [63:0] rdata1,
    output wire [63:0] rdata2,

    input  wire        we,
    input  wire [4:0]  waddr,
    input  wire [63:0] wdata
);
    logic [63:0] regs [0:31];
    integer i;

    // Synchronous write
    always_ff @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 32; i = i + 1) begin
                regs[i] <= 64'd0;
            end
        end else begin
            if (we && (waddr != 5'd0)) begin
                regs[waddr] <= wdata;
            end
            regs[0] <= 64'd0; // keep x0 zero
        end
    end

    // Asynchronous read
    assign rdata1 = (raddr1 == 5'd0) ? 64'd0 : regs[raddr1];
    assign rdata2 = (raddr2 == 5'd0) ? 64'd0 : regs[raddr2];

endmodule
