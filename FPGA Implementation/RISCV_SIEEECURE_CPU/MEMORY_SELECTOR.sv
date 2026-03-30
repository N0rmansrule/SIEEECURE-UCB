// -----------------------------------------------------------------------------
// mem_arbiter4_rr.sv
//
// 4-port round-robin arbiter for the simple_mem_if interface.
// - Accepts one request at a time.
// - Locks to the granted master until the response is returned.
//
// This is suitable for merging multiple core cache arbiters onto a single
// shared memory port (BRAM/DDR controller).
// -----------------------------------------------------------------------------
module mem_arbiter4_rr(
    input  wire clk,
    input  wire rst,

    // Masters (as "slaves" of the arbiter)
    simple_mem_if.slave m0,
    simple_mem_if.slave m1,
    simple_mem_if.slave m2,
    simple_mem_if.slave m3,

    // Downstream memory port
    simple_mem_if.master mem
);

    logic        active;
    logic [1:0]  grant_idx;
    logic [1:0]  rr_ptr;

    // Candidate selected in IDLE
    logic [1:0] sel_idx;
    logic       sel_valid;

    // Helper: request-valids
    wire v0 = m0.req_valid;
    wire v1 = m1.req_valid;
    wire v2 = m2.req_valid;
    wire v3 = m3.req_valid;

    // Round-robin selection in IDLE
    always_comb begin
        sel_valid = 1'b0;
        sel_idx   = rr_ptr;

        unique case (rr_ptr)
            2'd0: begin
                if (v0) begin sel_valid=1'b1; sel_idx=2'd0; end
                else if (v1) begin sel_valid=1'b1; sel_idx=2'd1; end
                else if (v2) begin sel_valid=1'b1; sel_idx=2'd2; end
                else if (v3) begin sel_valid=1'b1; sel_idx=2'd3; end
            end
            2'd1: begin
                if (v1) begin sel_valid=1'b1; sel_idx=2'd1; end
                else if (v2) begin sel_valid=1'b1; sel_idx=2'd2; end
                else if (v3) begin sel_valid=1'b1; sel_idx=2'd3; end
                else if (v0) begin sel_valid=1'b1; sel_idx=2'd0; end
            end
            2'd2: begin
                if (v2) begin sel_valid=1'b1; sel_idx=2'd2; end
                else if (v3) begin sel_valid=1'b1; sel_idx=2'd3; end
                else if (v0) begin sel_valid=1'b1; sel_idx=2'd0; end
                else if (v1) begin sel_valid=1'b1; sel_idx=2'd1; end
            end
            default: begin // 2'd3
                if (v3) begin sel_valid=1'b1; sel_idx=2'd3; end
                else if (v0) begin sel_valid=1'b1; sel_idx=2'd0; end
                else if (v1) begin sel_valid=1'b1; sel_idx=2'd1; end
                else if (v2) begin sel_valid=1'b1; sel_idx=2'd2; end
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // Request mux (only when !active)
    // -------------------------------------------------------------------------
    always_comb begin
        // Default: no request to downstream
        mem.req_valid = 1'b0;
        mem.req_addr  = 64'd0;
        mem.req_write = 1'b0;
        mem.req_wdata = 128'd0;
        mem.req_wstrb = 16'd0;

        // Default: no master gets ready
        m0.req_ready = 1'b0;
        m1.req_ready = 1'b0;
        m2.req_ready = 1'b0;
        m3.req_ready = 1'b0;

        if (!active && sel_valid) begin
            unique case (sel_idx)
                2'd0: begin
                    mem.req_valid = m0.req_valid;
                    mem.req_addr  = m0.req_addr;
                    mem.req_write = m0.req_write;
                    mem.req_wdata = m0.req_wdata;
                    mem.req_wstrb = m0.req_wstrb;
                    m0.req_ready  = mem.req_ready;
                end
                2'd1: begin
                    mem.req_valid = m1.req_valid;
                    mem.req_addr  = m1.req_addr;
                    mem.req_write = m1.req_write;
                    mem.req_wdata = m1.req_wdata;
                    mem.req_wstrb = m1.req_wstrb;
                    m1.req_ready  = mem.req_ready;
                end
                2'd2: begin
                    mem.req_valid = m2.req_valid;
                    mem.req_addr  = m2.req_addr;
                    mem.req_write = m2.req_write;
                    mem.req_wdata = m2.req_wdata;
                    mem.req_wstrb = m2.req_wstrb;
                    m2.req_ready  = mem.req_ready;
                end
                default: begin
                    mem.req_valid = m3.req_valid;
                    mem.req_addr  = m3.req_addr;
                    mem.req_write = m3.req_write;
                    mem.req_wdata = m3.req_wdata;
                    mem.req_wstrb = m3.req_wstrb;
                    m3.req_ready  = mem.req_ready;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Response routing (when active, based on grant_idx)
    // -------------------------------------------------------------------------
    always_comb begin
        // Default: no responses to any master
        m0.resp_valid = 1'b0;
        m0.resp_rdata = 128'd0;
        m0.resp_err   = 1'b0;

        m1.resp_valid = 1'b0;
        m1.resp_rdata = 128'd0;
        m1.resp_err   = 1'b0;

        m2.resp_valid = 1'b0;
        m2.resp_rdata = 128'd0;
        m2.resp_err   = 1'b0;

        m3.resp_valid = 1'b0;
        m3.resp_rdata = 128'd0;
        m3.resp_err   = 1'b0;

        // Downstream ready only from the active master
        mem.resp_ready = 1'b0;

        if (active) begin
            unique case (grant_idx)
                2'd0: begin
                    m0.resp_valid = mem.resp_valid;
                    m0.resp_rdata = mem.resp_rdata;
                    m0.resp_err   = mem.resp_err;
                    mem.resp_ready = m0.resp_ready;
                end
                2'd1: begin
                    m1.resp_valid = mem.resp_valid;
                    m1.resp_rdata = mem.resp_rdata;
                    m1.resp_err   = mem.resp_err;
                    mem.resp_ready = m1.resp_ready;
                end
                2'd2: begin
                    m2.resp_valid = mem.resp_valid;
                    m2.resp_rdata = mem.resp_rdata;
                    m2.resp_err   = mem.resp_err;
                    mem.resp_ready = m2.resp_ready;
                end
                default: begin
                    m3.resp_valid = mem.resp_valid;
                    m3.resp_rdata = mem.resp_rdata;
                    m3.resp_err   = mem.resp_err;
                    mem.resp_ready = m3.resp_ready;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Control FSM
    // -------------------------------------------------------------------------
    wire req_fire = mem.req_valid && mem.req_ready;
    wire resp_fire = mem.resp_valid && mem.resp_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            active    <= 1'b0;
            grant_idx <= 2'd0;
            rr_ptr    <= 2'd0;
        end else begin
            if (!active) begin
                if (req_fire) begin
                    active    <= 1'b1;
                    grant_idx <= sel_idx;
                end
            end else begin
                if (resp_fire) begin
                    active <= 1'b0;
                    rr_ptr <= grant_idx + 2'd1;
                end
            end
        end
    end

endmodule
