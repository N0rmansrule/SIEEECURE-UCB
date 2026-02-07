// gpu_ci_stub.sv
// -----------------------------------------------------------------------------
// Stub responder for GPU custom instruction interface
// -----------------------------------------------------------------------------
// If a CPU core that is NOT connected to the real GPU executes a CUSTOM-0
// instruction, this block will:
//
//   - accept the command (ready=1)
//   - return rsp_valid with an error code
//
// This prevents the core from deadlocking in the S_GPU state.
module gpu_ci_stub (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ci_valid,
    input  wire [7:0]  ci_op,
    input  wire [63:0] ci_arg0,
    input  wire [63:0] ci_arg1,
    output wire        ci_ready,
    output reg         ci_rsp_valid,
    output reg  [63:0] ci_rsp_data,
    input  wire        ci_rsp_ready
);
    assign ci_ready = 1'b1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ci_rsp_valid <= 1'b0;
            ci_rsp_data  <= 64'h0;
        end else begin
            if (ci_rsp_valid && ci_rsp_ready)
                ci_rsp_valid <= 1'b0;

            if (ci_valid) begin
                ci_rsp_valid <= 1'b1;
                ci_rsp_data  <= 64'hDEAD_DEAD_DEAD_0001; // "GPU CI not connected"
            end
        end
    end
endmodule
