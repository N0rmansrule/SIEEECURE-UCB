// rv64_core.sv
// Minimal RV64I(MUL) single-hart core for bring-up.
// - Machine mode only, no MMU.
// - Multi-cycle FSM (FETCH/DECODE/EXEC/MEM/WB).
// - Intended as an easily-debuggable reference core, not a high-performance design.
//
// NOTE: To run a full-featured software stack you will want a mature RV64 core.
// This module is deliberately small and readable so the surrounding SoC/security
// infrastructure can be validated quickly.
module rv64_core #(
    parameter [63:0] RESET_PC = 64'h0000_0000_0000_0000,
    parameter integer HART_ID = 0
)(
    input  wire        clk,
    input  wire        rst_n,

    // Instruction cache interface (read-only)
    output reg         if_valid,
    output reg  [63:0] if_addr,
    input  wire        if_ready,
    input  wire        if_rvalid,
    input  wire [31:0] if_rdata,
    input  wire        if_err,

    // Data cache interface
    output reg         mem_valid,
    output reg         mem_we,
    output reg  [63:0] mem_addr,
    output reg  [63:0] mem_wdata,
    output reg  [7:0]  mem_wstrb,
    input  wire        mem_ready,
    input  wire        mem_rvalid,
    input  wire [63:0] mem_rdata,
    input  wire        mem_err,

    // ---------------------------------------------------------------------
    // Optional GPU custom-instruction port
    // ---------------------------------------------------------------------
    // This is used when the core executes a RISC-V "custom-0" instruction.
    // See docs/GPU_CUSTOM_ISA.md for a suggested encoding.
    //
    // If you don't want custom instructions, you can ignore this port and
    // access the GPU via MMIO only.
    output reg         gpu_ci_valid,
    output reg  [7:0]  gpu_ci_op,
    output reg  [63:0] gpu_ci_arg0,
    output reg  [63:0] gpu_ci_arg1,
    input  wire        gpu_ci_ready,

    input  wire        gpu_ci_rsp_valid,
    input  wire [63:0] gpu_ci_rsp_data,
    output reg         gpu_ci_rsp_ready,

    // Interrupts (optional)
    input  wire        irq_ext,

    // Debug / status
    output reg  [63:0] dbg_pc
);
    // FSM states
    localparam S_FETCH  = 3'd0;
    localparam S_DECODE = 3'd1;
    localparam S_EXEC   = 3'd2;
    localparam S_MEM    = 3'd3;
    localparam S_WB     = 3'd4;
    localparam S_GPU    = 3'd5; // wait for GPU custom instruction

    reg [2:0] state;

    // Architectural state
    reg [63:0] pc;
    reg [31:0] ir;

    // Decode fields
    wire [6:0] opcode = ir[6:0];
    wire [4:0] rd     = ir[11:7];
    wire [2:0] funct3 = ir[14:12];
    wire [4:0] rs1    = ir[19:15];
    wire [4:0] rs2    = ir[24:20];
    wire [6:0] funct7 = ir[31:25];

    // immediates
    wire [63:0] imm_i = {{52{ir[31]}}, ir[31:20]};
    wire [63:0] imm_s = {{52{ir[31]}}, ir[31:25], ir[11:7]};
    wire [63:0] imm_b = {{51{ir[31]}}, ir[7], ir[30:25], ir[11:8], 1'b0};
    wire [63:0] imm_u = {{32{ir[31]}}, ir[31:12], 12'h000};
    wire [63:0] imm_j = {{43{ir[31]}}, ir[19:12], ir[20], ir[30:21], 1'b0};

    // Regfile
    wire [63:0] rdata1, rdata2;
    wire        rf_we;
    wire [4:0]  rf_waddr;
    wire [63:0] rf_wdata;

    reg  wb_en;
    reg  [4:0]  wb_rd;
    reg  [63:0] wb_value;

    regfile u_rf (
        .clk(clk), .rst_n(rst_n),
        .raddr1(rs1), .raddr2(rs2),
        .rdata1(rdata1), .rdata2(rdata2),
        .we(rf_we), .waddr(rf_waddr), .wdata(rf_wdata)
    );

    // ALU / Branch comparator
    reg  [4:0]  alu_op;
    reg  [63:0] alu_a, alu_b;
    wire [63:0] alu_y;

    alu u_alu (.a(alu_a), .b(alu_b), .op(alu_op), .y(alu_y));

    wire br_take;
    branch_cmp u_br (.a(rdata1), .b(rdata2), .funct3(funct3), .take(br_take));

    // BHT (optional; kept as a module boundary)
    wire bht_pred_taken;
    reg  bht_upd_valid;
    reg  [63:0] bht_upd_pc;
    reg  bht_upd_taken;

    bht #(.ENTRIES(256)) u_bht (
        .clk(clk), .rst_n(rst_n),
        .pc_fetch(pc),
        .pred_taken(bht_pred_taken),
        .upd_valid(bht_upd_valid),
        .upd_pc(bht_upd_pc),
        .upd_taken(bht_upd_taken)
    );

    // MEM latches
    reg [63:0] mem_eff_addr;
    reg [2:0]  mem_funct3;
    reg [6:0]  mem_opcode;
    reg [63:0] mem_store_data;

    // --- GPU custom instruction latches (to avoid re-sending on stall) ---
    reg        gpu_pending;
    reg [7:0]  gpu_op_q;
    reg [63:0] gpu_a0_q;
    reg [63:0] gpu_a1_q;


    // Helpers
    function [7:0] gen_wstrb(input [2:0] sz, input [2:0] addr_lsb);
        begin
            case (sz)
                3'b000: gen_wstrb = (8'b0000_0001 << addr_lsb);      // SB
                3'b001: gen_wstrb = (8'b0000_0011 << addr_lsb);      // SH
                3'b010: gen_wstrb = (8'b0000_1111 << addr_lsb);      // SW
                default: gen_wstrb = 8'b1111_1111;                   // SD
            endcase
        end
    endfunction

    function [63:0] load_extend(input [2:0] sz, input [63:0] data, input [2:0] addr_lsb);
        reg [63:0] shifted;
        begin
            shifted = data >> (addr_lsb * 8);
            case (sz)
                3'b000: load_extend = {{56{shifted[7]}},  shifted[7:0]};   // LB
                3'b001: load_extend = {{48{shifted[15]}}, shifted[15:0]};  // LH
                3'b010: load_extend = {{32{shifted[31]}}, shifted[31:0]};  // LW
                3'b011: load_extend = shifted;                              // LD
                3'b100: load_extend = {56'h0, shifted[7:0]};               // LBU
                3'b101: load_extend = {48'h0, shifted[15:0]};              // LHU
                3'b110: load_extend = {32'h0, shifted[31:0]};              // LWU
                default: load_extend = shifted;
            endcase
        end
    endfunction

    // Combinational: ALU inputs for the current instruction
    always @* begin
        alu_a  = rdata1;
        alu_b  = rdata2;
        alu_op = 5'd0; // ADD

        if (state == S_EXEC) begin
            if (opcode == 7'h13) begin // OP-IMM
                alu_b = imm_i;
                case (funct3)
                    3'b000: alu_op = 5'd0; // ADDI
                    3'b010: alu_op = 5'd8; // SLTI
                    3'b011: alu_op = 5'd9; // SLTIU
                    3'b100: alu_op = 5'd4; // XORI
                    3'b110: alu_op = 5'd3; // ORI
                    3'b111: alu_op = 5'd2; // ANDI
                    3'b001: alu_op = 5'd5; // SLLI
                    3'b101: alu_op = (funct7[5] ? 5'd7 : 5'd6); // SRAI/SRLI
                    default: alu_op = 5'd0;
                endcase
            end else if (opcode == 7'h33) begin // OP / MUL
                if (funct7 == 7'h01 && funct3 == 3'b000) begin
                    alu_op = 5'd10; // MUL (low 64)
                end else begin
                    case ({funct7, funct3})
                        {7'h00,3'b000}: alu_op = 5'd0; // ADD
                        {7'h20,3'b000}: alu_op = 5'd1; // SUB
                        {7'h00,3'b111}: alu_op = 5'd2; // AND
                        {7'h00,3'b110}: alu_op = 5'd3; // OR
                        {7'h00,3'b100}: alu_op = 5'd4; // XOR
                        {7'h00,3'b001}: alu_op = 5'd5; // SLL
                        {7'h00,3'b101}: alu_op = 5'd6; // SRL
                        {7'h20,3'b101}: alu_op = 5'd7; // SRA
                        {7'h00,3'b010}: alu_op = 5'd8; // SLT
                        {7'h00,3'b011}: alu_op = 5'd9; // SLTU
                        default:         alu_op = 5'd0;
                    endcase
                end
            end
        end
    end

    // Combinational outputs
    always @* begin
        // Instruction interface
        if_valid = (state == S_FETCH);
        if_addr  = pc;

        // Data interface
        mem_valid = (state == S_MEM);
        mem_we    = (state == S_MEM) && (mem_opcode == 7'h23); // STORE
        mem_addr  = mem_eff_addr;

        mem_wstrb = (mem_opcode == 7'h23) ? gen_wstrb(mem_funct3, mem_eff_addr[2:0]) : 8'h00;
        mem_wdata = (mem_opcode == 7'h23) ? (mem_store_data << (mem_eff_addr[2:0] * 8)) : 64'h0;

        // regfile writeback (synchronous inside regfile)
        rf_we    = (state == S_WB) && wb_en && (wb_rd != 5'd0);
        rf_waddr = wb_rd;
        rf_wdata = wb_value;

        // BHT update
        bht_upd_valid = (state == S_EXEC) && (opcode == 7'h63);
        bht_upd_pc    = pc;
        bht_upd_taken = br_take;
    end

    // Sequential control
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_FETCH;
            pc    <= RESET_PC;
            ir    <= 32'h0000_0013; // NOP (ADDI x0,x0,0)

            wb_en    <= 1'b0;
            wb_rd    <= 5'd0;
            wb_value <= 64'h0;

            mem_eff_addr   <= 64'h0;
            mem_funct3     <= 3'h0;
            mem_opcode     <= 7'h0;
            mem_store_data <= 64'h0;

            dbg_pc <= RESET_PC;
                    gpu_ci_valid     <= 1'b0;
            gpu_ci_op        <= 8'h00;
            gpu_ci_arg0      <= 64'h0;
            gpu_ci_arg1      <= 64'h0;
            gpu_ci_rsp_ready <= 1'b0;
            gpu_pending      <= 1'b0;
            gpu_op_q         <= 8'h00;
            gpu_a0_q          <= 64'h0;
            gpu_a1_q          <= 64'h0;
end else begin
            dbg_pc <= pc;

            // Default: no GPU command unless in S_GPU
            gpu_ci_valid     <= 1'b0;
            gpu_ci_rsp_ready <= 1'b0;

            case (state)
                S_FETCH: begin
                    // Wait for instruction word
                    if (if_ready && if_rvalid) begin
                        ir    <= if_rdata;
                        state <= S_DECODE;
                    end
                end

                S_DECODE: begin
                    state <= S_EXEC;
                end

                S_EXEC: begin
                    // Default sequential PC
                    pc <= pc + 64'd4;

                    // Default WB disabled
                    wb_en <= 1'b0;
                    wb_rd <= rd;

                    case (opcode)
                        7'h37: begin // LUI
                            wb_value <= imm_u;
                            wb_en    <= 1'b1;
                        end
                        7'h17: begin // AUIPC
                            wb_value <= pc + imm_u;
                            wb_en    <= 1'b1;
                        end
                        7'h6F: begin // JAL
                            wb_value <= pc + 64'd4;
                            wb_en    <= 1'b1;
                            pc       <= pc + imm_j;
                        end
                        7'h67: begin // JALR
                            wb_value <= pc + 64'd4;
                            wb_en    <= 1'b1;
                            pc       <= (rdata1 + imm_i) & ~64'd1;
                        end
                        7'h63: begin // BRANCH
                            if (br_take) pc <= pc + imm_b;
                            wb_en <= 1'b0;
                        end
                        7'h03: begin // LOAD
                            mem_eff_addr   <= rdata1 + imm_i;
                            mem_funct3     <= funct3;
                            mem_opcode     <= opcode;
                            state          <= S_MEM;
                        end
                        7'h23: begin // STORE
                            mem_eff_addr   <= rdata1 + imm_s;
                            mem_funct3     <= funct3;
                            mem_opcode     <= opcode;
                            mem_store_data <= rdata2;
                            state          <= S_MEM;
                        end
                        7'h13: begin // OP-IMM
                            wb_value <= alu_y;
                            wb_en    <= 1'b1;
                        end
                        7'h33: begin // OP / MUL
                            wb_value <= alu_y;
                            wb_en    <= 1'b1;
                        end
                                                7'h0B: begin // CUSTOM-0 (GPU custom instruction)
                            // We interpret CUSTOM-0 as a GPU command:
                            //   gpu_ci_op   = {funct7[6:0], funct3[2:0]} simplified to 8 bits
                            //   gpu_ci_arg0 = rs1 value
                            //   gpu_ci_arg1 = rs2 value
                            //
                            // The actual operation definitions live in the GPU block.
                            // This core only transports op/args and waits for a response.
                            gpu_pending <= 1'b1;
                            gpu_op_q    <= {funct7[4:0], funct3}; // 5+3 = 8 bits (compact encoding)
                            gpu_a0_q    <= rdata1;
                            gpu_a1_q    <= rdata2;
                            state       <= S_GPU;
                            wb_en       <= 1'b0;
                        end
default: begin
                            wb_en <= 1'b0;
                        end
                    endcase

                    if (state == S_EXEC && opcode != 7'h03 && opcode != 7'h23 && opcode != 7'h0B) begin
                        state <= S_WB;
                    end
                end

                S_MEM: begin
                    // Wait for D$ to accept and respond
                    if (mem_ready && mem_rvalid) begin
                        if (mem_opcode == 7'h03) begin
                            wb_value <= load_extend(mem_funct3, mem_rdata, mem_eff_addr[2:0]);
                            wb_rd    <= rd;
                            wb_en    <= 1'b1;
                        end else begin
                            wb_en <= 1'b0; // store
                        end
                        state <= S_WB;
                    end
                end

                S_WB: begin
                    // regfile write happens this cycle via rf_we/rf_w* combinational
                    state <= S_FETCH;
                end

                default: state <= S_FETCH;
            endcase
        end
    end
endmodule
