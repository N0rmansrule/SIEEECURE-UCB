// -----------------------------------------------------------------------------
// cache_arbiter.sv
// Simple 2-master arbiter for I$ and D$ memory ports onto a single external port.
// Priority: D$ > I$
// -----------------------------------------------------------------------------
module cache_arbiter(
    input  wire        clk,
    input  wire        rst,

    // From caches (as slaves from arbiter perspective)
    simple_mem_if.slave ic_port,
    simple_mem_if.slave dc_port,

    // To external memory
    simple_mem_if.master mem_port
);

    typedef enum logic [1:0] {IDLE, SERVE_IC, SERVE_DC} state_t;
    state_t state;

    // Default assignments
    always_comb begin
        // Default: deassert everything
        ic_port.req_ready  = 1'b0;
        ic_port.resp_valid = 1'b0;
        ic_port.resp_rdata = 128'd0;
        ic_port.resp_err   = 1'b0;

        dc_port.req_ready  = 1'b0;
        dc_port.resp_valid = 1'b0;
        dc_port.resp_rdata = 128'd0;
        dc_port.resp_err   = 1'b0;

        mem_port.req_valid = 1'b0;
        mem_port.req_addr  = 64'd0;
        mem_port.req_write = 1'b0;
        mem_port.req_wdata = 128'd0;
        mem_port.req_wstrb = 16'd0;
        mem_port.resp_ready= 1'b0;

        case (state)
            IDLE: begin
                // Choose grant combinationally based on requests.
                if (dc_port.req_valid) begin
                    mem_port.req_valid = dc_port.req_valid;
                    mem_port.req_addr  = dc_port.req_addr;
                    mem_port.req_write = dc_port.req_write;
                    mem_port.req_wdata = dc_port.req_wdata;
                    mem_port.req_wstrb = dc_port.req_wstrb;
                    dc_port.req_ready  = mem_port.req_ready;
                    mem_port.resp_ready= dc_port.resp_ready;

                    // Route response
                    dc_port.resp_valid = mem_port.resp_valid;
                    dc_port.resp_rdata = mem_port.resp_rdata;
                    dc_port.resp_err   = mem_port.resp_err;
                end else if (ic_port.req_valid) begin
                    mem_port.req_valid = ic_port.req_valid;
                    mem_port.req_addr  = ic_port.req_addr;
                    mem_port.req_write = ic_port.req_write;
                    mem_port.req_wdata = ic_port.req_wdata;
                    mem_port.req_wstrb = ic_port.req_wstrb;
                    ic_port.req_ready  = mem_port.req_ready;
                    mem_port.resp_ready= ic_port.resp_ready;

                    ic_port.resp_valid = mem_port.resp_valid;
                    ic_port.resp_rdata = mem_port.resp_rdata;
                    ic_port.resp_err   = mem_port.resp_err;
                end
            end

            SERVE_DC: begin
                mem_port.req_valid = dc_port.req_valid;
                mem_port.req_addr  = dc_port.req_addr;
                mem_port.req_write = dc_port.req_write;
                mem_port.req_wdata = dc_port.req_wdata;
                mem_port.req_wstrb = dc_port.req_wstrb;
                dc_port.req_ready  = mem_port.req_ready;

                mem_port.resp_ready= dc_port.resp_ready;
                dc_port.resp_valid = mem_port.resp_valid;
                dc_port.resp_rdata = mem_port.resp_rdata;
                dc_port.resp_err   = mem_port.resp_err;
            end

            SERVE_IC: begin
                mem_port.req_valid = ic_port.req_valid;
                mem_port.req_addr  = ic_port.req_addr;
                mem_port.req_write = ic_port.req_write;
                mem_port.req_wdata = ic_port.req_wdata;
                mem_port.req_wstrb = ic_port.req_wstrb;
                ic_port.req_ready  = mem_port.req_ready;

                mem_port.resp_ready= ic_port.resp_ready;
                ic_port.resp_valid = mem_port.resp_valid;
                ic_port.resp_rdata = mem_port.resp_rdata;
                ic_port.resp_err   = mem_port.resp_err;
            end

            default: begin end
        endcase
    end

    // State transitions based on accepted request and completed response
    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
        end else begin
            case (state)
                IDLE: begin
                    if (dc_port.req_valid) state <= SERVE_DC;
                    else if (ic_port.req_valid) state <= SERVE_IC;
                end
                SERVE_DC: begin
                    // Return to IDLE when response handshake completes
                    if (mem_port.resp_valid && mem_port.resp_ready) state <= IDLE;
                end
                SERVE_IC: begin
                    if (mem_port.resp_valid && mem_port.resp_ready) state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end

endmodule
