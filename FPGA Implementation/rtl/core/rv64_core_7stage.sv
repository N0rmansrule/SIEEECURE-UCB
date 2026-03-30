// -----------------------------------------------------------------------------
// rv64_core_7stage.sv
// In-order RV64 core with a 7-stage style pipeline:
//
//   IF1 : PC / branch prediction / I$ line request
//   IF2 : Instruction word select / latch
//   ID  : Decode / reg read
//   EX1 : Execute / branch resolve / AGU / start mul-div / start SE
//   MEM1: Cache access (blocking) / hold for response
//   EX2 : Load data align / finalize WB value
//   WB  : Register writeback / retire
//
// Notes:
// - This core is intended as a compact reference. It supports RV64I + M,
//   basic CSRs (machine mode), and the SIEEECURE custom instructions.
// - It assumes 32-bit fixed-length instructions (no C extension).
// -----------------------------------------------------------------------------
module rv64_core_7stage #(
    parameter logic [63:0] RESET_PC    = 64'h0000_0000_0000_0000,
    parameter int          AES_KEY_BITS = 128
)(
    input  wire         clk,
    input  wire         rst,

    // I$ line interface (16-byte lines)
    output wire         imem_req_valid,
    input  wire         imem_req_ready,
    output wire [63:0]  imem_req_addr,
    input  wire         imem_resp_valid,
    output wire         imem_resp_ready,
    input  wire [127:0] imem_resp_rdata,
    input  wire         imem_resp_err,

    // D$ line interface (16-byte lines)
    output wire         dmem_req_valid,
    input  wire         dmem_req_ready,
    output wire [63:0]  dmem_req_addr,
    output wire         dmem_req_write,
    output wire [127:0] dmem_req_wdata,
    output wire [15:0]  dmem_req_wstrb,
    input  wire         dmem_resp_valid,
    output wire         dmem_resp_ready,
    input  wire [127:0] dmem_resp_rdata,
    input  wire         dmem_resp_err,

    input  wire         ext_irq,        // not fully implemented

    // Optional external SE key path (from QRNG / photonic entropy manager)
    input  wire         se_ext_mode,       // 0=use CSR-programmed key path, 1=use external key path
    input  wire         se_ext_enable,
    input  wire         se_ext_key_update,
    input  wire [AES_KEY_BITS-1:0] se_ext_key,
    input  wire [63:0]  se_ext_seed,

    output wire         fencei_pulse,    // connect to I$ invalidate
    output wire [63:0]  dbg_pc
);
    import rv64_pkg::*;
    import se_pkg::*;

    // =========================================================================
    // IF1: PC and I$ line buffer
    // =========================================================================
    logic [63:0] pc_if1;

    logic        ibuf_valid;
    logic [63:0] ibuf_addr;
    logic [127:0] ibuf_line;

    logic        ifetch_inflight;
    logic [63:0] ifetch_addr;

    wire [63:0] pc_plus4_if1 = pc_if1 + 64'd4;
    wire [63:0] pc_line_if1  = pc_if1 & 64'hFFFF_FFFF_FFFF_FFF0;
    wire [1:0]  pc_word_idx  = pc_if1[3:2];

    wire instr_avail = ibuf_valid && (ibuf_addr == pc_line_if1);
    wire [31:0] instr_word = ibuf_line[pc_word_idx*32 +: 32];

    // Branch predictor (query in IF1)
    wire bp_taken;
    wire [63:0] bp_target;

    // Update ports (from EX1 commit)
    wire bp_upd_valid;
    wire [63:0] bp_upd_pc;
    wire bp_upd_is_cond;
    wire bp_upd_is_jump;
    wire bp_upd_is_call;
    wire bp_upd_is_return;
    wire bp_upd_taken;
    wire [63:0] bp_upd_target;
    wire [63:0] bp_upd_pc_plus4;

    branch_predictor u_bp (
        .clk(clk),
        .rst(rst),
        .pc_query(pc_if1),
        .pred_taken(bp_taken),
        .pred_target(bp_target),

        .upd_valid(bp_upd_valid),
        .upd_pc(bp_upd_pc),
        .upd_is_cond_branch(bp_upd_is_cond),
        .upd_is_jump(bp_upd_is_jump),
        .upd_is_call(bp_upd_is_call),
        .upd_is_return(bp_upd_is_return),
        .upd_taken(bp_upd_taken),
        .upd_target(bp_upd_target),
        .upd_pc_plus4(bp_upd_pc_plus4)
    );

    // I$ request/response
    assign imem_req_valid  = (!instr_avail) && (!ifetch_inflight);
    assign imem_req_addr   = pc_line_if1;
    assign imem_resp_ready = ifetch_inflight;

    // =========================================================================
    // Pipeline registers: IF2, ID, EX1, MEM1, EX2, WB
    // =========================================================================
    // IF2
    logic        if2_valid;
    logic [63:0] if2_pc;
    logic [31:0] if2_instr;
    logic        if2_pred_taken;
    logic [63:0] if2_pred_target;

    // ID
    logic        id_valid;
    logic [63:0] id_pc;
    logic [31:0] id_instr;
    logic        id_pred_taken;
    logic [63:0] id_pred_target;

    // EX1
    logic        ex1_valid;
    logic [63:0] ex1_pc;
    logic [31:0] ex1_instr;
    logic        ex1_pred_taken;
    logic [63:0] ex1_pred_target;

    // Control signals latched into EX1
    logic        ex1_reg_wen;
    logic [2:0]  ex1_wb_sel;
    logic [2:0]  ex1_op_a_sel;
    logic [2:0]  ex1_op_b_sel;
    logic [3:0]  ex1_alu_sel;
    logic        ex1_is_word_op;

    logic        ex1_is_branch, ex1_is_jal, ex1_is_jalr;
    logic        ex1_mem_ren, ex1_mem_wen;
    logic [2:0]  ex1_mem_size;
    logic        ex1_mem_unsigned;

    logic        ex1_is_fence, ex1_is_fencei;
    logic        ex1_is_ecall, ex1_is_ebreak, ex1_is_mret, ex1_is_wfi;

    logic        ex1_csr_en;
    logic [1:0]  ex1_csr_cmd;
    logic        ex1_csr_use_imm;
    logic [4:0]  ex1_csr_zimm;
    logic [11:0] ex1_csr_addr;

    logic        ex1_is_mul, ex1_is_div, ex1_is_rem;
    logic        ex1_div_signed;
    logic [2:0]  ex1_mul_funct3;

    logic        ex1_is_se_rtype, ex1_is_se_ld, ex1_is_se_sd;
    logic [6:0]  ex1_se_op;

    logic        ex1_illegal;

    // Latched immediates/operands into EX1
    logic [63:0]  ex1_imm_i, ex1_imm_s, ex1_imm_b, ex1_imm_u, ex1_imm_j;
    logic [63:0]  ex1_rs1_val, ex1_rs2_val;
    logic [127:0] ex1_ers1_ct, ex1_ers2_ct;

    // Long-latency op tracking in EX1 (prevents re-issuing while stalled)
    logic        ex1_se_started, ex1_se_done;
    logic [127:0] ex1_se_result;
    logic        ex1_div_started, ex1_div_done;
    logic [63:0]  ex1_div_result;

    // MEM1
    logic        mem1_valid;
    logic [63:0] mem1_pc;
    logic [4:0]  mem1_rd;
    logic        mem1_reg_wen;
    logic [2:0]  mem1_wb_sel;
    logic        mem1_is_word_op;

    logic        mem1_is_load, mem1_is_store;
    logic [2:0]  mem1_mem_size;
    logic        mem1_mem_unsigned;
    logic [63:0] mem1_addr;
    logic [63:0] mem1_addr_line;
    logic [127:0] mem1_store_wdata_line;
    logic [15:0]  mem1_store_wstrb_line;

    logic [63:0] mem1_result_pre;
    logic [63:0] mem1_pc_plus4;
    logic [63:0] mem1_csr_rdata;

    // e-reg writeback path (ciphertext)
    logic         mem1_ewen;
    logic [4:0]   mem1_erd;
    logic [127:0] mem1_ewdata;

    logic mem1_is_se_ld;
    logic mem1_is_se_sd;

    // MEM1 transaction state
    logic mem1_req_sent;
    logic mem1_resp_done;
    logic [127:0] mem1_line_rdata;
    logic mem1_resp_err;

    // EX2
    logic        ex2_valid;
    logic [63:0] ex2_pc;
    logic [4:0]  ex2_rd;
    logic        ex2_reg_wen;
    logic [63:0] ex2_wdata;
    logic        ex2_is_word_op;

    logic         ex2_ewen;
    logic [4:0]   ex2_erd;
    logic [127:0] ex2_ewdata;

    // WB
    logic        wb_valid;
    logic [4:0]  wb_rd;
    logic        wb_reg_wen;
    logic [63:0] wb_wdata;

    logic         wb_ewen;
    logic [4:0]   wb_erd;
    logic [127:0] wb_ewdata;

    // =========================================================================
    // Register files (read in ID, write in WB)
    // =========================================================================
    wire [4:0] id_rs1_idx = id_instr[19:15];
    wire [4:0] id_rs2_idx = id_instr[24:20];

    wire [63:0] rf_rdata1, rf_rdata2;
    regfile_32x64 u_rf (
        .clk(clk),
        .rst(rst),
        .raddr1(id_rs1_idx),
        .raddr2(id_rs2_idx),
        .rdata1(rf_rdata1),
        .rdata2(rf_rdata2),
        .we(wb_valid && wb_reg_wen),
        .waddr(wb_rd),
        .wdata(wb_wdata)
    );

    wire [127:0] erf_rdata1, erf_rdata2;
    eregfile_32x128 u_erf (
        .clk(clk),
        .rst(rst),
        .raddr1(id_rs1_idx),
        .raddr2(id_rs2_idx),
        .rdata1(erf_rdata1),
        .rdata2(erf_rdata2),
        .we(wb_valid && wb_ewen),
        .waddr(wb_erd),
        .wdata(wb_ewdata)
    );

    // =========================================================================
    // Immediate generator (ID)
    // =========================================================================
    wire [63:0] imm_i_d, imm_s_d, imm_b_d, imm_u_d, imm_j_d;
    imm_gen u_imm (
        .instr(id_instr),
        .imm_i(imm_i_d),
        .imm_s(imm_s_d),
        .imm_b(imm_b_d),
        .imm_u(imm_u_d),
        .imm_j(imm_j_d)
    );

    // =========================================================================
    // Decode (ID)
    // =========================================================================
    wire [6:0] d_opcode;
    wire [2:0] d_funct3;
    wire [6:0] d_funct7;
    wire [4:0] d_rd, d_rs1, d_rs2;

    wire        d_reg_wen;
    wire [2:0]  d_wb_sel;
    wire [2:0]  d_op_a_sel;
    wire [2:0]  d_op_b_sel;
    wire [3:0]  d_alu_sel;
    wire        d_is_word_op;

    wire        d_is_branch, d_is_jal, d_is_jalr;
    wire        d_mem_ren, d_mem_wen;
    wire [2:0]  d_mem_size;
    wire        d_mem_unsigned;

    wire        d_is_fence, d_is_fencei;
    wire        d_is_ecall, d_is_ebreak, d_is_mret, d_is_wfi;

    wire        d_csr_en;
    wire [1:0]  d_csr_cmd;
    wire        d_csr_use_imm;
    wire [4:0]  d_csr_zimm;
    wire [11:0] d_csr_addr;

    wire        d_is_mul, d_is_div, d_is_rem;
    wire        d_div_signed;
    wire [2:0]  d_mul_funct3;

    wire        d_is_se_rtype, d_is_se_ld, d_is_se_sd;
    wire [6:0]  d_se_op;

    wire        d_illegal;

    control_unit u_dec (
        .instr(id_instr),
        .opcode(d_opcode),
        .funct3(d_funct3),
        .funct7(d_funct7),
        .rd(d_rd),
        .rs1(d_rs1),
        .rs2(d_rs2),

        .reg_wen(d_reg_wen),
        .wb_sel(d_wb_sel),
        .op_a_sel(d_op_a_sel),
        .op_b_sel(d_op_b_sel),
        .alu_sel(d_alu_sel),
        .is_word_op(d_is_word_op),

        .is_branch(d_is_branch),
        .is_jal(d_is_jal),
        .is_jalr(d_is_jalr),

        .mem_ren(d_mem_ren),
        .mem_wen(d_mem_wen),
        .mem_size(d_mem_size),
        .mem_unsigned(d_mem_unsigned),

        .is_fence(d_is_fence),
        .is_fencei(d_is_fencei),
        .is_ecall(d_is_ecall),
        .is_ebreak(d_is_ebreak),
        .is_mret(d_is_mret),
        .is_wfi(d_is_wfi),

        .csr_en(d_csr_en),
        .csr_cmd(d_csr_cmd),
        .csr_use_imm(d_csr_use_imm),
        .csr_zimm(d_csr_zimm),
        .csr_addr(d_csr_addr),

        .is_mul(d_is_mul),
        .is_div(d_is_div),
        .is_rem(d_is_rem),
        .div_signed(d_div_signed),
        .mul_funct3(d_mul_funct3),

        .is_se_rtype(d_is_se_rtype),
        .is_se_ld(d_is_se_ld),
        .is_se_sd(d_is_se_sd),
        .se_op(d_se_op),

        .illegal(d_illegal)
    );

    // ID source usage (integer regs) for hazard detection
    // SE.RTYPE uses encrypted regs only; SE.SD uses rs1 as base, but rs2 is e-reg.
    wire id_use_rs1 = id_valid && (
        d_is_branch || d_is_jalr || d_mem_ren || d_mem_wen || d_csr_en || (d_op_a_sel == OP_A_RS1)
    ) && !(d_is_se_rtype);

    wire id_use_rs2 = id_valid && (
        (d_op_b_sel == OP_B_RS2) || d_is_branch || d_mem_wen
    ) && !(d_is_se_rtype) && !(d_is_se_sd);

    // =========================================================================
    // Hazard + forwarding
    // =========================================================================
    wire [4:0] ex1_rs1_idx = ex1_instr[19:15];
    wire [4:0] ex1_rs2_idx = ex1_instr[24:20];

    wire ex1_use_rs1 = ex1_valid && (
        ex1_is_branch || ex1_is_jalr || ex1_mem_ren || ex1_mem_wen || ex1_csr_en || (ex1_op_a_sel == OP_A_RS1)
    ) && !(ex1_is_se_rtype);

    wire ex1_use_rs2 = ex1_valid && (
        (ex1_op_b_sel == OP_B_RS2) || ex1_is_branch || ex1_mem_wen
    ) && !(ex1_is_se_rtype) && !(ex1_is_se_sd);

    wire stall_id;
    wire [1:0] fwd_a_sel, fwd_b_sel;

    hazard_unit u_haz (
        .id_valid(id_valid),
        .id_rs1(d_rs1),
        .id_rs2(d_rs2),
        .id_use_rs1(id_use_rs1),
        .id_use_rs2(id_use_rs2),

        .ex1_valid(ex1_valid),
        .ex1_rs1(ex1_rs1_idx),
        .ex1_rs2(ex1_rs2_idx),
        .ex1_use_rs1(ex1_use_rs1),
        .ex1_use_rs2(ex1_use_rs2),

        .mem1_valid(mem1_valid),
        .mem1_rd(mem1_rd),
        .mem1_reg_wen(mem1_reg_wen),
        .mem1_is_load(mem1_is_load),

        .ex2_valid(ex2_valid),
        .ex2_rd(ex2_rd),
        .ex2_reg_wen(ex2_reg_wen),

        .wb_valid(wb_valid),
        .wb_rd(wb_rd),
        .wb_reg_wen(wb_reg_wen),

        .stall_id(stall_id),
        .fwd_a_sel(fwd_a_sel),
        .fwd_b_sel(fwd_b_sel)
    );

    // Forward values
    wire [63:0] fwd_mem1_val = mem1_result_pre;
    wire [63:0] fwd_ex2_val  = ex2_wdata;
    wire [63:0] fwd_wb_val   = wb_wdata;

    function automatic [63:0] do_fwd(input [1:0] sel, input [63:0] orig);
        begin
            case (sel)
                FWD_MEM1: do_fwd = fwd_mem1_val;
                FWD_EX2:  do_fwd = fwd_ex2_val;
                FWD_WB:   do_fwd = fwd_wb_val;
                default:  do_fwd = orig;
            endcase
        end
    endfunction

    wire [63:0] rs1_fwd = do_fwd(fwd_a_sel, ex1_rs1_val);
    wire [63:0] rs2_fwd = do_fwd(fwd_b_sel, ex1_rs2_val);

    // =========================================================================
    // CSR file
    // =========================================================================
    wire [63:0] csr_rdata;
    wire [63:0] mtvec, mepc;

    // Retire: count each instruction reaching WB as retired
    wire retire = wb_valid;

    // SE CSR outputs
    wire csr_se_enable;
    wire [1:0] csr_se_key_len_sel;
    wire [255:0] csr_se_key;
    wire [63:0] csr_se_seed;

    // CSR command wires from EX1 commit (computed later)
    wire csr_valid_w;
    wire [1:0] csr_cmd_w;
    wire [11:0] csr_addr_w;
    wire [63:0] csr_wdata_w;

    // Trap wires (computed later)
    wire trap_enter_w;
    wire [63:0] trap_cause_w;
    wire [63:0] trap_tval_w;
    wire [63:0] trap_pc_w;
    wire mret_w;

    csr_file u_csr (
        .clk(clk),
        .rst(rst),

        .csr_valid(csr_valid_w),
        .csr_cmd(csr_cmd_w),
        .csr_addr(csr_addr_w),
        .csr_wdata(csr_wdata_w),
        .csr_rdata(csr_rdata),

        .trap_enter(trap_enter_w),
        .trap_cause(trap_cause_w),
        .trap_tval(trap_tval_w),
        .trap_pc(trap_pc_w),
        .mret(mret_w),

        .mtvec_out(mtvec),
        .mepc_out(mepc),

        .retire(retire),

        .se_enable(se_enable_eff),
        .se_key_len_sel(csr_se_key_len_sel),
        .se_key(csr_se_key),
        .se_seed(csr_se_seed)
    );

    // =========================================================================
    // SE unit
    // =========================================================================
    wire [AES_KEY_BITS-1:0] se_key_bits =
        (AES_KEY_BITS == 128) ? csr_se_key[127:0] :
        (AES_KEY_BITS == 192) ? csr_se_key[191:0] :
                                csr_se_key[AES_KEY_BITS-1:0];

    // Pulse key_update whenever SE CSRs are written
    wire se_key_update = csr_valid_w && (csr_addr_w[11:4] == 8'h7C);

    // Select between software-loaded key material and external entropy-derived key material.
    wire se_enable_eff = se_ext_mode ? se_ext_enable : csr_se_enable;
    wire [AES_KEY_BITS-1:0] se_key_bits_eff = se_ext_mode ? se_ext_key : se_key_bits;
    wire [63:0] se_seed_eff = se_ext_mode ? se_ext_seed : csr_se_seed;
    wire se_key_update_eff = se_ext_mode ? se_ext_key_update : se_key_update;

    wire se_req_ready, se_resp_valid, se_resp_err;
    wire [127:0] se_resp_ct;

    wire se_req_valid = ex1_valid && ex1_is_se_rtype && se_enable_eff && !ex1_se_started;
    wire [6:0] se_req_op = ex1_se_op;
    wire se_resp_ready = 1'b1;

    se_unit #(.KEY_BITS(AES_KEY_BITS)) u_se (
        .clk(clk),
        .rst(rst),
        .se_enable(se_enable_eff),
        .key_update(se_key_update_eff),
        .key_in(se_key_bits_eff),
        .seed_in(se_seed_eff),

        .req_valid(se_req_valid),
        .req_ready(se_req_ready),
        .op(se_req_op),
        .ct_a(ex1_ers1_ct),
        .ct_b(ex1_ers2_ct),

        .resp_valid(se_resp_valid),
        .resp_ready(se_resp_ready),
        .ct_y(se_resp_ct),
        .resp_err(se_resp_err)
    );

    // =========================================================================
    // Divider (iterative)
    // =========================================================================
    wire div_busy, div_done;
    wire [63:0] div_y;
    wire div_start;
    wire div_is_rem = ex1_is_rem;
    wire div_is_signed = ex1_div_signed;

    wire [63:0] div_a = (ex1_is_word_op) ?
                        (div_is_signed ? {{32{rs1_fwd[31]}}, rs1_fwd[31:0]} : {32'd0, rs1_fwd[31:0]}) :
                        rs1_fwd;
    wire [63:0] div_b = (ex1_is_word_op) ?
                        (div_is_signed ? {{32{rs2_fwd[31]}}, rs2_fwd[31:0]} : {32'd0, rs2_fwd[31:0]}) :
                        rs2_fwd;

    assign div_start = ex1_valid && (ex1_is_div || ex1_is_rem) && !ex1_div_started && !div_busy;

    div_unit u_div (
        .clk(clk),
        .rst(rst),
        .start(div_start),
        .is_rem(div_is_rem),
        .is_signed(div_is_signed),
        .a(div_a),
        .b(div_b),
        .busy(div_busy),
        .done(div_done),
        .y(div_y)
    );

    // Long-latency stalls in EX1
    wire div_wait = ex1_valid && (ex1_is_div || ex1_is_rem) && !ex1_div_done;
    wire se_wait  = ex1_valid && ex1_is_se_rtype && !ex1_se_done;
    wire stall_ex1 = div_wait || se_wait;

    // MEM1 stall (defined later once mem1_is_memop is known)
    wire stall_mem1;

    // =========================================================================
    // ALU / branch comparator / mul
    // =========================================================================
    wire [63:0] alu_in_a = (ex1_op_a_sel == OP_A_PC)   ? ex1_pc :
                           (ex1_op_a_sel == OP_A_ZERO) ? 64'd0 :
                           rs1_fwd;

    wire [63:0] ex1_imm_sel =
        (ex1_is_branch) ? ex1_imm_b :
        (ex1_is_jal)    ? ex1_imm_j :
        (ex1_is_jalr)   ? ex1_imm_i :
        (ex1_mem_wen)   ? ex1_imm_s :
        (ex1_mem_ren)   ? ex1_imm_i :
                          ex1_imm_i;

    wire [63:0] alu_in_b = (ex1_op_b_sel == OP_B_IMM) ? ex1_imm_sel :
                           (ex1_op_b_sel == OP_B_FOUR)? 64'd4 :
                           rs2_fwd;

    wire [63:0] alu_y;
    alu u_alu (
        .a(alu_in_a),
        .b(alu_in_b),
        .alu_sel(ex1_alu_sel),
        .y(alu_y)
    );

    wire branch_taken;
    branch_comp u_br (
        .funct3(ex1_instr[14:12]),
        .rs1(rs1_fwd),
        .rs2(rs2_fwd),
        .taken(branch_taken)
    );

    wire [63:0] mul_y;
    mul_unit u_mul (
        .funct3(ex1_mul_funct3),
        .is_word(ex1_is_word_op),
        .a(rs1_fwd),
        .b(rs2_fwd),
        .y(mul_y)
    );

    // =========================================================================
    // EX1 branch resolve / target / predictor update
    // =========================================================================
    wire [63:0] ex1_pc_plus4 = ex1_pc + 64'd4;
    wire [63:0] br_target    = ex1_pc + ex1_imm_b;
    wire [63:0] jal_target   = ex1_pc + ex1_imm_j;
    wire [63:0] jalr_target  = (rs1_fwd + ex1_imm_i) & ~64'd1;

    wire ex1_is_control = ex1_is_branch || ex1_is_jal || ex1_is_jalr || ex1_is_mret;

    wire act_taken = ex1_is_branch ? branch_taken :
                     (ex1_is_jal || ex1_is_jalr || ex1_is_mret) ? 1'b1 : 1'b0;

    wire [63:0] act_target = ex1_is_branch ? br_target :
                             ex1_is_jal    ? jal_target :
                             ex1_is_jalr   ? jalr_target :
                             ex1_is_mret   ? mepc :
                                             64'd0;

    wire [63:0] act_next_pc = act_taken ? act_target : ex1_pc_plus4;
    wire [63:0] pred_next_pc = ex1_pred_taken ? ex1_pred_target : ex1_pc_plus4;

    wire mispredict = ex1_valid && ex1_is_control && (act_next_pc != pred_next_pc);

    // Call/return heuristics
    wire [4:0] ex1_rd_idx = ex1_instr[11:7];
    assign bp_upd_is_call =
        (ex1_is_jal || ex1_is_jalr) && ((ex1_rd_idx == 5'd1) || (ex1_rd_idx == 5'd5));
    assign bp_upd_is_return =
        ex1_is_jalr && (ex1_rd_idx == 5'd0) && (ex1_rs1_idx == 5'd1) && (ex1_imm_i == 64'd0);

    // =========================================================================
    // Trap detection (EX1 + MEM1 + IF)
    // =========================================================================
    function automatic logic is_misaligned(input [2:0] sz, input [63:0] a);
        begin
            case (sz)
                MEM_B: is_misaligned = 1'b0;
                MEM_H: is_misaligned = a[0];
                MEM_W: is_misaligned = |a[1:0];
                MEM_D: is_misaligned = |a[2:0];
                MEM_Q: is_misaligned = |a[3:0];
                default: is_misaligned = 1'b0;
            endcase
        end
    endfunction

    localparam [63:0] CAUSE_INST_FAULT   = 64'd1;
    localparam [63:0] CAUSE_ILLEGAL      = 64'd2;
    localparam [63:0] CAUSE_BREAKPOINT   = 64'd3;
    localparam [63:0] CAUSE_LOAD_MISAL   = 64'd4;
    localparam [63:0] CAUSE_LOAD_FAULT   = 64'd5;
    localparam [63:0] CAUSE_STORE_MISAL  = 64'd6;
    localparam [63:0] CAUSE_STORE_FAULT  = 64'd7;
    localparam [63:0] CAUSE_ECALL_M      = 64'd11;

    wire ex1_is_memop = ex1_mem_ren || ex1_mem_wen;
    wire [63:0] ex1_addr = alu_y;
    wire ex1_misaligned = ex1_valid && ex1_is_memop && is_misaligned(ex1_mem_size, ex1_addr);

    wire ex1_take_trap_raw = ex1_valid && (ex1_illegal || ex1_is_ecall || ex1_is_ebreak || ex1_misaligned);

    wire [63:0] ex1_trap_cause =
        ex1_illegal ? CAUSE_ILLEGAL :
        ex1_is_ecall ? CAUSE_ECALL_M :
        ex1_is_ebreak ? CAUSE_BREAKPOINT :
        (ex1_misaligned && ex1_mem_ren) ? CAUSE_LOAD_MISAL :
        (ex1_misaligned && ex1_mem_wen) ? CAUSE_STORE_MISAL :
        CAUSE_ILLEGAL;

    wire [63:0] ex1_trap_tval =
        ex1_misaligned ? ex1_addr :
        ex1_illegal ? {32'd0, ex1_instr} :
        64'd0;

    // Only take trap when EX1 is allowed to "commit" (i.e., no older stall)
    wire ex1_commit_en = ex1_valid && !stall_ex1 && !stall_mem1;
    wire ex1_take_trap = ex1_take_trap_raw && ex1_commit_en;

    // MEM1 fault trap (bus error)
    wire mem1_is_memop = mem1_is_load || mem1_is_store || mem1_is_se_ld || mem1_is_se_sd;
    wire mem1_fault_trap = mem1_valid && mem1_is_memop && mem1_resp_done && mem1_resp_err;

    // IFetch fault trap
    wire ifetch_fault_trap = (imem_resp_valid && imem_resp_ready && imem_resp_err);

    // Trap priority
    wire trap_enter_int = mem1_fault_trap || ex1_take_trap || ifetch_fault_trap;

    wire [63:0] trap_cause_int =
        mem1_fault_trap ? (mem1_is_load ? CAUSE_LOAD_FAULT : CAUSE_STORE_FAULT) :
        ex1_take_trap    ? ex1_trap_cause :
        ifetch_fault_trap? CAUSE_INST_FAULT :
        CAUSE_ILLEGAL;

    wire [63:0] trap_tval_int =
        mem1_fault_trap ? mem1_addr :
        ex1_take_trap    ? ex1_trap_tval :
        ifetch_fault_trap? pc_if1 :
        64'd0;

    wire [63:0] trap_pc_int =
        mem1_fault_trap ? mem1_pc :
        ex1_take_trap    ? ex1_pc :
        ifetch_fault_trap? pc_if1 :
        pc_if1;

    // MRET commit (only when not stalled)
    wire mret_int = ex1_valid && ex1_is_mret && ex1_commit_en;

    // Control redirect commit (mispredict, mret) only when committing
    wire mispredict_commit = mispredict && ex1_commit_en;

    // =========================================================================
    // Redirect and flush
    // =========================================================================
    wire redirect = trap_enter_int || mret_int || mispredict_commit;
    wire [63:0] redirect_pc =
        trap_enter_int   ? mtvec :
        mret_int         ? mepc :
        mispredict_commit? act_next_pc :
        pc_if1;

    // Flush younger stages on any redirect (IF2/ID/next EX1 bubble)
    wire flush_if2 = redirect;
    wire flush_id  = redirect;
    // EX1 stage should become bubble after redirect
    wire flush_ex1_next = redirect;

    // Kill transfer to MEM1 if EX1 took a trap
    wire ex1_to_mem1_valid = ex1_commit_en && ex1_valid && !ex1_take_trap_raw;

    // Kill MEM1 -> EX2 transfer on MEM1 fault trap
    wire mem1_to_ex2_valid = mem1_valid && (!mem1_is_memop || mem1_resp_done) && !mem1_fault_trap;

    // =========================================================================
    // CSR interface wires
    // =========================================================================
    assign csr_valid_w = ex1_commit_en && ex1_valid && ex1_csr_en && !ex1_take_trap_raw;
    assign csr_cmd_w   = ex1_csr_cmd;
    assign csr_addr_w  = ex1_csr_addr;
    assign csr_wdata_w = ex1_csr_use_imm ? {59'd0, ex1_csr_zimm} : rs1_fwd;

    assign trap_enter_w = trap_enter_int;
    assign trap_cause_w = trap_cause_int;
    assign trap_tval_w  = trap_tval_int;
    assign trap_pc_w    = trap_pc_int;
    assign mret_w       = mret_int;

    // =========================================================================
    // Predictor update only when committing branch/jump
    // =========================================================================
    assign bp_upd_valid    = ex1_commit_en && ex1_valid && (ex1_is_branch || ex1_is_jal || ex1_is_jalr);
    assign bp_upd_pc       = ex1_pc;
    assign bp_upd_is_cond  = ex1_is_branch;
    assign bp_upd_is_jump  = ex1_is_jal || ex1_is_jalr;
    assign bp_upd_taken    = act_taken;
    assign bp_upd_target   = act_target;
    assign bp_upd_pc_plus4 = ex1_pc_plus4;

    // =========================================================================
    // Fence.i pulse
    // =========================================================================
    assign fencei_pulse = ex1_commit_en && ex1_valid && ex1_is_fencei;

    // =========================================================================
    // MEM1 stall condition (wait for D$ response)
    // =========================================================================
    assign stall_mem1 = mem1_valid && mem1_is_memop && !mem1_resp_done;

    // Stage enables
    wire if2_enable = !(stall_id || stall_ex1 || stall_mem1);
    wire id_enable  = if2_enable;
    wire ex1_enable = !(stall_ex1 || stall_mem1);
    wire mem1_enable = !stall_mem1;

    // =========================================================================
    // D$ request generation from MEM1 (block until response)
    // =========================================================================
    assign dmem_req_valid = mem1_valid && mem1_is_memop && !mem1_req_sent && !mem1_resp_done;
    assign dmem_req_addr  = mem1_addr_line;
    assign dmem_req_write = (mem1_is_store || mem1_is_se_sd);

    assign dmem_req_wdata = (mem1_is_se_sd) ? mem1_ewdata : mem1_store_wdata_line;
    assign dmem_req_wstrb = (mem1_is_se_sd) ? 16'hFFFF    : mem1_store_wstrb_line;

    assign dmem_resp_ready = mem1_valid && mem1_is_memop && mem1_req_sent && !mem1_resp_done;

    // =========================================================================
    // LSU align for integer loads
    // =========================================================================
    wire [63:0] lsu_load_data;
    lsu_align u_align (
        .addr(mem1_addr),
        .mem_size(mem1_mem_size),
        .is_unsigned(mem1_mem_unsigned),
        .store_data(64'd0),
        .line_rdata(mem1_line_rdata),
        .store_wdata_line(),
        .store_wstrb_line(),
        .load_data(lsu_load_data)
    );

    // =========================================================================
    // Main sequential state update
    // =========================================================================
    integer byte_off;
    always_ff @(posedge clk) begin
        if (rst) begin
            pc_if1 <= RESET_PC;

            ibuf_valid <= 1'b0;
            ibuf_addr  <= 64'd0;
            ibuf_line  <= 128'd0;
            ifetch_inflight <= 1'b0;
            ifetch_addr <= 64'd0;

            if2_valid <= 1'b0;
            if2_pc    <= 64'd0;
            if2_instr <= 32'd0;
            if2_pred_taken <= 1'b0;
            if2_pred_target<= 64'd0;

            id_valid <= 1'b0;
            id_pc    <= 64'd0;
            id_instr <= 32'd0;
            id_pred_taken <= 1'b0;
            id_pred_target<= 64'd0;

            ex1_valid <= 1'b0;
            ex1_pc    <= 64'd0;
            ex1_instr <= 32'd0;
            ex1_pred_taken <= 1'b0;
            ex1_pred_target<= 64'd0;

            ex1_reg_wen <= 1'b0;
            ex1_wb_sel  <= WB_ALU;
            ex1_op_a_sel<= OP_A_RS1;
            ex1_op_b_sel<= OP_B_RS2;
            ex1_alu_sel <= ALU_ADD;
            ex1_is_word_op <= 1'b0;

            ex1_is_branch <= 1'b0;
            ex1_is_jal    <= 1'b0;
            ex1_is_jalr   <= 1'b0;
            ex1_mem_ren   <= 1'b0;
            ex1_mem_wen   <= 1'b0;
            ex1_mem_size  <= MEM_D;
            ex1_mem_unsigned <= 1'b0;

            ex1_is_fence  <= 1'b0;
            ex1_is_fencei <= 1'b0;
            ex1_is_ecall  <= 1'b0;
            ex1_is_ebreak <= 1'b0;
            ex1_is_mret   <= 1'b0;
            ex1_is_wfi    <= 1'b0;

            ex1_csr_en    <= 1'b0;
            ex1_csr_cmd   <= CSR_NONE;
            ex1_csr_use_imm <= 1'b0;
            ex1_csr_zimm  <= 5'd0;
            ex1_csr_addr  <= 12'd0;

            ex1_is_mul    <= 1'b0;
            ex1_is_div    <= 1'b0;
            ex1_is_rem    <= 1'b0;
            ex1_div_signed<= 1'b0;
            ex1_mul_funct3<= 3'd0;

            ex1_is_se_rtype <= 1'b0;
            ex1_is_se_ld    <= 1'b0;
            ex1_is_se_sd    <= 1'b0;
            ex1_se_op       <= 7'd0;

            ex1_illegal <= 1'b0;

            ex1_imm_i <= 64'd0;
            ex1_imm_s <= 64'd0;
            ex1_imm_b <= 64'd0;
            ex1_imm_u <= 64'd0;
            ex1_imm_j <= 64'd0;
            ex1_rs1_val <= 64'd0;
            ex1_rs2_val <= 64'd0;
            ex1_ers1_ct <= 128'd0;
            ex1_ers2_ct <= 128'd0;

            ex1_se_started <= 1'b0;
            ex1_se_done    <= 1'b0;
            ex1_se_result  <= 128'd0;
            ex1_div_started<= 1'b0;
            ex1_div_done   <= 1'b0;
            ex1_div_result <= 64'd0;

            mem1_valid <= 1'b0;
            mem1_pc    <= 64'd0;
            mem1_rd    <= 5'd0;
            mem1_reg_wen <= 1'b0;
            mem1_wb_sel  <= WB_ALU;
            mem1_is_word_op <= 1'b0;
            mem1_is_load <= 1'b0;
            mem1_is_store<= 1'b0;
            mem1_mem_size<= MEM_D;
            mem1_mem_unsigned<=1'b0;
            mem1_addr <= 64'd0;
            mem1_addr_line <= 64'd0;
            mem1_store_wdata_line <= 128'd0;
            mem1_store_wstrb_line <= 16'd0;
            mem1_result_pre <= 64'd0;
            mem1_pc_plus4 <= 64'd0;
            mem1_csr_rdata <= 64'd0;
            mem1_ewen <= 1'b0;
            mem1_erd  <= 5'd0;
            mem1_ewdata <= 128'd0;
            mem1_is_se_ld <= 1'b0;
            mem1_is_se_sd <= 1'b0;

            mem1_req_sent <= 1'b0;
            mem1_resp_done <= 1'b0;
            mem1_line_rdata<= 128'd0;
            mem1_resp_err  <= 1'b0;

            ex2_valid <= 1'b0;
            ex2_pc    <= 64'd0;
            ex2_rd    <= 5'd0;
            ex2_reg_wen <= 1'b0;
            ex2_wdata <= 64'd0;
            ex2_is_word_op <= 1'b0;
            ex2_ewen <= 1'b0;
            ex2_erd  <= 5'd0;
            ex2_ewdata <= 128'd0;

            wb_valid <= 1'b0;
            wb_rd    <= 5'd0;
            wb_reg_wen <= 1'b0;
            wb_wdata <= 64'd0;
            wb_ewen  <= 1'b0;
            wb_erd   <= 5'd0;
            wb_ewdata<= 128'd0;
        end else begin
            // -------------------------------------------------------------
            // Fetch buffer handshakes
            // -------------------------------------------------------------
            if (imem_req_valid && imem_req_ready) begin
                ifetch_inflight <= 1'b1;
                ifetch_addr     <= imem_req_addr;
            end
            if (imem_resp_valid && imem_resp_ready) begin
                ifetch_inflight <= 1'b0;
                if (!imem_resp_err) begin
                    ibuf_valid <= 1'b1;
                    ibuf_addr  <= ifetch_addr;
                    ibuf_line  <= imem_resp_rdata;
                end else begin
                    ibuf_valid <= 1'b0;
                end
            end
            // fence.i: drop line buffer to force refetch
            if (fencei_pulse) begin
                ibuf_valid <= 1'b0;
            end

            // -------------------------------------------------------------
            // PC update
            // -------------------------------------------------------------
            if (redirect) begin
                pc_if1 <= redirect_pc;
            end else if (if2_enable && instr_avail) begin
                pc_if1 <= (bp_taken ? bp_target : pc_plus4_if1);
            end

            // -------------------------------------------------------------
            // IF2 update
            // -------------------------------------------------------------
            if (flush_if2) begin
                if2_valid <= 1'b0;
            end else if (if2_enable) begin
                if2_valid <= instr_avail;
                if2_pc    <= pc_if1;
                if2_instr <= instr_word;
                if2_pred_taken  <= bp_taken;
                if2_pred_target <= bp_target;
            end

            // -------------------------------------------------------------
            // ID update
            // -------------------------------------------------------------
            if (flush_id) begin
                id_valid <= 1'b0;
            end else if (id_enable) begin
                id_valid <= if2_valid;
                id_pc    <= if2_pc;
                id_instr <= if2_instr;
                id_pred_taken  <= if2_pred_taken;
                id_pred_target <= if2_pred_target;
            end

            // -------------------------------------------------------------
            // EX1 update (bubble insertion on stall_id)
            // -------------------------------------------------------------
            if (ex1_enable) begin
                if (flush_ex1_next) begin
                    ex1_valid <= 1'b0;
                    ex1_se_started <= 1'b0;
                    ex1_se_done    <= 1'b0;
                    ex1_se_result  <= 128'd0;
                    ex1_div_started<= 1'b0;
                    ex1_div_done   <= 1'b0;
                    ex1_div_result <= 64'd0;
                end else if (stall_id) begin
                    ex1_valid <= 1'b0;
                    ex1_se_started <= 1'b0;
                    ex1_se_done    <= 1'b0;
                    ex1_se_result  <= 128'd0;
                    ex1_div_started<= 1'b0;
                    ex1_div_done   <= 1'b0;
                    ex1_div_result <= 64'd0;
                end else begin
                    ex1_valid <= id_valid;
                    ex1_pc    <= id_pc;
                    ex1_instr <= id_instr;
                    ex1_pred_taken  <= id_pred_taken;
                    ex1_pred_target <= id_pred_target;

                    // latch decoded controls
                    ex1_reg_wen <= d_reg_wen;
                    ex1_wb_sel  <= d_wb_sel;
                    ex1_op_a_sel<= d_op_a_sel;
                    ex1_op_b_sel<= d_op_b_sel;
                    ex1_alu_sel <= d_alu_sel;
                    ex1_is_word_op <= d_is_word_op;

                    ex1_is_branch <= d_is_branch;
                    ex1_is_jal    <= d_is_jal;
                    ex1_is_jalr   <= d_is_jalr;

                    ex1_mem_ren   <= d_mem_ren;
                    ex1_mem_wen   <= d_mem_wen;
                    ex1_mem_size  <= d_mem_size;
                    ex1_mem_unsigned <= d_mem_unsigned;

                    ex1_is_fence  <= d_is_fence;
                    ex1_is_fencei <= d_is_fencei;
                    ex1_is_ecall  <= d_is_ecall;
                    ex1_is_ebreak <= d_is_ebreak;
                    ex1_is_mret   <= d_is_mret;
                    ex1_is_wfi    <= d_is_wfi;

                    ex1_csr_en    <= d_csr_en;
                    ex1_csr_cmd   <= d_csr_cmd;
                    ex1_csr_use_imm <= d_csr_use_imm;
                    ex1_csr_zimm  <= d_csr_zimm;
                    ex1_csr_addr  <= d_csr_addr;

                    ex1_is_mul    <= d_is_mul;
                    ex1_is_div    <= d_is_div;
                    ex1_is_rem    <= d_is_rem;
                    ex1_div_signed<= d_div_signed;
                    ex1_mul_funct3<= d_mul_funct3;

                    ex1_is_se_rtype <= d_is_se_rtype;
                    ex1_is_se_ld    <= d_is_se_ld;
                    ex1_is_se_sd    <= d_is_se_sd;
                    ex1_se_op       <= d_se_op;

                    ex1_illegal   <= d_illegal;

                    // latch immediates and operands
                    ex1_imm_i <= imm_i_d;
                    ex1_imm_s <= imm_s_d;
                    ex1_imm_b <= imm_b_d;
                    ex1_imm_u <= imm_u_d;
                    ex1_imm_j <= imm_j_d;

                    ex1_rs1_val <= rf_rdata1;
                    ex1_rs2_val <= rf_rdata2;
                    ex1_ers1_ct <= erf_rdata1;
                    ex1_ers2_ct <= erf_rdata2;

                    // reset long-op tracking for the new EX1 instruction
                    ex1_se_started <= 1'b0;
                    ex1_se_done    <= 1'b0;
                    ex1_se_result  <= 128'd0;
                    ex1_div_started<= 1'b0;
                    ex1_div_done   <= 1'b0;
                    ex1_div_result <= 64'd0;
                end
            end

            // -------------------------------------------------------------
            
            // -------------------------------------------------------------
            // Long-latency bookkeeping while EX1 is held (SE / DIV)
            // -------------------------------------------------------------
            if (ex1_valid && ex1_is_se_rtype) begin
                // Mark SE request accepted
                if (!ex1_se_started && se_req_valid && se_req_ready) begin
                    ex1_se_started <= 1'b1;
                end
                // Latch result when response arrives
                if (ex1_se_started && !ex1_se_done && se_resp_valid) begin
                    ex1_se_result <= se_resp_ct;
                    ex1_se_done   <= 1'b1;
                end
            end

            if (ex1_valid && (ex1_is_div || ex1_is_rem)) begin
                if (!ex1_div_started && div_start) begin
                    ex1_div_started <= 1'b1;
                end
                if (ex1_div_started && !ex1_div_done && div_done) begin
                    ex1_div_result <= div_y;
                    ex1_div_done   <= 1'b1;
                end
            end

// MEM1 transaction state update (req/resp) when holding a mem op
            // -------------------------------------------------------------
            if (mem1_valid && mem1_is_memop && !mem1_resp_done) begin
                if (!mem1_req_sent) begin
                    if (dmem_req_valid && dmem_req_ready) begin
                        mem1_req_sent <= 1'b1;
                    end
                end else begin
                    if (dmem_resp_valid && dmem_resp_ready) begin
                        mem1_req_sent  <= 1'b0;
                        mem1_resp_done <= 1'b1;
                        mem1_line_rdata<= dmem_resp_rdata;
                        mem1_resp_err  <= dmem_resp_err;
                    end
                end
            end

            // -------------------------------------------------------------
            // MEM1 stage update (only when not stalled)
            // -------------------------------------------------------------
            if (mem1_enable) begin
                // If mem1 fault trap, kill and clear
                if (mem1_fault_trap) begin
                    mem1_valid <= 1'b0;
                    mem1_req_sent <= 1'b0;
                    mem1_resp_done <= 1'b0;
                    mem1_resp_err  <= 1'b0;
                    mem1_line_rdata<= 128'd0;
                end else begin
                    // Shift in from EX1 (or bubble)
                    mem1_valid <= ex1_to_mem1_valid;
                    mem1_pc    <= ex1_pc;
                    mem1_rd    <= ex1_instr[11:7];
                    mem1_reg_wen <= ex1_reg_wen;
                    mem1_wb_sel  <= ex1_wb_sel;
                    mem1_is_word_op <= ex1_is_word_op;

                    mem1_is_load <= ex1_mem_ren;
                    mem1_is_store<= ex1_mem_wen;
                    mem1_mem_size<= ex1_mem_size;
                    mem1_mem_unsigned <= ex1_mem_unsigned;

                    mem1_addr <= ex1_addr;
                    mem1_addr_line <= ex1_addr & 64'hFFFF_FFFF_FFFF_FFF0;
                    mem1_pc_plus4 <= ex1_pc_plus4;

                    mem1_csr_rdata <= csr_rdata;

                    mem1_is_se_ld <= ex1_is_se_ld;
                    mem1_is_se_sd <= ex1_is_se_sd;

                    // Default store packing
                    mem1_store_wdata_line <= 128'd0;
                    mem1_store_wstrb_line <= 16'd0;

                    if (ex1_mem_wen && !ex1_is_se_sd) begin
                        byte_off = ex1_addr[3:0];
                        mem1_store_wdata_line <= ({64'd0, rs2_fwd} << (byte_off*8));
                        case (ex1_mem_size)
                            MEM_B: mem1_store_wstrb_line <= 16'h0001 << byte_off;
                            MEM_H: mem1_store_wstrb_line <= 16'h0003 << byte_off;
                            MEM_W: mem1_store_wstrb_line <= 16'h000F << byte_off;
                            MEM_D: mem1_store_wstrb_line <= 16'h00FF << byte_off;
                            default: mem1_store_wstrb_line <= 16'h0000;
                        endcase
                    end

                    // Result precompute for WB (non-load)
                    mem1_result_pre <= alu_y;
                    if (ex1_is_jal || ex1_is_jalr) begin
                        mem1_result_pre <= ex1_pc_plus4;
                    end else if (ex1_csr_en) begin
                        mem1_result_pre <= csr_rdata;
                    end else if (ex1_is_mul) begin
                        mem1_result_pre <= mul_y;
                    end else if (ex1_is_div || ex1_is_rem) begin
                        mem1_result_pre <= ex1_is_word_op ? {{32{ex1_div_result[31]}}, ex1_div_result[31:0]} : ex1_div_result;
                    end

                    // e-reg path
                    mem1_ewen   <= 1'b0;
                    mem1_erd    <= ex1_instr[11:7];
                    mem1_ewdata <= 128'd0;

                    if (ex1_is_se_rtype) begin
                        if (ex1_se_done && !se_resp_err) begin
                            mem1_ewen   <= 1'b1;
                            mem1_erd    <= ex1_instr[11:7];
                            mem1_ewdata <= ex1_se_result;
                        end
                    end else if (ex1_is_se_sd) begin
                        mem1_ewdata <= ex1_ers2_ct;
                    end

                    // Reset transaction flags for new instruction
                    mem1_req_sent  <= 1'b0;
                    mem1_resp_done <= 1'b0;
                    mem1_resp_err  <= 1'b0;
                    mem1_line_rdata<= 128'd0;
                end
            end

            // -------------------------------------------------------------
            // EX2 stage update (always shifts; bubble when MEM1 stalled)
            // -------------------------------------------------------------
            ex2_valid <= mem1_to_ex2_valid;
            ex2_pc    <= mem1_pc;
            ex2_rd    <= mem1_rd;
            ex2_reg_wen <= mem1_reg_wen;
            ex2_is_word_op <= mem1_is_word_op;

            // default
            ex2_wdata <= mem1_result_pre;

            if (mem1_is_load && mem1_resp_done && !mem1_resp_err) begin
                ex2_wdata <= lsu_load_data;
            end

            // e-reg propagation
            ex2_ewen   <= mem1_ewen;
            ex2_erd    <= mem1_erd;
            ex2_ewdata <= mem1_ewdata;

            if (mem1_is_se_ld && mem1_resp_done && !mem1_resp_err) begin
                ex2_ewen   <= 1'b1;
                ex2_erd    <= mem1_rd;
                ex2_ewdata <= mem1_line_rdata;
            end

            // -------------------------------------------------------------
            // WB stage update (always shifts)
            // -------------------------------------------------------------
            wb_valid   <= ex2_valid;
            wb_rd      <= ex2_rd;
            wb_reg_wen <= ex2_reg_wen;
            wb_wdata   <= ex2_is_word_op ? {{32{ex2_wdata[31]}}, ex2_wdata[31:0]} : ex2_wdata;

            wb_ewen    <= ex2_ewen;
            wb_erd     <= ex2_erd;
            wb_ewdata  <= ex2_ewdata;
        end
    end

    assign dbg_pc = pc_if1;

endmodule