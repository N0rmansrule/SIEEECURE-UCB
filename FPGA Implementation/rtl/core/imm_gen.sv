// -----------------------------------------------------------------------------
// imm_gen.sv
// Immediate generator for RV64 instructions.
// Produces sign-extended 64-bit immediates for I/S/B/U/J formats.
// -----------------------------------------------------------------------------
module imm_gen(
    input  wire [31:0] instr,
    output wire [63:0] imm_i,
    output wire [63:0] imm_s,
    output wire [63:0] imm_b,
    output wire [63:0] imm_u,
    output wire [63:0] imm_j
);
    // I-type: imm[11:0] = instr[31:20]
    wire [11:0] i_imm = instr[31:20];
    assign imm_i = {{52{i_imm[11]}}, i_imm};

    // S-type: imm[11:5]=instr[31:25], imm[4:0]=instr[11:7]
    wire [11:0] s_imm = {instr[31:25], instr[11:7]};
    assign imm_s = {{52{s_imm[11]}}, s_imm};

    // B-type: imm[12|10:5|4:1|11] = {instr[31],instr[30:25],instr[11:8],instr[7]}
    wire [12:0] b_imm = {instr[31], instr[30:25], instr[11:8], instr[7], 1'b0};
    assign imm_b = {{51{b_imm[12]}}, b_imm};

    // U-type: imm[31:12] = instr[31:12], low 12 bits zero
    wire [31:0] u_imm = {instr[31:12], 12'b0};
    assign imm_u = {{32{u_imm[31]}}, u_imm};

    // J-type: imm[20|10:1|11|19:12] = {instr[31],instr[30:21],instr[20],instr[19:12]}
    wire [20:0] j_imm = {instr[31], instr[30:21], instr[20], instr[19:12], 1'b0};
    assign imm_j = {{43{j_imm[20]}}, j_imm};

endmodule
