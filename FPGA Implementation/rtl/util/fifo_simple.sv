// -----------------------------------------------------------------------------
// fifo_simple.sv
// Small synchronous FIFO (single-clock) for buffering.
//
// Notes:
// - Supports simultaneous read+write (count unchanged).
// -----------------------------------------------------------------------------
module fifo_simple #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 4
)(
    input  wire             clk,
    input  wire             rst,

    input  wire             wr_en,
    input  wire [WIDTH-1:0] wr_data,
    output wire             full,

    input  wire             rd_en,
    output wire [WIDTH-1:0] rd_data,
    output wire             empty
);
    localparam int ADDR_BITS = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

    logic [WIDTH-1:0] mem [0:DEPTH-1];
    logic [ADDR_BITS-1:0] wptr, rptr;
    logic [ADDR_BITS:0]   count;

    assign full  = (count == DEPTH);
    assign empty = (count == 0);
    assign rd_data = mem[rptr];

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            wptr  <= '0;
            rptr  <= '0;
            count <= '0;
            for (i = 0; i < DEPTH; i = i + 1) mem[i] <= '0;
        end else begin
            logic do_wr, do_rd;
            do_wr = wr_en && !full;
            do_rd = rd_en && !empty;

            // write first (safe with separate pointers)
            if (do_wr) begin
                mem[wptr] <= wr_data;
                wptr <= wptr + 1'b1;
            end
            if (do_rd) begin
                rptr <= rptr + 1'b1;
            end

            // update count
            case ({do_wr, do_rd})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end

endmodule
