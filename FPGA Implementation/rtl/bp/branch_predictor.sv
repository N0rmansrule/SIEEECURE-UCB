// -----------------------------------------------------------------------------
// branch_predictor.sv
// Simple predictor: BHT (2-bit counters) + direct-mapped BTB + small RAS.
// - Query on IF PC to produce predicted next PC.
// - Update on branch/jump resolution in EX1.
//
// This is intentionally small/FPGA-friendly and uses simple indexing.
// -----------------------------------------------------------------------------
module branch_predictor #(
    parameter int BHT_ENTRIES = 1024,
    parameter int BTB_ENTRIES = 256,
    parameter int RAS_DEPTH   = 8,
    parameter int TAG_BITS    = 20
)(
    input  wire        clk,
    input  wire        rst,

    // Query (IF stage)
    input  wire [63:0] pc_query,
    output wire        pred_taken,
    output wire [63:0] pred_target,

    // Update (EX1 stage resolve)
    input  wire        upd_valid,
    input  wire [63:0] upd_pc,
    input  wire        upd_is_cond_branch,
    input  wire        upd_is_jump,
    input  wire        upd_is_call,
    input  wire        upd_is_return,
    input  wire        upd_taken,
    input  wire [63:0] upd_target,
    input  wire [63:0] upd_pc_plus4
);

    // -------------------------------------------------------------------------
    // BHT: 2-bit saturating counters (00 strongly NT .. 11 strongly T)
    // -------------------------------------------------------------------------
    localparam int BHT_IDX_BITS = (BHT_ENTRIES <= 1) ? 1 : $clog2(BHT_ENTRIES);
    logic [1:0] bht [0:BHT_ENTRIES-1];

    wire [BHT_IDX_BITS-1:0] bht_idx_q = pc_query[2 +: BHT_IDX_BITS];
    wire [BHT_IDX_BITS-1:0] bht_idx_u = upd_pc[2 +: BHT_IDX_BITS];

    wire bht_taken = bht[bht_idx_q][1]; // MSB as direction

    // Update BHT
    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < BHT_ENTRIES; i = i + 1) begin
                bht[i] <= 2'b01; // weakly not-taken
            end
        end else if (upd_valid && upd_is_cond_branch) begin
            if (upd_taken) begin
                if (bht[bht_idx_u] != 2'b11) bht[bht_idx_u] <= bht[bht_idx_u] + 2'b01;
            end else begin
                if (bht[bht_idx_u] != 2'b00) bht[bht_idx_u] <= bht[bht_idx_u] - 2'b01;
            end
        end
    end

    // -------------------------------------------------------------------------
    // BTB: direct-mapped target cache with small tag
    // -------------------------------------------------------------------------
    localparam int BTB_IDX_BITS = (BTB_ENTRIES <= 1) ? 1 : $clog2(BTB_ENTRIES);

    typedef struct packed {
        logic              valid;
        logic [TAG_BITS-1:0] tag;
        logic [63:0]       target;
        logic              is_branch; // conditional
        logic              is_return;
    } btb_entry_t;

    btb_entry_t btb [0:BTB_ENTRIES-1];

    wire [BTB_IDX_BITS-1:0] btb_idx_q = pc_query[2 +: BTB_IDX_BITS];
    wire [BTB_IDX_BITS-1:0] btb_idx_u = upd_pc[2 +: BTB_IDX_BITS];

    wire [TAG_BITS-1:0] tag_q = pc_query[2+BTB_IDX_BITS +: TAG_BITS];
    wire [TAG_BITS-1:0] tag_u = upd_pc[2+BTB_IDX_BITS +: TAG_BITS];

    wire btb_hit = btb[btb_idx_q].valid && (btb[btb_idx_q].tag == tag_q);

    // BTB update
    always_ff @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < BTB_ENTRIES; i = i + 1) begin
                btb[i].valid     <= 1'b0;
                btb[i].tag       <= '0;
                btb[i].target    <= 64'd0;
                btb[i].is_branch <= 1'b0;
                btb[i].is_return <= 1'b0;
            end
        end else if (upd_valid && (upd_is_cond_branch || upd_is_jump)) begin
            btb[btb_idx_u].valid     <= 1'b1;
            btb[btb_idx_u].tag       <= tag_u;
            btb[btb_idx_u].target    <= upd_target;
            btb[btb_idx_u].is_branch <= upd_is_cond_branch;
            btb[btb_idx_u].is_return <= upd_is_return;
        end
    end

    // -------------------------------------------------------------------------
    // RAS: return address stack
    // -------------------------------------------------------------------------
    logic [63:0] ras [0:RAS_DEPTH-1];
    logic [$clog2(RAS_DEPTH):0] ras_sp; // points to next free slot

    wire ras_empty = (ras_sp == 0);

    wire [63:0] ras_top = ras_empty ? 64'd0 : ras[ras_sp-1];

    always_ff @(posedge clk) begin
        if (rst) begin
            ras_sp <= '0;
            for (i = 0; i < RAS_DEPTH; i = i + 1) begin
                ras[i] <= 64'd0;
            end
        end else if (upd_valid) begin
            if (upd_is_call) begin
                // push
                if (ras_sp < RAS_DEPTH) begin
                    ras[ras_sp] <= upd_pc_plus4;
                    ras_sp <= ras_sp + 1;
                end
            end else if (upd_is_return) begin
                // pop
                if (ras_sp > 0) begin
                    ras_sp <= ras_sp - 1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Prediction
    // -------------------------------------------------------------------------
    wire [63:0] btb_target = btb[btb_idx_q].is_return ? ras_top : btb[btb_idx_q].target;

    // For conditional branches, only take if BHT predicts taken.
    wire pred_dir = btb[btb_idx_q].is_branch ? bht_taken : 1'b1;

    assign pred_taken  = btb_hit && pred_dir;
    assign pred_target = pred_taken ? btb_target : (pc_query + 64'd4);

endmodule
