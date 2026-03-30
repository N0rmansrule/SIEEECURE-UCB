// -----------------------------------------------------------------------------
// Arithmetic Logic Unit for RISC-V 64-bit Instructions
//
// Pure combinational block: given an ALU operation code and two 64-bit operands,
// produces a 64-bit result.
//
// NOTE: For RV64W (word) operations, the core sign-extends the low 32 bits of
// this result. The ALU itself is always 64-bit.
// -----------------------------------------------------------------------------
module ALU(
    input  wire [3:0]  ALU_SELECT,
    input  wire [63:0] A,
    input  wire [63:0] B,
    output wire [63:0] ALU_RESULT
);

    // ALU Operations:
    wire [63:0] AND_RESULT  = A & B;
    wire [63:0] OR_RESULT   = A | B;
    wire [63:0] SRA_RESULT  = $signed(A) >>> B[5:0]; // RV64 uses shift amount [5:0]
    wire [63:0] SRL_RESULT  = A >> B[5:0];
    wire [63:0] XOR_RESULT  = A ^ B;
    wire [63:0] SLTU_RESULT = (A < B) ? 64'd1 : 64'd0;
    wire [63:0] SLT_RESULT  = ($signed(A) < $signed(B)) ? 64'd1 : 64'd0;
    wire [63:0] SLL_RESULT  = A << B[5:0];
    wire [63:0] SUB_RESULT  = $signed(A) - $signed(B);
    wire [63:0] ADD_RESULT  = $signed(A) + $signed(B);
    wire [63:0] LUI_RESULT  = B;

    // ALU - Lookup MUX
    assign ALU_RESULT =
        (ALU_SELECT == 4'b0000) ? AND_RESULT   : // ALU_AND
        (ALU_SELECT == 4'b0001) ? OR_RESULT    : // ALU_OR
        (ALU_SELECT == 4'b0010) ? SRA_RESULT   : // ALU_SRA
        (ALU_SELECT == 4'b0011) ? SRL_RESULT   : // ALU_SRL
        (ALU_SELECT == 4'b0100) ? XOR_RESULT   : // ALU_XOR
        (ALU_SELECT == 4'b0101) ? SLTU_RESULT  : // ALU_SLTU
        (ALU_SELECT == 4'b0110) ? SLT_RESULT   : // ALU_SLT
        (ALU_SELECT == 4'b0111) ? SLL_RESULT   : // ALU_SLL
        (ALU_SELECT == 4'b1000) ? SUB_RESULT   : // ALU_SUB
        (ALU_SELECT == 4'b1001) ? ADD_RESULT   : // ALU_ADD
        (ALU_SELECT == 4'b1010) ? LUI_RESULT   : // ALU_LUI
                                  ADD_RESULT;    // Default

endmodule
