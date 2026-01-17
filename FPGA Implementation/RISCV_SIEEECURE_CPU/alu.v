// -----------------------------------------------------------------------------
// Arithmetic Logic Unit for RISC-V 64 bit Instructions
//
// This is a pure combinational block: given an ALU operation encoding and two
// 64-bit operands, it produces a 64-bit result.
// -----------------------------------------------------------------------------

`include "rv64_defs.vh"

module alu(
  input  wire [3:0]  alu_select,
  input  wire [63:0] a,
  input  wire [63:0] b,
  output reg  [63:0] result
);

  wire signed [63:0] signed_a = a;
  wire signed [63:0] signed_b = b;

  always @* begin
    case (alu_select)
      `ALU_ADD:   y = a + b;
      `ALU_SUB:   y = a - b;
      `ALU_AND:   y = a & b;
      `ALU_OR:    y = a | b;
      `ALU_XOR:   y = a ^ b;
      `ALU_SLT:   y = (as < bs) ? 64'd1 : 64'd0;
      `ALU_SLTU:  y = (a  < b ) ? 64'd1 : 64'd0;
      `ALU_SLL:   y = a << b[5:0];
      `ALU_SRL:   y = a >> b[5:0];
      `ALU_SRA:   y = as >>> b[5:0];
      `ALU_FORWARD_B: y = b;
      default:    y = 64'd0;
    endcase
  end

endmodule
