// -----------------------------------------------------------------------------
// branch_comp.sv
// Branch comparator for RV64 conditional branches.
// -----------------------------------------------------------------------------
module branch_comp(
    input  wire [2:0]  funct3,
    input  wire [63:0] rs1,
    input  wire [63:0] rs2,
    output wire        taken
);
    reg t;
    always @(*) begin
        t = 1'b0;
        case (funct3)
            3'b000: t = (rs1 == rs2);                     // BEQ
            3'b001: t = (rs1 != rs2);                     // BNE
            3'b100: t = ($signed(rs1) < $signed(rs2));    // BLT
            3'b101: t = ($signed(rs1) >= $signed(rs2));   // BGE
            3'b110: t = (rs1 < rs2);                      // BLTU
            3'b111: t = (rs1 >= rs2);                     // BGEU
            default: t = 1'b0;
        endcase
    end
    assign taken = t;
endmodule
