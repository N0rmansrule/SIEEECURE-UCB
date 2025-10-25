module fp_reg_file (
    input clk,
    input we,
    input [4:0] ra1, ra2, ra3, wa,
    input [31:0] wd,
    output [31:0] rd1, rd2, rd3
);
    parameter DEPTH = 32;
    reg [31:0] mem [0:31];
    assign rd1 = 32'd0;
    assign rd2 = 32'd0;
    assign rd3 = 32'd0;
endmodule
