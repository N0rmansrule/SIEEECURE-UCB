// -----------------------------------------------------------------------------
// entropy_source_mux.sv
// Selects between manual/QRNG/photonic entropy streams for SE key generation.
//
// sel encoding:
//   2'b00 : manual key path (no entropy output, handled externally)
//   2'b01 : QRNG stream only
//   2'b10 : photon/optical entropy stream only
//   2'b11 : mixed stream = qrng_data XOR photon_data when both valid,
//           otherwise forwards whichever source is valid.
// -----------------------------------------------------------------------------
module entropy_source_mux (
    input  wire        clk,
    input  wire        rst,
    input  wire [1:0]  sel,

    input  wire        qrng_valid,
    input  wire [7:0]  qrng_data,
    output wire        qrng_ready,

    input  wire        photon_valid,
    input  wire [7:0]  photon_data,
    output wire        photon_ready,

    output logic       out_valid,
    output logic [7:0] out_data,
    input  wire        out_ready
);
    assign qrng_ready   = out_ready && (sel == 2'b01 || sel == 2'b11);
    assign photon_ready = out_ready && (sel == 2'b10 || sel == 2'b11);

    always_comb begin
        out_valid = 1'b0;
        out_data  = 8'd0;

        unique case (sel)
            2'b01: begin
                out_valid = qrng_valid;
                out_data  = qrng_data;
            end
            2'b10: begin
                out_valid = photon_valid;
                out_data  = photon_data;
            end
            2'b11: begin
                if (qrng_valid && photon_valid) begin
                    out_valid = 1'b1;
                    out_data  = qrng_data ^ photon_data;
                end else if (qrng_valid) begin
                    out_valid = 1'b1;
                    out_data  = qrng_data;
                end else if (photon_valid) begin
                    out_valid = 1'b1;
                    out_data  = photon_data;
                end
            end
            default: begin
                out_valid = 1'b0;
                out_data  = 8'd0;
            end
        endcase
    end
endmodule
