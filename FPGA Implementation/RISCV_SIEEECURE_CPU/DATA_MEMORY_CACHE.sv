// -----------------------------------------------------------------------------
// dcache.sv
// Simple direct-mapped, blocking D-cache (16-byte lines).
// Write-back + write-allocate.
// - One outstanding miss
// - Byte write strobes (for sub-word stores) supported
// -----------------------------------------------------------------------------
module dcache #(
    parameter int LINES    = 256,
    parameter int TAG_BITS = 24
)(
    input  wire         clk,
    input  wire         rst,

    // CPU side (line request)
    input  wire         req_valid,
    output wire         req_ready,
    input  wire [63:0]  req_addr,     // line-aligned
    input  wire         req_write,
    input  wire [127:0] req_wdata,
    input  wire [15:0]  req_wstrb,

    output wire         resp_valid,
    input  wire         resp_ready,
    output wire [127:0] resp_rdata,
    output wire         resp_err,

    // Optional maintenance
    input  wire         invalidate_all,

    // Memory side
    simple_mem_if.master mem
);
    localparam int IDX_BITS = (LINES <= 1) ? 1 : $clog2(LINES);

    // Arrays
    logic [127:0]        data_mem [0:LINES-1];
    logic [TAG_BITS-1:0] tag_mem  [0:LINES-1];
    logic                valid_mem[0:LINES-1];
    logic                dirty_mem[0:LINES-1];

    // Latched request
    logic        pend_valid;
    logic [63:0] pend_addr;
    logic        pend_write;
    logic [127:0] pend_wdata;
    logic [15:0]  pend_wstrb;
    logic [IDX_BITS-1:0] pend_idx;
    logic [TAG_BITS-1:0] pend_tag;

    // Evict info
    logic [63:0] evict_addr;
    logic [127:0] evict_data;

    // FSM
    typedef enum logic [2:0] {
        S_IDLE,
        S_HITRESP,
        S_WB_REQ,
        S_WB_WAIT,
        S_RD_REQ,
        S_RD_WAIT
    } state_t;
    state_t state;

    // Helpers
    function automatic [127:0] apply_wstrb(input [127:0] oldl, input [127:0] newl, input [15:0] strb);
        integer k;
        begin
            apply_wstrb = oldl;
            for (k = 0; k < 16; k = k + 1) begin
                if (strb[k]) apply_wstrb[k*8 +: 8] = newl[k*8 +: 8];
            end
        end
    endfunction

    // Hit check on incoming request
    wire [IDX_BITS-1:0] idx = req_addr[4 +: IDX_BITS];
    wire [TAG_BITS-1:0] tag = req_addr[4+IDX_BITS +: TAG_BITS];
    wire hit = valid_mem[idx] && (tag_mem[idx] == tag);

    // CPU handshake
    assign req_ready = (state == S_IDLE);

    // Response regs
    logic resp_v;
    logic [127:0] resp_d;
    logic resp_e;

    assign resp_valid = resp_v;
    assign resp_rdata = resp_d;
    assign resp_err   = resp_e;

    // Memory interface driven combinationally from state
    assign mem.req_valid  = (state == S_WB_REQ) || (state == S_RD_REQ);
    assign mem.req_addr   = (state == S_WB_REQ) ? evict_addr : pend_addr;
    assign mem.req_write  = (state == S_WB_REQ) ? 1'b1      : 1'b0;
    assign mem.req_wdata  = (state == S_WB_REQ) ? evict_data : 128'd0;
    assign mem.req_wstrb  = (state == S_WB_REQ) ? 16'hFFFF   : 16'd0;
    assign mem.resp_ready = (state == S_WB_WAIT) || (state == S_RD_WAIT);

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            pend_valid <= 1'b0;
            pend_addr  <= 64'd0;
            pend_write <= 1'b0;
            pend_wdata <= 128'd0;
            pend_wstrb <= 16'd0;
            pend_idx   <= '0;
            pend_tag   <= '0;
            evict_addr <= 64'd0;
            evict_data <= 128'd0;

            resp_v <= 1'b0;
            resp_d <= 128'd0;
            resp_e <= 1'b0;

            for (i = 0; i < LINES; i = i + 1) begin
                valid_mem[i] <= 1'b0;
                dirty_mem[i] <= 1'b0;
                tag_mem[i]   <= '0;
                data_mem[i]  <= 128'd0;
            end
        end else begin
            if (resp_v && resp_ready) resp_v <= 1'b0;

            // Optional invalidate
            if (invalidate_all) begin
                for (i = 0; i < LINES; i = i + 1) begin
                    valid_mem[i] <= 1'b0;
                    dirty_mem[i] <= 1'b0;
                end
            end

            case (state)
                S_IDLE: begin
                    if (req_valid && req_ready) begin
                        pend_valid <= 1'b1;
                        pend_addr  <= req_addr & 64'hFFFF_FFFF_FFFF_FFF0;
                        pend_write <= req_write;
                        pend_wdata <= req_wdata;
                        pend_wstrb <= req_wstrb;
                        pend_idx   <= idx;
                        pend_tag   <= tag;

                        if (hit) begin
                            // Hit: update on write, return line
                            if (req_write) begin
                                data_mem[idx] <= apply_wstrb(data_mem[idx], req_wdata, req_wstrb);
                                dirty_mem[idx] <= 1'b1;
                            end
                            resp_d <= req_write ? apply_wstrb(data_mem[idx], req_wdata, req_wstrb) : data_mem[idx];
                            resp_e <= 1'b0;
                            resp_v <= 1'b1;
                            state <= S_HITRESP;
                        end else begin
                            // Miss: decide if writeback needed
                            if (valid_mem[idx] && dirty_mem[idx]) begin
                                // Evict current line
                                evict_addr <= { {(64-TAG_BITS-IDX_BITS-4){1'b0}}, tag_mem[idx], idx, 4'b0000 };
                                evict_data <= data_mem[idx];
                                state <= S_WB_REQ;
                            end else begin
                                state <= S_RD_REQ;
                            end
                        end
                    end
                end

                S_HITRESP: begin
                    if (!resp_v || (resp_v && resp_ready)) begin
                        state <= S_IDLE;
                        pend_valid <= 1'b0;
                    end
                end

                S_WB_REQ: begin
                    if (mem.req_valid && mem.req_ready) begin
                        state <= S_WB_WAIT;
                    end
                end

                S_WB_WAIT: begin
                    if (mem.resp_valid && mem.resp_ready) begin
                        // ignore resp_rdata; check error
                        resp_e <= mem.resp_err;
                        // Clear dirty on evicted index
                        dirty_mem[pend_idx] <= 1'b0;
                        state <= S_RD_REQ;
                    end
                end

                S_RD_REQ: begin
                    if (mem.req_valid && mem.req_ready) begin
                        state <= S_RD_WAIT;
                    end
                end

                S_RD_WAIT: begin
                    if (mem.resp_valid && mem.resp_ready) begin
                        resp_e <= mem.resp_err;
                        resp_d <= mem.resp_rdata;
                        resp_v <= 1'b1;

                        if (!mem.resp_err) begin
                            // Fill line
                            data_mem[pend_idx] <= mem.resp_rdata;
                            tag_mem[pend_idx]  <= pend_tag;
                            valid_mem[pend_idx] <= 1'b1;
                            dirty_mem[pend_idx] <= 1'b0;

                            // Apply store on fill (write-allocate)
                            if (pend_write) begin
                                data_mem[pend_idx] <= apply_wstrb(mem.resp_rdata, pend_wdata, pend_wstrb);
                                dirty_mem[pend_idx] <= 1'b1;
                                resp_d <= apply_wstrb(mem.resp_rdata, pend_wdata, pend_wstrb);
                            end
                        end

                        state <= S_HITRESP;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
