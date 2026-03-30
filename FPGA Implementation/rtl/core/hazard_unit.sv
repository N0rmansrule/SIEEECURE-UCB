// -----------------------------------------------------------------------------
// hazard_unit.sv
// Simple hazard detection + forwarding for an in-order pipeline.
//
// - Detects classic load-use hazard (load in MEM1, consumer in ID)
// - Computes forwarding select for EX1 rs1/rs2 from MEM1/EX2/WB
// -----------------------------------------------------------------------------
module hazard_unit(
    // ID stage (next to enter EX1)
    input  wire        id_valid,
    input  wire [4:0]  id_rs1,
    input  wire [4:0]  id_rs2,
    input  wire        id_use_rs1,
    input  wire        id_use_rs2,

    // EX1 stage (needs forwarding)
    input  wire        ex1_valid,
    input  wire [4:0]  ex1_rs1,
    input  wire [4:0]  ex1_rs2,
    input  wire        ex1_use_rs1,
    input  wire        ex1_use_rs2,

    // MEM1 stage (older)
    input  wire        mem1_valid,
    input  wire [4:0]  mem1_rd,
    input  wire        mem1_reg_wen,
    input  wire        mem1_is_load,

    // EX2 stage (older)
    input  wire        ex2_valid,
    input  wire [4:0]  ex2_rd,
    input  wire        ex2_reg_wen,

    // WB stage (oldest)
    input  wire        wb_valid,
    input  wire [4:0]  wb_rd,
    input  wire        wb_reg_wen,

    // Outputs
    output wire        stall_id,
    output wire [1:0]  fwd_a_sel,
    output wire [1:0]  fwd_b_sel
);
    import rv64_pkg::*;

    // -------------------------------------------------------------------------
    // Load-use hazard (stall ID for 1 cycle, letting load advance to EX2).
    // -------------------------------------------------------------------------
    wire id_haz_rs1 = id_valid && id_use_rs1 && (id_rs1 != 5'd0) &&
                      mem1_valid && mem1_is_load && mem1_reg_wen &&
                      (mem1_rd == id_rs1);

    wire id_haz_rs2 = id_valid && id_use_rs2 && (id_rs2 != 5'd0) &&
                      mem1_valid && mem1_is_load && mem1_reg_wen &&
                      (mem1_rd == id_rs2);

    assign stall_id = id_haz_rs1 || id_haz_rs2;

    // -------------------------------------------------------------------------
    // Forwarding selects for EX1 operands
    // Priority: MEM1 (non-load) > EX2 > WB > no-forward
    // -------------------------------------------------------------------------
    reg [1:0] sel_a, sel_b;

    always @(*) begin
        sel_a = FWD_NONE;
        sel_b = FWD_NONE;

        // rs1 forwarding
        if (ex1_valid && ex1_use_rs1 && (ex1_rs1 != 5'd0)) begin
            if (mem1_valid && mem1_reg_wen && !mem1_is_load && (mem1_rd == ex1_rs1)) begin
                sel_a = FWD_MEM1;
            end else if (ex2_valid && ex2_reg_wen && (ex2_rd == ex1_rs1)) begin
                sel_a = FWD_EX2;
            end else if (wb_valid && wb_reg_wen && (wb_rd == ex1_rs1)) begin
                sel_a = FWD_WB;
            end else begin
                sel_a = FWD_NONE;
            end
        end

        // rs2 forwarding
        if (ex1_valid && ex1_use_rs2 && (ex1_rs2 != 5'd0)) begin
            if (mem1_valid && mem1_reg_wen && !mem1_is_load && (mem1_rd == ex1_rs2)) begin
                sel_b = FWD_MEM1;
            end else if (ex2_valid && ex2_reg_wen && (ex2_rd == ex1_rs2)) begin
                sel_b = FWD_EX2;
            end else if (wb_valid && wb_reg_wen && (wb_rd == ex1_rs2)) begin
                sel_b = FWD_WB;
            end else begin
                sel_b = FWD_NONE;
            end
        end
    end

    assign fwd_a_sel = sel_a;
    assign fwd_b_sel = sel_b;

endmodule
