
// -----------------------------------------------------------------------------
// rv64_pkg.sv
// Common constants and types for the SIEEECURE RV64 7-stage core.
// -----------------------------------------------------------------------------
package rv64_pkg;

  // ---------------------------------------------------------------------------
  // RISC-V base opcodes
  // ---------------------------------------------------------------------------
  localparam logic [6:0] OPCODE_LUI      = 7'b0110111;
  localparam logic [6:0] OPCODE_AUIPC    = 7'b0010111;
  localparam logic [6:0] OPCODE_JAL      = 7'b1101111;
  localparam logic [6:0] OPCODE_JALR     = 7'b1100111;
  localparam logic [6:0] OPCODE_BRANCH   = 7'b1100011;
  localparam logic [6:0] OPCODE_LOAD     = 7'b0000011;
  localparam logic [6:0] OPCODE_STORE    = 7'b0100011;
  localparam logic [6:0] OPCODE_OP_IMM   = 7'b0010011;
  localparam logic [6:0] OPCODE_OP       = 7'b0110011;
  localparam logic [6:0] OPCODE_MISC_MEM = 7'b0001111; // FENCE/FENCE.I
  localparam logic [6:0] OPCODE_SYSTEM   = 7'b1110011; // CSR/ECALL/EBREAK/MRET/WFI

  // RV64 "word" opcodes
  localparam logic [6:0] OPCODE_OP_IMM_32 = 7'b0011011;
  localparam logic [6:0] OPCODE_OP_32     = 7'b0111011;

  // Custom opcode space (custom-0)
  localparam logic [6:0] OPCODE_CUSTOM0  = 7'b0001011;

  // ---------------------------------------------------------------------------
  // ALU operation encoding (matches your ALU formatting guide)
  // ---------------------------------------------------------------------------
  localparam logic [3:0] ALU_AND = 4'b0000;
  localparam logic [3:0] ALU_OR  = 4'b0001;
  localparam logic [3:0] ALU_SRA = 4'b0010;
  localparam logic [3:0] ALU_SRL = 4'b0011;
  localparam logic [3:0] ALU_XOR = 4'b0100;
  localparam logic [3:0] ALU_SLTU= 4'b0101;
  localparam logic [3:0] ALU_SLT = 4'b0110;
  localparam logic [3:0] ALU_SLL = 4'b0111;
  localparam logic [3:0] ALU_SUB = 4'b1000;
  localparam logic [3:0] ALU_ADD = 4'b1001;
  localparam logic [3:0] ALU_LUI = 4'b1010;

  // ---------------------------------------------------------------------------
  // Operand select mux encodings
  // ---------------------------------------------------------------------------
  localparam logic [2:0] OP_A_RS1  = 3'd0;
  localparam logic [2:0] OP_A_PC   = 3'd1;
  localparam logic [2:0] OP_A_ZERO = 3'd2;

  localparam logic [2:0] OP_B_RS2  = 3'd0;
  localparam logic [2:0] OP_B_IMM  = 3'd1;
  localparam logic [2:0] OP_B_FOUR = 3'd2;

  // ---------------------------------------------------------------------------
  // Writeback select
  // ---------------------------------------------------------------------------
  localparam logic [2:0] WB_ALU    = 3'd0;
  localparam logic [2:0] WB_PC4    = 3'd1;
  localparam logic [2:0] WB_MEM    = 3'd2;
  localparam logic [2:0] WB_CSR    = 3'd3;
  localparam logic [2:0] WB_MULDIV = 3'd4;

  // ---------------------------------------------------------------------------
  // Memory access size encoding
  // ---------------------------------------------------------------------------
  localparam logic [2:0] MEM_B = 3'd0; // 8-bit
  localparam logic [2:0] MEM_H = 3'd1; // 16-bit
  localparam logic [2:0] MEM_W = 3'd2; // 32-bit
  localparam logic [2:0] MEM_D = 3'd3; // 64-bit
  localparam logic [2:0] MEM_Q = 3'd4; // 128-bit (SE ciphertext block)

  // ---------------------------------------------------------------------------
  // CSR commands
  // ---------------------------------------------------------------------------
  localparam logic [1:0] CSR_NONE  = 2'd0;
  localparam logic [1:0] CSR_WRITE = 2'd1;
  localparam logic [1:0] CSR_SET   = 2'd2;
  localparam logic [1:0] CSR_CLEAR = 2'd3;

  // ---------------------------------------------------------------------------
  // Forwarding select encoding
  // ---------------------------------------------------------------------------
  localparam logic [1:0] FWD_NONE = 2'd0;
  localparam logic [1:0] FWD_MEM1 = 2'd1;
  localparam logic [1:0] FWD_EX2  = 2'd2;
  localparam logic [1:0] FWD_WB   = 2'd3;

endpackage
