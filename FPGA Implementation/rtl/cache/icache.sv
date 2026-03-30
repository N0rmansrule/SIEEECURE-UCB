// -----------------------------------------------------------------------------
// icache.sv
// Simple direct-mapped, blocking I-cache (16-byte lines).
// - One outstanding miss
// - One-cycle hit response (registered)
//
// CPU requests *cache lines* (16 bytes). The core fetch unit selects the word
// from the returned line.
// -----------------------------------------------------------------------------
module icache #(
    parameter int LINES    = 256,
    parameter int TAG_BITS = 24
)(
    input  wire         clk,
    input  wire         rst,

    // CPU side (line request)
    input  wire         req_valid,
    output wire         req_ready,
    input  wire [63:0]  req_addr,     // 16-byte aligned recommended

    output wire         resp_valid,
    input  wire         resp_ready,
    output wire [127:0] resp_rdata,
    output wire         resp_err,

    // Invalidate pulse (FENCE.I)
    input  wire         invalidate,

    // Memory side
    simple_mem_if.master mem
);
    localparam int IDX_BITS = (LINES <= 1) ? 1 : $clog2(LINES);

    // Arrays
    logic [127:0]        data_mem [0:LINES-1];
    logic [TAG_BITS-1:0] tag_mem  [0:LINES-1];
    logic                valid_mem[0:LINES-1];

    // Request latch
    logic        pend_valid;
    logic [63:0] pend_addr;
    logic [IDX_BITS-1:0] pend_idx;
    logic [TAG_BITS-1:0] pend_tag;

    // FSM
    typedef enum logic [1:0] {S_IDLE, S_HITRESP, S_MISS_REQ, S_MISS_WAIT} state_t;
    state_t state;

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
    assign mem.req_valid  = (state == S_MISS_REQ);
    assign mem.req_addr   = pend_addr;
    assign mem.req_write  = 1'b0;
    assign mem.req_wdata  = 128'd0;
    assign mem.req_wstrb  = 16'd0;
    assign mem.resp_ready = (state == S_MISS_WAIT);

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            pend_valid <= 1'b0;
            pend_addr <= 64'd0;
            pend_idx <= '0;
            pend_tag <= '0;
            resp_v <= 1'b0;
            resp_d <= 128'd0;
            resp_e <= 1'b0;
            for (i = 0; i < LINES; i = i + 1) begin
                valid_mem[i] <= 1'b0;
                tag_mem[i]   <= '0;
                data_mem[i]  <= 128'd0;
            end
        end else begin
            // Drop response when accepted
            if (resp_v && resp_ready) begin
                resp_v <= 1'b0;
            end

            // Invalidate
            if (invalidate) begin
                for (i = 0; i < LINES; i = i + 1) begin
                    valid_mem[i] <= 1'b0;
                end
            end

            case (state)
                S_IDLE: begin
                    if (req_valid && req_ready) begin
                        pend_valid <= 1'b1;
                        pend_addr  <= req_addr & 64'hFFFF_FFFF_FFFF_FFF0;
                        pend_idx   <= idx;
                        pend_tag   <= tag;

                        if (hit) begin
                            resp_d <= data_mem[idx];
                            resp_e <= 1'b0;
                            resp_v <= 1'b1;
                            state <= S_HITRESP;
                        end else begin
                            state <= S_MISS_REQ;
                        end
                    end
                end

                S_HITRESP: begin
                    if (!resp_v || (resp_v && resp_ready)) begin
                        state <= S_IDLE;
                        pend_valid <= 1'b0;
                    end
                end

                S_MISS_REQ: begin
                    // Wait for memory accept
                    if (mem.req_valid && mem.req_ready) begin
                        state <= S_MISS_WAIT;
                    end
                end

                S_MISS_WAIT: begin
                    if (mem.resp_valid && mem.resp_ready) begin
                        resp_d <= mem.resp_rdata;
                        resp_e <= mem.resp_err;
                        resp_v <= 1'b1;

                        if (!mem.resp_err) begin
                            data_mem[pend_idx] <= mem.resp_rdata;
                            tag_mem[pend_idx]  <= pend_tag;
                            valid_mem[pend_idx] <= 1'b1;
                        end

                        state <= S_HITRESP;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
