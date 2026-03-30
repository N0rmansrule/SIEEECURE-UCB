// -----------------------------------------------------------------------------
// div_unit.sv
// Iterative divider for RV64M (DIV/DIVU/REM/REMU, plus *W variants handled by core).
//
// Interface:
//  - start: pulse high for 1 cycle to begin operation
//  - is_rem: 0 => quotient, 1 => remainder
//  - is_signed: 1 => signed division, 0 => unsigned division
//  - busy: high while computing
//  - done: 1-cycle pulse when result is valid
//
// Implements RISC-V specified corner cases:
//  - divide by zero
//  - signed overflow: (-2^63) / (-1)
// -----------------------------------------------------------------------------
module div_unit(
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire        is_rem,
    input  wire        is_signed,
    input  wire [63:0] a,
    input  wire [63:0] b,

    output wire        busy,
    output wire        done,
    output wire [63:0] y
);

    // State
    typedef enum logic [1:0] {IDLE, RUN, FINISH} state_t;
    state_t state;

    logic [63:0] dividend_abs;
    logic [63:0] divisor_abs;
    logic        a_neg, b_neg;

    logic [127:0] rem_shift;
    logic [63:0]  quot;

    logic [6:0]   bit_idx; // 0..64

    logic [63:0]  result_q;
    logic [63:0]  result_r;

    logic done_q;

    // Helpers
    function automatic [63:0] abs64(input [63:0] x);
        abs64 = x[63] ? (~x + 64'd1) : x;
    endfunction

    // Busy/done outputs
    assign busy = (state != IDLE);
    assign done = done_q;
    assign y    = is_rem ? result_r : result_q;

    // Main FSM
    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            dividend_abs <= 64'd0;
            divisor_abs  <= 64'd0;
            a_neg <= 1'b0;
            b_neg <= 1'b0;
            rem_shift <= 128'd0;
            quot <= 64'd0;
            bit_idx <= 7'd0;
            result_q <= 64'd0;
            result_r <= 64'd0;
            done_q <= 1'b0;
        end else begin
            done_q <= 1'b0;

            case (state)
                IDLE: begin
                    if (start) begin
                        // Capture signs and abs values
                        a_neg <= is_signed && a[63];
                        b_neg <= is_signed && b[63];
                        dividend_abs <= (is_signed && a[63]) ? abs64(a) : a;
                        divisor_abs  <= (is_signed && b[63]) ? abs64(b) : b;

                        // Default
                        rem_shift <= 128'd0;
                        quot <= 64'd0;
                        bit_idx <= 7'd64;

                        // Corner cases handled up-front in FINISH
                        state <= RUN;
                    end
                end

                RUN: begin
                    // Handle divide by zero early (go to FINISH)
                    if (divisor_abs == 64'd0) begin
                        // Quotient = all ones, remainder = dividend (per spec)
                        result_q <= 64'hFFFF_FFFF_FFFF_FFFF;
                        result_r <= a;
                        state <= FINISH;
                    end else if (is_signed && (a == 64'h8000_0000_0000_0000) && (b == 64'hFFFF_FFFF_FFFF_FFFF)) begin
                        // Signed overflow: (-2^63)/(-1) => quotient = -2^63, remainder = 0
                        result_q <= 64'h8000_0000_0000_0000;
                        result_r <= 64'd0;
                        state <= FINISH;
                    end else begin
                        // Restoring division algorithm
                        // Shift remainder left by 1, bring next dividend bit into LSB.
                        rem_shift <= {rem_shift[126:0], dividend_abs[bit_idx-1]};
                        // Compare/subtract
                        if (rem_shift[127:64] >= divisor_abs) begin
                            rem_shift[127:64] <= rem_shift[127:64] - divisor_abs;
                            quot[bit_idx-1] <= 1'b1;
                        end else begin
                            quot[bit_idx-1] <= 1'b0;
                        end

                        // Next bit
                        bit_idx <= bit_idx - 7'd1;

                        if (bit_idx == 7'd1) begin
                            // Done iterating
                            // Apply signs
                            // Quotient sign: a_neg xor b_neg
                            // Remainder sign: same as dividend sign (a_neg)
                            if (is_signed) begin
                                result_q <= (a_neg ^ b_neg) ? (~quot + 64'd1) : quot;
                                result_r <= a_neg ? (~rem_shift[127:64] + 64'd1) : rem_shift[127:64];
                            end else begin
                                result_q <= quot;
                                result_r <= rem_shift[127:64];
                            end
                            state <= FINISH;
                        end
                    end
                end

                FINISH: begin
                    done_q <= 1'b1;
                    state  <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
