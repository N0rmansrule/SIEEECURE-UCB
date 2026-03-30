// -----------------------------------------------------------------------------
// se_key_manager.sv
// Shared key manager for SE-enabled CPU/GPU domains.
//
// Provides a control-select feature for choosing the key source:
//   2'b00 manual/static key
//   2'b01 QRNG-conditioned key
//   2'b10 photonic entropy-conditioned key
//   2'b11 mixed QRNG^photonic conditioned key
//
// Outputs are meant to drive the optional external key path of rv64_core_7stage
// and SE-aware GPU blocks.
// -----------------------------------------------------------------------------
module se_key_manager #(
    parameter int KEY_BITS = 128
)(
    input  wire              clk,
    input  wire              rst,

    input  wire [1:0]        entropy_sel,
    input  wire              manual_load,
    input  wire              manual_enable,
    input  wire [KEY_BITS-1:0] manual_key,
    input  wire [63:0]       manual_seed,

    input  wire              qrng_valid,
    input  wire [7:0]        qrng_data,
    input  wire              photon_valid,
    input  wire [7:0]        photon_data,

    input  wire              reseed_req,

    output logic             se_enable,
    output logic             key_update,
    output logic [KEY_BITS-1:0] key_out,
    output logic [63:0]      seed_out,
    output logic             entropy_ready
);
    wire mux_valid;
    wire [7:0] mux_data;

    entropy_source_mux u_mux (
        .clk(clk),
        .rst(rst),
        .sel(entropy_sel),
        .qrng_valid(qrng_valid),
        .qrng_data(qrng_data),
        .qrng_ready(),
        .photon_valid(photon_valid),
        .photon_data(photon_data),
        .photon_ready(),
        .out_valid(mux_valid),
        .out_data(mux_data),
        .out_ready(1'b1)
    );

    wire cond_key_update;
    wire [KEY_BITS-1:0] cond_key;
    wire [63:0] cond_seed;
    wire cond_ready;

    entropy_conditioner #(.KEY_BITS(KEY_BITS)) u_cond (
        .clk(clk),
        .rst(rst),
        .in_valid(mux_valid && (entropy_sel != 2'b00)),
        .in_data(mux_data),
        .in_ready(),
        .reseed_req(reseed_req),
        .key_update(cond_key_update),
        .key_out(cond_key),
        .seed_out(cond_seed),
        .entropy_ready(cond_ready)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            se_enable <= 1'b0;
            key_update <= 1'b0;
            key_out <= '0;
            seed_out <= 64'd0;
            entropy_ready <= 1'b0;
        end else begin
            key_update <= 1'b0;
            entropy_ready <= cond_ready;

            if (entropy_sel == 2'b00) begin
                se_enable <= manual_enable;
                if (manual_load) begin
                    key_out <= manual_key;
                    seed_out <= manual_seed;
                    key_update <= 1'b1;
                end
            end else begin
                se_enable <= 1'b1;
                if (cond_key_update) begin
                    key_out <= cond_key;
                    seed_out <= cond_seed;
                    key_update <= 1'b1;
                end
            end
        end
    end
endmodule
