// -----------------------------------------------------------------------------
// csr_file.sv
// Minimal Machine-mode CSR file + SIEEECURE custom CSRs.
// Implements Zicsr, basic trap entry, and mret.
//
// This core is "M-mode only" (no S/U mode). Unsupported privilege instructions
// should be trapped as illegal by decode/control.
// -----------------------------------------------------------------------------
module csr_file(
    input  wire        clk,
    input  wire        rst,

    // CSR instruction interface
    input  wire        csr_valid,
    input  wire [1:0]  csr_cmd,       // rv64_pkg::CSR_*
    input  wire [11:0] csr_addr,
    input  wire [63:0] csr_wdata,
    output wire [63:0] csr_rdata,

    // Trap / return interface
    input  wire        trap_enter,
    input  wire [63:0] trap_cause,
    input  wire [63:0] trap_tval,
    input  wire [63:0] trap_pc,
    input  wire        mret,

    output wire [63:0] mtvec_out,
    output wire [63:0] mepc_out,

    // Counters
    input  wire        retire,

    // SIEEECURE CSRs to SE unit
    output wire        se_enable,
    output wire [1:0]  se_key_len_sel, // 0=128,1=192,2=256
    output wire [255:0] se_key,
    output wire [63:0] se_seed
);
    import rv64_pkg::*;

    // -------------------------------------------------------------------------
    // CSR registers
    // -------------------------------------------------------------------------
    logic [63:0] mstatus;
    logic [63:0] mie;
    logic [63:0] mip;
    logic [63:0] mtvec;
    logic [63:0] mscratch;
    logic [63:0] mepc;
    logic [63:0] mcause;
    logic [63:0] mtval;

    logic [63:0] cycle;
    logic [63:0] instret;

    // Custom SIEEECURE CSRs
    logic [63:0] se_ctrl;
    logic [63:0] se_key0, se_key1, se_key2, se_key3;
    logic [63:0] se_seed_r;

    // misa: XLEN=64, extensions: I,M (and optionally C if you add compressed later)
    wire [63:0] misa_const = 64'h8000_0000_0000_0000 | // MXL=2 for 64-bit
                             (64'd1 << 8)  |           // I
                             (64'd1 << 12);            // M

    // CSR read mux (combinational)
    reg [63:0] rdata;
    always @(*) begin
        rdata = 64'd0;
        unique case (csr_addr)
            12'h300: rdata = mstatus;
            12'h301: rdata = misa_const;
            12'h304: rdata = mie;
            12'h305: rdata = mtvec;
            12'h340: rdata = mscratch;
            12'h341: rdata = mepc;
            12'h342: rdata = mcause;
            12'h343: rdata = mtval;
            12'h344: rdata = mip;

            12'hC00: rdata = cycle;
            12'hC02: rdata = instret;

            // Custom range
            12'h7C0: rdata = se_ctrl;
            12'h7C1: rdata = se_key0;
            12'h7C2: rdata = se_key1;
            12'h7C3: rdata = se_key2;
            12'h7C4: rdata = se_key3;
            12'h7C5: rdata = se_seed_r;

            default: rdata = 64'd0;
        endcase
    end
    assign csr_rdata = rdata;

    // -------------------------------------------------------------------------
    // CSR write helper
    // -------------------------------------------------------------------------
    function automatic [63:0] csr_apply(
        input [1:0]  cmd,
        input [63:0] oldv,
        input [63:0] wv
    );
        case (cmd)
            CSR_WRITE: csr_apply = wv;
            CSR_SET:   csr_apply = oldv | wv;
            CSR_CLEAR: csr_apply = oldv & ~wv;
            default:   csr_apply = oldv;
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // Sequential updates
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            mstatus  <= 64'd0;
            mie      <= 64'd0;
            mip      <= 64'd0;
            mtvec    <= 64'd0;
            mscratch <= 64'd0;
            mepc     <= 64'd0;
            mcause   <= 64'd0;
            mtval    <= 64'd0;
            cycle    <= 64'd0;
            instret  <= 64'd0;

            se_ctrl  <= 64'd0;
            se_key0  <= 64'd0;
            se_key1  <= 64'd0;
            se_key2  <= 64'd0;
            se_key3  <= 64'd0;
            se_seed_r<= 64'd0;
        end else begin
            // Cycle counter always increments
            cycle <= cycle + 64'd1;
            if (retire) instret <= instret + 64'd1;

            // Trap entry (highest priority)
            if (trap_enter) begin
                mepc   <= trap_pc;
                mcause <= trap_cause;
                mtval  <= trap_tval;
                // mstatus: MPIE <= MIE, MIE <= 0, MPP <= 3 (M-mode)
                mstatus[7]   <= mstatus[3];   // MPIE
                mstatus[3]   <= 1'b0;         // MIE
                mstatus[12:11] <= 2'b11;      // MPP
            end
            // Return from trap
            else if (mret) begin
                // mstatus: MIE <= MPIE, MPIE <= 1
                mstatus[3] <= mstatus[7];
                mstatus[7] <= 1'b1;
                mstatus[12:11] <= 2'b11;
            end
            // CSR instruction write
            else if (csr_valid && (csr_cmd != CSR_NONE)) begin
                unique case (csr_addr)
                    12'h300: mstatus  <= csr_apply(csr_cmd, mstatus, csr_wdata);
                    12'h304: mie      <= csr_apply(csr_cmd, mie, csr_wdata);
                    12'h305: mtvec    <= csr_apply(csr_cmd, mtvec, csr_wdata);
                    12'h340: mscratch <= csr_apply(csr_cmd, mscratch, csr_wdata);
                    12'h341: mepc     <= csr_apply(csr_cmd, mepc, csr_wdata);
                    12'h342: mcause   <= csr_apply(csr_cmd, mcause, csr_wdata);
                    12'h343: mtval    <= csr_apply(csr_cmd, mtval, csr_wdata);
                    12'h344: mip      <= csr_apply(csr_cmd, mip, csr_wdata);

                    // Custom: SE control and key material
                    12'h7C0: se_ctrl  <= csr_apply(csr_cmd, se_ctrl, csr_wdata);
                    12'h7C1: se_key0  <= csr_apply(csr_cmd, se_key0, csr_wdata);
                    12'h7C2: se_key1  <= csr_apply(csr_cmd, se_key1, csr_wdata);
                    12'h7C3: se_key2  <= csr_apply(csr_cmd, se_key2, csr_wdata);
                    12'h7C4: se_key3  <= csr_apply(csr_cmd, se_key3, csr_wdata);
                    12'h7C5: se_seed_r<= csr_apply(csr_cmd, se_seed_r, csr_wdata);

                    default: begin end
                endcase
            end
        end
    end

    assign mtvec_out = mtvec;
    assign mepc_out  = mepc;

    // Custom outputs
    assign se_enable      = se_ctrl[0];
    assign se_key_len_sel = se_ctrl[2:1];
    assign se_key         = {se_key3, se_key2, se_key1, se_key0};
    assign se_seed        = se_seed_r;

endmodule
