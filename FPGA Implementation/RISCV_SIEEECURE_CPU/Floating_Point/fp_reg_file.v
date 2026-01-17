// fp_reg_file.v
// -----------------------------------------------------------------------------
// RISC-V Floating-Point Register File (for RV64F binary32)
//  - 32 registers (f0..f31), 32-bit each for single-precision values.
//  - 3 read ports to support instructions like FMADD (needs fs1, fs2, fs3).
//  - 1 write port for fd.
//
// IEEE-754 relevance:
//  - The register file stores raw IEEE-754 bit patterns. No interpretation
//    happens here. This is exactly how hardware stores FP registers.
//  - Unlike integer x0, floating register f0 is NOT hardwired to 0.
//
// Hazard handling:
//  - Same-cycle write bypass: if you write a register and read it in the same
//    cycle, you see the new data (common requirement for simple pipelines).
// -----------------------------------------------------------------------------

module fp_reg_file (
    input  wire        clk,
    input  wire        we,
    input  wire [4:0]  ra1, ra2, ra3,
    input  wire [4:0]  wa,
    input  wire [31:0] wd,
    output wire [31:0] rd1, rd2, rd3
);
    parameter DEPTH = 32;

    reg [31:0] mem [0:DEPTH-1];

    // Combinational reads with write-bypass.
    assign rd1 = (we && (wa == ra1)) ? wd : mem[ra1];
    assign rd2 = (we && (wa == ra2)) ? wd : mem[ra2];
    assign rd3 = (we && (wa == ra3)) ? wd : mem[ra3];

    // Synchronous write.
    always @(posedge clk) begin
        if (we) begin
            mem[wa] <= wd;
        end
    end
endmodule
