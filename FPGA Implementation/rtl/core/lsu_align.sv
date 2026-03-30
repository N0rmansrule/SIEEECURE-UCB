// -----------------------------------------------------------------------------
// lsu_align.sv
// Helper for extracting/packing sub-word loads and stores into a 16-byte cache line.
// - For stores: produces line write data and byte strobes.
// - For loads : extracts and sign/zero extends into 64-bit.
// -----------------------------------------------------------------------------
module lsu_align(
    input  wire [63:0]  addr,
    input  wire [2:0]   mem_size,     // rv64_pkg::MEM_*
    input  wire         is_unsigned,  // for loads
    input  wire [63:0]  store_data,   // for stores (low bits used)
    input  wire [127:0] line_rdata,   // 16-byte line read data

    output wire [127:0] store_wdata_line,
    output wire [15:0]  store_wstrb_line,
    output wire [63:0]  load_data
);

    // Byte offset within the 16-byte line
    wire [3:0] off = addr[3:0];

    // -----------------------------
    // Store packing
    // -----------------------------
    reg [127:0] wdata;
    reg [15:0]  wstrb;

    integer i;
    always @(*) begin
        wdata = 128'd0;
        wstrb = 16'd0;

        case (mem_size)
            3'd0: begin // MEM_B
                wdata = {120'd0, store_data[7:0]} << (off * 8);
                wstrb = 16'h0001 << off;
            end
            3'd1: begin // MEM_H
                wdata = {112'd0, store_data[15:0]} << (off * 8);
                wstrb = 16'h0003 << off;
            end
            3'd2: begin // MEM_W
                wdata = {96'd0, store_data[31:0]} << (off * 8);
                wstrb = 16'h000F << off;
            end
            3'd3: begin // MEM_D
                wdata = {64'd0, store_data[63:0]} << (off * 8);
                wstrb = 16'h00FF << off;
            end
            3'd4: begin // MEM_Q (128-bit, full line)
                // For SE ciphertext stores, the caller usually provides 128-bit data
                // directly and sets wstrb=all ones, so this case is rarely used.
                // We still support MEM_Q as "store_data occupies low 64 bits", upper 64 = 0.
                wdata = {64'd0, store_data};
                wstrb = 16'hFFFF;
            end
            default: begin
                wdata = 128'd0;
                wstrb = 16'd0;
            end
        endcase
    end

    assign store_wdata_line  = wdata;
    assign store_wstrb_line  = wstrb;

    // -----------------------------
    // Load extraction
    // -----------------------------
    reg [63:0] ld;
    reg [63:0] raw;

    always @(*) begin
        ld  = 64'd0;
        raw = 64'd0;

        // Slice 64 bits starting at the byte offset; for smaller loads we use low bits.
        raw = (line_rdata >> (off * 8));

        case (mem_size)
            3'd0: begin // MEM_B
                if (is_unsigned) ld = {56'd0, raw[7:0]};
                else             ld = {{56{raw[7]}}, raw[7:0]};
            end
            3'd1: begin // MEM_H
                if (is_unsigned) ld = {48'd0, raw[15:0]};
                else             ld = {{48{raw[15]}}, raw[15:0]};
            end
            3'd2: begin // MEM_W
                if (is_unsigned) ld = {32'd0, raw[31:0]};
                else             ld = {{32{raw[31]}}, raw[31:0]};
            end
            3'd3: begin // MEM_D
                ld = raw[63:0];
            end
            3'd4: begin // MEM_Q
                // For 128-bit loads (SE), the caller uses the full 128-bit line directly.
                // Here we return the low 64 bits.
                ld = raw[63:0];
            end
            default: ld = 64'd0;
        endcase
    end

    assign load_data = ld;

endmodule
