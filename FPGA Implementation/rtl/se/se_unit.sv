// -----------------------------------------------------------------------------
// se_unit.sv
// SIEEECURE "sequestered encryption" execution unit.
//
// Ciphertext format (128-bit):
//   [127:64] = ctr  (per-value counter / tweak)
//   [63:0]   = enc_payload  (payload XOR AES_keystream_low64)
//
// Keystream generation (CTR-like):
//   ks = AES_encrypt({seed, ctr})
//   payload = enc_payload XOR ks[63:0]
//
// For result encryption we allocate a fresh ctr from an internal counter.
//
// Notes:
// - Uses a single iterative AES core, so an SE.RTYPE op has a latency of
//   ~3*NR cycles (decrypt A, decrypt B, encrypt result) + misc overhead.
// - This is area-friendly; to increase throughput you can instantiate
//   multiple AES lanes (not included here).
// -----------------------------------------------------------------------------
module se_unit #(
    parameter int KEY_BITS = 128
)(
    input  wire         clk,
    input  wire         rst,

    input  wire         se_enable,
    input  wire         key_update,
    input  wire [KEY_BITS-1:0] key_in,
    input  wire [63:0]  seed_in,

    // Request
    input  wire         req_valid,
    output wire         req_ready,
    input  wire [6:0]   op,
    input  wire [127:0] ct_a,
    input  wire [127:0] ct_b,

    // Response
    output wire         resp_valid,
    input  wire         resp_ready,
    output wire [127:0] ct_y,
    output wire         resp_err
);
    import se_pkg::*;

    // AES core
    wire aes_key_ready;
    reg  aes_key_load;
    reg  aes_start;
    reg  [127:0] aes_block_in;
    wire aes_busy;
    wire aes_done;
    wire [127:0] aes_block_out;

    aes_enc_core #(.KEY_BITS(KEY_BITS)) u_aes (
        .clk(clk),
        .rst(rst),
        .key_load(aes_key_load),
        .key_in(key_in),
        .key_ready(aes_key_ready),
        .start(aes_start),
        .block_in(aes_block_in),
        .busy(aes_busy),
        .done(aes_done),
        .block_out(aes_block_out)
    );

    // Optional FP unit for SEOP_FADD/SEOP_FMUL (simulation-friendly wrapper)
    // You can replace this with a vendor IEEE-754 compliant FPU IP.
    wire fpu_busy, fpu_done;
    wire [63:0] fpu_y;
    reg  fpu_start;
    reg  [1:0] fpu_op;
    reg  [63:0] fpu_a, fpu_b;

    fpu_fp64_unit u_fpu (
        .clk(clk),
        .rst(rst),
        .start(fpu_start),
        .op(fpu_op),
        .a(fpu_a),
        .b(fpu_b),
        .busy(fpu_busy),
        .done(fpu_done),
        .y(fpu_y)
    );

    // Internal counter for fresh ciphertext ctr values
    reg [63:0] ctr_counter;

    // FSM
    typedef enum logic [2:0] {S_IDLE, S_KSA, S_KSB, S_FPU, S_KSO, S_RESP} state_t;
    state_t state;

    reg [6:0]   op_r;
    reg [127:0] cta_r, ctb_r;

    reg [63:0]  pt_a, pt_b;
    reg [63:0]  res_payload;
    reg [63:0]  ctr_out;

    reg [127:0] ct_y_r;
    reg resp_v_r;
    reg resp_err_r;

    assign req_ready  = (state == S_IDLE);
    assign resp_valid = resp_v_r;
    assign ct_y       = ct_y_r;
    assign resp_err   = resp_err_r;

    // AES control defaults
    always @(*) begin
        aes_key_load  = 1'b0;
        aes_start     = 1'b0;
        aes_block_in  = 128'd0;

        fpu_start     = 1'b0;
        fpu_op        = 2'd0;
        fpu_a         = 64'd0;
        fpu_b         = 64'd0;

        if (key_update) begin
            aes_key_load = 1'b1;
        end

        case (state)
            S_KSA: begin
                aes_start    = !aes_busy; // start when idle
                aes_block_in = {seed_in, cta_r[127:64]};
            end
            S_KSB: begin
                aes_start    = !aes_busy;
                aes_block_in = {seed_in, ctb_r[127:64]};
            end
            S_KSO: begin
                aes_start    = !aes_busy;
                aes_block_in = {seed_in, ctr_out};
            end
            S_FPU: begin
                fpu_start = !fpu_busy;
                fpu_a = pt_a;
                fpu_b = pt_b;
                if (op_r == SEOP_FADD) fpu_op = 2'd0;
                else if (op_r == SEOP_FMUL) fpu_op = 2'd2;
                else fpu_op = 2'd0;
            end
            default: begin end
        endcase
    end

    // Integer operation helper (combinational)
    function automatic [63:0] se_int_op(input [6:0] opi, input [63:0] a, input [63:0] b);
        begin
            unique case (opi)
                SEOP_ADD: se_int_op = a + b;
                SEOP_SUB: se_int_op = a - b;
                SEOP_XOR: se_int_op = a ^ b;
                SEOP_AND: se_int_op = a & b;
                SEOP_OR : se_int_op = a | b;
                SEOP_SLL: se_int_op = a << b[5:0];
                SEOP_SRL: se_int_op = a >> b[5:0];
                SEOP_SRA: se_int_op = $signed(a) >>> b[5:0];
                default:  se_int_op = a + b;
            endcase
        end
    endfunction

    // Sequential FSM / datapath
    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            ctr_counter <= 64'd1;

            op_r <= 7'd0;
            cta_r <= 128'd0;
            ctb_r <= 128'd0;

            pt_a <= 64'd0;
            pt_b <= 64'd0;
            res_payload <= 64'd0;
            ctr_out <= 64'd0;

            ct_y_r <= 128'd0;
            resp_v_r <= 1'b0;
            resp_err_r <= 1'b0;
        end else begin
            // consume response handshake
            if (resp_v_r && resp_ready) begin
                resp_v_r <= 1'b0;
            end

            case (state)
                S_IDLE: begin
                    if (req_valid && req_ready) begin
                        op_r <= op;
                        cta_r <= ct_a;
                        ctb_r <= ct_b;

                        resp_err_r <= 1'b0;

                        if (!se_enable) begin
                            // SE disabled: respond with error immediately
                            ct_y_r <= 128'd0;
                            resp_err_r <= 1'b1;
                            resp_v_r <= 1'b1;
                            state <= S_RESP;
                        end else if (!aes_key_ready) begin
                            // No key yet: error
                            ct_y_r <= 128'd0;
                            resp_err_r <= 1'b1;
                            resp_v_r <= 1'b1;
                            state <= S_RESP;
                        end else begin
                            // Start decrypt A (keystream A)
                            state <= S_KSA;
                        end
                    end
                end

                S_KSA: begin
                    if (aes_done) begin
                        pt_a <= cta_r[63:0] ^ aes_block_out[63:0];
                        state <= S_KSB;
                    end
                end

                S_KSB: begin
                    if (aes_done) begin
                        pt_b <= ctb_r[63:0] ^ aes_block_out[63:0];

                        // Compute result payload (integer or float)
                        if ((op_r == SEOP_FADD) || (op_r == SEOP_FMUL)) begin
                            state <= S_FPU;
                        end else begin
                            res_payload <= se_int_op(op_r, pt_a, (ctb_r[63:0] ^ aes_block_out[63:0]));
                            // allocate fresh ctr
                            ctr_out <= ctr_counter;
                            ctr_counter <= ctr_counter + 64'd1;
                            state <= S_KSO;
                        end
                    end
                end

                S_FPU: begin
                    if (fpu_done) begin
                        res_payload <= fpu_y;
                        ctr_out <= ctr_counter;
                        ctr_counter <= ctr_counter + 64'd1;
                        state <= S_KSO;
                    end
                end

                S_KSO: begin
                    if (aes_done) begin
                        ct_y_r <= {ctr_out, (res_payload ^ aes_block_out[63:0])};
                        resp_err_r <= 1'b0;
                        resp_v_r <= 1'b1;
                        state <= S_RESP;
                    end
                end

                S_RESP: begin
                    if (!resp_v_r || (resp_v_r && resp_ready)) begin
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
