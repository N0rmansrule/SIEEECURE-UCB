// -----------------------------------------------------------------------------
// se_pkg.sv
// SIEEECURE custom instruction definitions (Custom-0 opcode).
// -----------------------------------------------------------------------------
package se_pkg;

  // SE custom opcode uses rv64_pkg::OPCODE_CUSTOM0 (0x0B)

  // funct3 encodings
  localparam logic [2:0] SE_FUNCT3_RTYPE = 3'b000; // se.op eRd, eRs1, eRs2 (funct7 selects op)
  localparam logic [2:0] SE_FUNCT3_LD    = 3'b001; // se.ld eRd, imm(rs1) (loads 128-bit ciphertext)
  localparam logic [2:0] SE_FUNCT3_SD    = 3'b010; // se.sd eRs2, imm(rs1) (stores 128-bit ciphertext)

  // funct7 operation codes for SE_RTYPE
  localparam logic [6:0] SEOP_ADD  = 7'h00;
  localparam logic [6:0] SEOP_SUB  = 7'h01;
  localparam logic [6:0] SEOP_XOR  = 7'h02;
  localparam logic [6:0] SEOP_AND  = 7'h03;
  localparam logic [6:0] SEOP_OR   = 7'h04;
  localparam logic [6:0] SEOP_SLL  = 7'h05;
  localparam logic [6:0] SEOP_SRL  = 7'h06;
  localparam logic [6:0] SEOP_SRA  = 7'h07;

  // Optional encrypted floating-point ops (payload interpreted as IEEE-754 FP64)
  localparam logic [6:0] SEOP_FADD = 7'h10;
  localparam logic [6:0] SEOP_FMUL = 7'h11;

endpackage
