// -----------------------------------------------------------------------------
// entropy_conditioner.sv
// Lightweight entropy conditioner / key extractor for FPGA use.
//
// This is intentionally smaller than a full SHA-256 conditioner so it is easier
// to fit into an ECP5-85K together with multiple cores. It collects 256 bits of
// raw entropy, mixes them with 64-bit avalanche functions, and emits:
//   - key_out  (KEY_BITS)
//   - seed_out (64 bits)
//   - key_update pulse
//
// For production work, replace this module with a standards-driven conditioner
// (e.g. SHA-256 or SP800-90B-compatible health testing + extraction).
// -----------------------------------------------------------------------------
module entropy_conditioner #(
    parameter int KEY_BITS = 128
)(
    input  wire              clk,
    input  wire              rst,

    input  wire              in_valid,
    input  wire [7:0]        in_data,
    output wire              in_ready,

    input  wire              reseed_req,
    output logic             key_update,
    output logic [KEY_BITS-1:0] key_out,
    output logic [63:0]      seed_out,
    output logic             entropy_ready
);
    logic [255:0] raw_shift;
    logic [5:0]   byte_count;

    assign in_ready = 1'b1;

    function automatic [63:0] mix64(input [63:0] x0);
        logic [63:0] x;
        begin
            x = x0;
            x = x ^ (x >> 33);
            x = x * 64'hff51afd7ed558ccd;
            x = x ^ (x >> 33);
            x = x * 64'hc4ceb9fe1a85ec53;
            x = x ^ (x >> 33);
            mix64 = x;
        end
    endfunction

    function automatic [KEY_BITS-1:0] derive_key(input [255:0] r);
        logic [63:0] w0, w1, w2, w3;
        logic [255:0] tmp;
        begin
            w0 = mix64(r[ 63:  0] ^ r[255:192]);
            w1 = mix64(r[127: 64] ^ r[191:128]);
            w2 = mix64(r[191:128] ^ r[127: 64] ^ 64'hA5A5A5A5A5A5A5A5);
            w3 = mix64(r[255:192] ^ r[ 63:  0] ^ 64'h5A5A5A5A5A5A5A5A);
            tmp = {w3,w2,w1,w0};
            derive_key = tmp[KEY_BITS-1:0];
        end
    endfunction

    function automatic [63:0] derive_seed(input [255:0] r);
        begin
            derive_seed = mix64(r[63:0] ^ r[127:64] ^ r[191:128] ^ r[255:192]);
        end
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            raw_shift <= 256'd0;
            byte_count <= 6'd0;
            key_out <= '0;
            seed_out <= 64'd0;
            key_update <= 1'b0;
            entropy_ready <= 1'b0;
        end else begin
            key_update <= 1'b0;

            if (reseed_req) begin
                entropy_ready <= 1'b0;
                byte_count <= 6'd0;
            end

            if (in_valid && in_ready) begin
                raw_shift <= {raw_shift[247:0], in_data};
                if (byte_count == 6'd31) begin
                    byte_count <= 6'd0;
                    key_out <= derive_key({raw_shift[247:0], in_data});
                    seed_out <= derive_seed({raw_shift[247:0], in_data});
                    key_update <= 1'b1;
                    entropy_ready <= 1'b1;
                end else begin
                    byte_count <= byte_count + 6'd1;
                end
            end
        end
    end
endmodule
