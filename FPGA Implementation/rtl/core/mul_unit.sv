// -----------------------------------------------------------------------------
// mul_unit.sv
// Combinational multiply unit for RV64M.
// Supports MUL/MULH/MULHSU/MULHU and MULW.
// -----------------------------------------------------------------------------
module mul_unit(
    input  wire [2:0]  funct3,
    input  wire        is_word, // 1 for MULW
    input  wire [63:0] a,
    input  wire [63:0] b,
    output wire [63:0] y
);
    // 64-bit products
    wire signed [127:0] prod_ss = $signed(a) * $signed(b);
    wire        [127:0] prod_uu = $unsigned(a) * $unsigned(b);
    wire signed [127:0] prod_su = $signed(a) * $signed({1'b0, b[62:0]}); // approximate signed*unsigned

    // NOTE: Some tools don't like mixed signed/unsigned in one expression.
    // For MULHSU we treat 'b' as unsigned by zero-extending into a signed container.
    wire signed [127:0] b_zu = $signed({1'b0, b});
    wire signed [127:0] prod_hsu = $signed(a) * b_zu;

    // MULW
    wire signed [31:0] a32 = a[31:0];
    wire signed [31:0] b32 = b[31:0];
    wire signed [63:0] prod_w = a32 * b32;
    wire [63:0] mulw_res = {{32{prod_w[31]}}, prod_w[31:0]};

    reg [63:0] out;
    always @(*) begin
        out = 64'd0;
        if (is_word) begin
            out = mulw_res;
        end else begin
            case (funct3)
                3'b000: out = prod_ss[63:0];    // MUL
                3'b001: out = prod_ss[127:64];  // MULH
                3'b010: out = prod_hsu[127:64]; // MULHSU
                3'b011: out = prod_uu[127:64];  // MULHU
                default: out = prod_ss[63:0];
            endcase
        end
    end

    assign y = out;

endmodule
