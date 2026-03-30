// -----------------------------------------------------------------------------
// fpu_fp64_unit.sv
// Lightweight FP64 unit wrapper.
//
// IMPORTANT:
// - The simulation model uses SystemVerilog real conversions ($bitstoreal),
//   which are *not* synthesizable.
// - For synthesis, vendor tools typically define `SYNTHESIS; in that case this
//   module becomes a stub and should be replaced with an IEEE-754 compliant
//   FPGA FPU IP core.
//
// Supported ops:
//   op=0: add
//   op=1: sub
//   op=2: mul
// -----------------------------------------------------------------------------
module fpu_fp64_unit(
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire [1:0]  op,
    input  wire [63:0] a,
    input  wire [63:0] b,

    output wire        busy,
    output wire        done,
    output wire [63:0] y
);

`ifdef SYNTHESIS
    // Synthesis stub (replace with vendor IP)
    assign busy = 1'b0;
    assign done = start;
    assign y    = 64'd0;
`else
    // Simple fixed-latency pipeline simulation model
    localparam int LAT = 4;

    reg [LAT-1:0] vld_sh;
    reg [63:0]    y_sh [0:LAT-1];

    integer i;

    // Convert bits to real and back
    function automatic [63:0] fp_calc(input [1:0] opi, input [63:0] ai, input [63:0] bi);
        real ra, rb, rr;
        begin
            ra = $bitstoreal(ai);
            rb = $bitstoreal(bi);
            case (opi)
                2'd0: rr = ra + rb;
                2'd1: rr = ra - rb;
                2'd2: rr = ra * rb;
                default: rr = ra + rb;
            endcase
            fp_calc = $realtobits(rr);
        end
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            vld_sh <= '0;
            for (i = 0; i < LAT; i = i + 1) y_sh[i] <= 64'd0;
        end else begin
            vld_sh <= {vld_sh[LAT-2:0], start};
            y_sh[0] <= fp_calc(op, a, b);
            for (i = 1; i < LAT; i = i + 1) begin
                y_sh[i] <= y_sh[i-1];
            end
        end
    end

    assign busy = |vld_sh;
    assign done = vld_sh[LAT-1];
    assign y    = y_sh[LAT-1];
`endif

endmodule
