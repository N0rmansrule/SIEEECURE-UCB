// -----------------------------------------------------------------------------
// Simple Branch History Table (BHT) using 2-bit saturating counters.
//
// Purpose:
//   - Predict whether a branch will be taken based on past behavior.
//   - Each entry is a 2-bit counter (classic scheme):
//        00 = Strongly Not Taken
//        01 = Weakly  Not Taken
//        10 = Weakly  Taken
//        11 = Strongly Taken
//
// Prediction rule:
//   - Use the MSB of the counter as the prediction bit.
//       MSB = 0 -> predict NOT taken
//       MSB = 1 -> predict taken
//
// Indexing:
//   - We index using word-aligned PC bits.
//   - RISC-V instructions are 32-bit aligned in RV64I base ISA (PC[1:0] = 0),
//     so we ignore the byte offset by starting at INDEX_LSB = 2.
//   - Index bits are extracted as: PC[INDEX_LSB +: INDEX_BITS]
//
// Interface:
//   - PC_FETCH provides the PC of the instruction currently being predicted.
//   - PRED_TAKEN outputs the predicted direction.
//   - UPDATE interface tells us when a branch resolved and what it actually did.
// -----------------------------------------------------------------------------

module BHT (
    input  wire        CLOCK,
    input  wire        RESET_N,

    // Fetch side: give BHT the PC you want a prediction for
    input  wire [63:0] PC_FETCH,
    output wire        PRED_TAKEN,

    // Update side: when a branch resolves, update the counter
    input  wire        UPDATE_VALID,
    input  wire [63:0] UPDATE_PC,
    input  wire        UPDATE_TAKEN
);
    // -----------------------------
    // Parameters
    // -----------------------------
    parameter DEPTH     = 256; // Number of entries in the BHT
    parameter INDEX_LSB = 2;   // Ignore byte offset bits [1:0]

    // INDEX_BITS must be log2(DEPTH). DEPTH should be power-of-two.
    localparam INDEX_BITS = $clog2(DEPTH);

    // -----------------------------
    // Storage: 2-bit counters
    // -----------------------------
    reg [1:0] COUNTER_TABLE [0:DEPTH-1];

    // -----------------------------
    // Compute indices for fetch & update
    // -----------------------------
    wire [INDEX_BITS-1:0] FETCH_INDEX  = PC_FETCH [INDEX_LSB +: INDEX_BITS];
    wire [INDEX_BITS-1:0] UPDATE_INDEX = UPDATE_PC[INDEX_LSB +: INDEX_BITS];

    // -----------------------------
    // Prediction
    //   Use MSB of the counter as prediction.
    // -----------------------------
    assign PRED_TAKEN = COUNTER_TABLE[FETCH_INDEX][1];

    // -----------------------------
    // Reset / Update logic
    // -----------------------------
    integer i;

    always @(posedge CLOCK or negedge RESET_N) begin
        if (!RESET_N) begin
            // Initialize all entries to weakly-not-taken (01).
            // This is a common default: not too biased, but avoids "always taken".
            for (i = 0; i < DEPTH; i = i + 1) begin
                COUNTER_TABLE[i] <= 2'b01;
            end
        end else if (UPDATE_VALID) begin
            // 2-bit saturating counter update:
            // - If the branch was taken: increment counter unless already 11
            // - If the branch was not taken: decrement counter unless already 00
            case (COUNTER_TABLE[UPDATE_INDEX])
                2'b00: COUNTER_TABLE[UPDATE_INDEX] <= UPDATE_TAKEN ? 2'b01 : 2'b00;
                2'b01: COUNTER_TABLE[UPDATE_INDEX] <= UPDATE_TAKEN ? 2'b10 : 2'b00;
                2'b10: COUNTER_TABLE[UPDATE_INDEX] <= UPDATE_TAKEN ? 2'b11 : 2'b01;
                2'b11: COUNTER_TABLE[UPDATE_INDEX] <= UPDATE_TAKEN ? 2'b11 : 2'b10;
            endcase
        end
    end

endmodule
