// -----------------------------------------------------------------------------
// Arithmetic Logic Unit for RISC-V 64 bit Instructions
//
// This is a pure combinational block: given an ALU operation code and two
// 64-bit operands, it produces a 64-bit result.
// -----------------------------------------------------------------------------

module ALU(
    input wire [3:0] ALU_SELECT,
    input wire [63:0] A,
    input wire [63:0] B,
    output wire [63:0] ALU_RESULT
);

    // ALU Operations:
    wire [63:0] AND_RESULT  = A & B;
    wire [63:0] OR_RESULT   = A | B;
    wire [63:0] SRA_RESULT  = $signed(A) >>> B[5:0]; // RISC-V 64 bit uses shift amount of 6 bits (0 through 63)
    wire [63:0] SRL_RESULT  = A >> B[5:0]; // RISC-V 64 bit uses shift amount of 6 bits (0 through 63)
    wire [63:0] XOR_RESULT  = A ^ B;
    wire [63:0] SLTU_RESULT = (A < B) ? 64'd1 : 64'd0;
    wire [63:0] SLT_RESULT  = ($signed(A) < $signed(B)) ? 64'd1 : 64'd0;
    wire [63:0] SLL_RESULT  = A << B[5:0]; // RISC-V 64 bit uses shift amount of 6 bits (0 through 63)
    wire [63:0] SUB_RESULT  = $signed(A) - $signed(B);
    wire [63:0] ADD_RESULT  = $signed(A) + $signed(B);
    wire [63:0] LUI_RESULT  = B;
    
    // ALU - Lookup MUX
    assign ALU_RESULT =
        (ALU_SELECT == 4'b0000) ? AND_RESULT   : // ALU_AND
        (ALU_SELECT == 4'b0001) ? OR_RESULT    : // ALU_OR
        (ALU_SELECT == 4'b0010) ? SRA_RESULT   : // ALU_SRA - Shift Right Arithmetic
        (ALU_SELECT == 4'b0011) ? SRL_RESULT   : // ALU_SRL - Shift Logical Right
        (ALU_SELECT == 4'b0100) ? XOR_RESULT   : // ALU_XOR
        (ALU_SELECT == 4'b0101) ? SLTU_RESULT  : // ALU_SLTU - Unsigned Set Less Than 
        (ALU_SELECT == 4'b0110) ? SLT_RESULT   : // ALU_SLT - Signed Set Less Than
        (ALU_SELECT == 4'b0111) ? SLL_RESULT   : // ALU_SLL - Shift Logical Left
        (ALU_SELECT == 4'b1000) ? SUB_RESULT   : // ALU_SUB
        (ALU_SELECT == 4'b1001) ? ADD_RESULT   : // ALU_ADD
        (ALU_SELECT == 4'b1010) ? LUI_RESULT   : // ALU_LUI - Load upper immediate (shift left 12 bits done in immediate generator)
                                  ADD_RESULT;    // Default Operation

endmodule