// -----------------------------------------------------------------------------
// eregfile_32x128.sv
// 32 x 128-bit encrypted register file (ciphertext registers).
// - 2 async read ports
// - 1 sync write port
//
// NOTE: e0 is *not* special; you can use all 32 entries for ciphertext.
// -----------------------------------------------------------------------------
module eregfile_32x128(
    input  wire         clk,
    input  wire         rst,

    input  wire [4:0]   raddr1,
    input  wire [4:0]   raddr2,
    output wire [127:0] rdata1,
    output wire [127:0] rdata2,

    input  wire         we,
    input  wire [4:0]   waddr,
    input  wire [127:0] wdata
);
    logic [127:0] regs [0:31];
    integer i;

    // Synchronous write
    always_ff @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 32; i = i + 1) begin
                regs[i] <= 128'd0;
            end
        end else begin
            if (we) begin
                regs[waddr] <= wdata;
            end
        end
    end

    // Asynchronous read
    assign rdata1 = regs[raddr1];
    assign rdata2 = regs[raddr2];

endmodule
