// -----------------------------------------------------------------------------
// control_unit.sv
// RV64 instruction decoder for the SIEEECURE 7-stage core.
// Outputs a "one instruction" control bundle used by ID->EX1 latch.
//
// Supported ISA in this project (default):
//   RV64I + RV64M + Zicsr + Zifencei
//   RV64 "W" subset (OP-32/OP-IMM-32)
//   Custom-0 opcode used for SIEEECURE encrypted instructions (SE extension)
//
// Privilege model: M-mode only (MRET supported).
// -----------------------------------------------------------------------------
module control_unit(
    input  wire [31:0] instr,

    // Common fields
    output wire [6:0]  opcode,
    output wire [2:0]  funct3,
    output wire [6:0]  funct7,
    output wire [4:0]  rd,
    output wire [4:0]  rs1,
    output wire [4:0]  rs2,

    // Main control
    output wire        reg_wen,
    output wire [2:0]  wb_sel,      // rv64_pkg::WB_*
    output wire [2:0]  op_a_sel,    // rv64_pkg::OP_A_*
    output wire [2:0]  op_b_sel,    // rv64_pkg::OP_B_*
    output wire [3:0]  alu_sel,     // rv64_pkg::ALU_*
    output wire        is_word_op,  // sign-extend low 32 bits of result

    // Branch/jump
    output wire        is_branch,
    output wire        is_jal,
    output wire        is_jalr,

    // Memory
    output wire        mem_ren,
    output wire        mem_wen,
    output wire [2:0]  mem_size,     // rv64_pkg::MEM_*
    output wire        mem_unsigned, // for loads

    // CSR/system
    output wire        is_fence,
    output wire        is_fencei,
    output wire        is_ecall,
    output wire        is_ebreak,
    output wire        is_mret,
    output wire        is_wfi,

    output wire        csr_en,
    output wire [1:0]  csr_cmd,      // rv64_pkg::CSR_*
    output wire        csr_use_imm,
    output wire [4:0]  csr_zimm,
    output wire [11:0] csr_addr,

    // M extension
    output wire        is_mul,
    output wire        is_div,
    output wire        is_rem,
    output wire        div_signed,
    output wire [2:0]  mul_funct3,

    // SIEEECURE custom extension
    output wire        is_se_rtype,
    output wire        is_se_ld,
    output wire        is_se_sd,
    output wire [6:0]  se_op,        // from funct7 for SE.RTYPE

    // Illegal instruction
    output wire        illegal
);
    import rv64_pkg::*;

    assign opcode = instr[6:0];
    assign rd     = instr[11:7];
    assign funct3 = instr[14:12];
    assign rs1    = instr[19:15];
    assign rs2    = instr[24:20];
    assign funct7 = instr[31:25];

    // Defaults
    reg        reg_wen_r;
    reg [2:0]  wb_sel_r;
    reg [2:0]  op_a_sel_r;
    reg [2:0]  op_b_sel_r;
    reg [3:0]  alu_sel_r;
    reg        is_word_r;

    reg        is_branch_r, is_jal_r, is_jalr_r;
    reg        mem_ren_r, mem_wen_r;
    reg [2:0]  mem_size_r;
    reg        mem_unsigned_r;

    reg        is_fence_r, is_fencei_r;
    reg        is_ecall_r, is_ebreak_r, is_mret_r, is_wfi_r;

    reg        csr_en_r;
    reg [1:0]  csr_cmd_r;
    reg        csr_use_imm_r;
    reg [4:0]  csr_zimm_r;
    reg [11:0] csr_addr_r;

    reg        is_mul_r, is_div_r, is_rem_r, div_signed_r;
    reg [2:0]  mul_funct3_r;

    reg        is_se_rtype_r, is_se_ld_r, is_se_sd_r;
    reg [6:0]  se_op_r;

    reg        illegal_r;

    // Decoding
    always @(*) begin
        // defaults
        reg_wen_r       = 1'b0;
        wb_sel_r        = WB_ALU;
        op_a_sel_r      = OP_A_RS1;
        op_b_sel_r      = OP_B_RS2;
        alu_sel_r       = ALU_ADD;
        is_word_r       = 1'b0;

        is_branch_r     = 1'b0;
        is_jal_r        = 1'b0;
        is_jalr_r       = 1'b0;

        mem_ren_r       = 1'b0;
        mem_wen_r       = 1'b0;
        mem_size_r      = MEM_D;
        mem_unsigned_r  = 1'b0;

        is_fence_r      = 1'b0;
        is_fencei_r     = 1'b0;

        is_ecall_r      = 1'b0;
        is_ebreak_r     = 1'b0;
        is_mret_r       = 1'b0;
        is_wfi_r        = 1'b0;

        csr_en_r        = 1'b0;
        csr_cmd_r       = CSR_NONE;
        csr_use_imm_r   = 1'b0;
        csr_zimm_r      = rs1;
        csr_addr_r      = instr[31:20];

        is_mul_r        = 1'b0;
        is_div_r        = 1'b0;
        is_rem_r        = 1'b0;
        div_signed_r    = 1'b0;
        mul_funct3_r    = funct3;

        is_se_rtype_r   = 1'b0;
        is_se_ld_r      = 1'b0;
        is_se_sd_r      = 1'b0;
        se_op_r         = funct7;

        illegal_r       = 1'b0;

        unique case (opcode)

            OPCODE_LUI: begin
                reg_wen_r   = 1'b1;
                op_a_sel_r  = OP_A_ZERO;
                op_b_sel_r  = OP_B_IMM;
                alu_sel_r   = ALU_LUI;
            end

            OPCODE_AUIPC: begin
                reg_wen_r   = 1'b1;
                op_a_sel_r  = OP_A_PC;
                op_b_sel_r  = OP_B_IMM;
                alu_sel_r   = ALU_ADD;
            end

            OPCODE_JAL: begin
                reg_wen_r   = (rd != 5'd0);
                wb_sel_r    = WB_PC4;
                is_jal_r    = 1'b1;
                // target computed in EX1 using imm_j + pc
            end

            OPCODE_JALR: begin
                reg_wen_r   = (rd != 5'd0);
                wb_sel_r    = WB_PC4;
                is_jalr_r   = 1'b1;
            end

            OPCODE_BRANCH: begin
                is_branch_r = 1'b1;
                // branch condition in branch_comp
            end

            OPCODE_LOAD: begin
                reg_wen_r   = (rd != 5'd0);
                wb_sel_r    = WB_MEM;
                mem_ren_r   = 1'b1;
                op_a_sel_r  = OP_A_RS1;
                op_b_sel_r  = OP_B_IMM;
                alu_sel_r   = ALU_ADD;
                unique case (funct3)
                    3'b000: begin mem_size_r = MEM_B; mem_unsigned_r = 1'b0; end // LB
                    3'b001: begin mem_size_r = MEM_H; mem_unsigned_r = 1'b0; end // LH
                    3'b010: begin mem_size_r = MEM_W; mem_unsigned_r = 1'b0; end // LW
                    3'b011: begin mem_size_r = MEM_D; mem_unsigned_r = 1'b0; end // LD
                    3'b100: begin mem_size_r = MEM_B; mem_unsigned_r = 1'b1; end // LBU
                    3'b101: begin mem_size_r = MEM_H; mem_unsigned_r = 1'b1; end // LHU
                    3'b110: begin mem_size_r = MEM_W; mem_unsigned_r = 1'b1; end // LWU
                    default: illegal_r = 1'b1;
                endcase
            end

            OPCODE_STORE: begin
                mem_wen_r   = 1'b1;
                op_a_sel_r  = OP_A_RS1;
                op_b_sel_r  = OP_B_IMM;
                alu_sel_r   = ALU_ADD;
                unique case (funct3)
                    3'b000: mem_size_r = MEM_B; // SB
                    3'b001: mem_size_r = MEM_H; // SH
                    3'b010: mem_size_r = MEM_W; // SW
                    3'b011: mem_size_r = MEM_D; // SD
                    default: begin mem_size_r = MEM_D; illegal_r = 1'b1; end
                endcase
            end

            OPCODE_OP_IMM: begin
                reg_wen_r  = (rd != 5'd0);
                wb_sel_r   = WB_ALU;
                op_a_sel_r = OP_A_RS1;
                op_b_sel_r = OP_B_IMM;
                unique case (funct3)
                    3'b000: alu_sel_r = ALU_ADD; // ADDI
                    3'b010: alu_sel_r = ALU_SLT; // SLTI
                    3'b011: alu_sel_r = ALU_SLTU;// SLTIU
                    3'b100: alu_sel_r = ALU_XOR; // XORI
                    3'b110: alu_sel_r = ALU_OR;  // ORI
                    3'b111: alu_sel_r = ALU_AND; // ANDI
                    3'b001: alu_sel_r = ALU_SLL; // SLLI
                    3'b101: begin
                        if (funct7 == 7'b0000000) alu_sel_r = ALU_SRL; // SRLI
                        else if (funct7 == 7'b0100000) alu_sel_r = ALU_SRA; // SRAI
                        else illegal_r = 1'b1;
                    end
                    default: illegal_r = 1'b1;
                endcase
            end

            OPCODE_OP: begin
                reg_wen_r  = (rd != 5'd0);
                wb_sel_r   = WB_ALU;
                op_a_sel_r = OP_A_RS1;
                op_b_sel_r = OP_B_RS2;

                if (funct7 == 7'b0000001) begin
                    // RV64M
                    wb_sel_r      = WB_MULDIV;
                    mul_funct3_r  = funct3;

                    unique case (funct3)
                        3'b000, 3'b001, 3'b010, 3'b011: begin
                            is_mul_r = 1'b1;
                        end
                        3'b100: begin
                            is_div_r     = 1'b1;
                            div_signed_r = 1'b1; // DIV
                        end
                        3'b101: begin
                            is_div_r     = 1'b1;
                            div_signed_r = 1'b0; // DIVU
                        end
                        3'b110: begin
                            is_rem_r     = 1'b1;
                            div_signed_r = 1'b1; // REM
                        end
                        3'b111: begin
                            is_rem_r     = 1'b1;
                            div_signed_r = 1'b0; // REMU
                        end
                        default: illegal_r = 1'b1;
                    endcase
                end else begin
                    // Base RV64I register ops
                    unique case (funct3)
                        3'b000: alu_sel_r = (funct7 == 7'b0100000) ? ALU_SUB : ALU_ADD; // ADD/SUB
                        3'b001: alu_sel_r = ALU_SLL;
                        3'b010: alu_sel_r = ALU_SLT;
                        3'b011: alu_sel_r = ALU_SLTU;
                        3'b100: alu_sel_r = ALU_XOR;
                        3'b101: alu_sel_r = (funct7 == 7'b0100000) ? ALU_SRA : ALU_SRL; // SRL/SRA
                        3'b110: alu_sel_r = ALU_OR;
                        3'b111: alu_sel_r = ALU_AND;
                        default: illegal_r = 1'b1;
                    endcase
                end
            end

            // RV64 word-immediate ops
            OPCODE_OP_IMM_32: begin
                reg_wen_r  = (rd != 5'd0);
                wb_sel_r   = WB_ALU;
                op_a_sel_r = OP_A_RS1;
                op_b_sel_r = OP_B_IMM;
                is_word_r  = 1'b1;
                unique case (funct3)
                    3'b000: alu_sel_r = ALU_ADD; // ADDIW
                    3'b001: begin
                        // SLLIW: funct7 must be 0000000
                        if (funct7 == 7'b0000000) alu_sel_r = ALU_SLL;
                        else illegal_r = 1'b1;
                    end
                    3'b101: begin
                        if (funct7 == 7'b0000000) alu_sel_r = ALU_SRL; // SRLIW
                        else if (funct7 == 7'b0100000) alu_sel_r = ALU_SRA; // SRAIW
                        else illegal_r = 1'b1;
                    end
                    default: illegal_r = 1'b1;
                endcase
            end

            // RV64 word register ops
            OPCODE_OP_32: begin
                reg_wen_r  = (rd != 5'd0);
                wb_sel_r   = WB_ALU;
                op_a_sel_r = OP_A_RS1;
                op_b_sel_r = OP_B_RS2;
                is_word_r  = 1'b1;

                if (funct7 == 7'b0000001) begin
                    // RV64M word ops
                    wb_sel_r      = WB_MULDIV;
                    mul_funct3_r  = funct3;

                    unique case (funct3)
                        3'b000: begin
                            is_mul_r = 1'b1; // MULW
                        end
                        3'b100: begin
                            is_div_r     = 1'b1; // DIVW
                            div_signed_r = 1'b1;
                        end
                        3'b101: begin
                            is_div_r     = 1'b1; // DIVUW
                            div_signed_r = 1'b0;
                        end
                        3'b110: begin
                            is_rem_r     = 1'b1; // REMW
                            div_signed_r = 1'b1;
                        end
                        3'b111: begin
                            is_rem_r     = 1'b1; // REMUW
                            div_signed_r = 1'b0;
                        end
                        default: illegal_r = 1'b1;
                    endcase
                end else begin
                    // Base word ops
                    unique case (funct3)
                        3'b000: alu_sel_r = (funct7 == 7'b0100000) ? ALU_SUB : ALU_ADD; // ADDW/SUBW
                        3'b001: alu_sel_r = ALU_SLL; // SLLW
                        3'b101: alu_sel_r = (funct7 == 7'b0100000) ? ALU_SRA : ALU_SRL; // SRLW/SRAW
                        default: illegal_r = 1'b1;
                    endcase
                end
            end

            OPCODE_MISC_MEM: begin
                // FENCE / FENCE.I
                if (funct3 == 3'b000) begin
                    is_fence_r = 1'b1;
                end else if (funct3 == 3'b001) begin
                    is_fencei_r = 1'b1;
                end else begin
                    illegal_r = 1'b1;
                end
            end

            OPCODE_SYSTEM: begin
                if (funct3 == 3'b000) begin
                    // ECALL/EBREAK/MRET/WFI identified by imm[11:0]
                    unique case (instr[31:20])
                        12'h000: is_ecall_r  = 1'b1;
                        12'h001: is_ebreak_r = 1'b1;
                        12'h302: is_mret_r   = 1'b1;
                        12'h105: is_wfi_r    = 1'b1;
                        default: illegal_r   = 1'b1;
                    endcase
                end else begin
                    // CSR instructions
                    csr_en_r = 1'b1;
                    csr_addr_r = instr[31:20];
                    unique case (funct3)
                        3'b001: begin csr_cmd_r = CSR_WRITE; csr_use_imm_r = 1'b0; end // CSRRW
                        3'b010: begin csr_cmd_r = CSR_SET;   csr_use_imm_r = 1'b0; end // CSRRS
                        3'b011: begin csr_cmd_r = CSR_CLEAR; csr_use_imm_r = 1'b0; end // CSRRC
                        3'b101: begin csr_cmd_r = CSR_WRITE; csr_use_imm_r = 1'b1; end // CSRRWI
                        3'b110: begin csr_cmd_r = CSR_SET;   csr_use_imm_r = 1'b1; end // CSRRSI
                        3'b111: begin csr_cmd_r = CSR_CLEAR; csr_use_imm_r = 1'b1; end // CSRRCI
                        default: begin csr_cmd_r = CSR_NONE; illegal_r = 1'b1; end
                    endcase

                    // rd gets old CSR value unless rd=x0
                    reg_wen_r = (rd != 5'd0);
                    wb_sel_r  = WB_CSR;
                end
            end

            // Custom opcode: SIEEECURE encrypted instructions
            OPCODE_CUSTOM0: begin
                unique case (funct3)
                    3'b000: begin
                        // SE.RTYPE: se.op eRd, eRs1, eRs2   (funct7 encodes operation)
                        is_se_rtype_r = 1'b1;
                        // Writes ciphertext to eRd, not xRd
                        reg_wen_r = 1'b0;
                    end
                    3'b001: begin
                        // SE.LD: se.ld eRd, imm(rs1)   (I-type imm)
                        is_se_ld_r = 1'b1;
                        // 128-bit memory read into eRd
                        reg_wen_r = 1'b0;
                        mem_ren_r = 1'b1;
                        mem_size_r = MEM_Q;
                        op_a_sel_r = OP_A_RS1;
                        op_b_sel_r = OP_B_IMM;
                        alu_sel_r  = ALU_ADD;
                    end
                    3'b010: begin
                        // SE.SD: se.sd eRs2, imm(rs1)  (S-type imm)
                        is_se_sd_r = 1'b1;
                        reg_wen_r  = 1'b0;
                        mem_wen_r  = 1'b1;
                        mem_size_r = MEM_Q;
                        op_a_sel_r = OP_A_RS1;
                        op_b_sel_r = OP_B_IMM;
                        alu_sel_r  = ALU_ADD;
                    end
                    default: illegal_r = 1'b1;
                endcase
            end

            default: begin
                illegal_r = 1'b1;
            end

        endcase
    end

    // Outputs
    assign reg_wen       = reg_wen_r;
    assign wb_sel        = wb_sel_r;
    assign op_a_sel      = op_a_sel_r;
    assign op_b_sel      = op_b_sel_r;
    assign alu_sel       = alu_sel_r;
    assign is_word_op    = is_word_r;

    assign is_branch     = is_branch_r;
    assign is_jal        = is_jal_r;
    assign is_jalr       = is_jalr_r;

    assign mem_ren       = mem_ren_r;
    assign mem_wen       = mem_wen_r;
    assign mem_size      = mem_size_r;
    assign mem_unsigned  = mem_unsigned_r;

    assign is_fence      = is_fence_r;
    assign is_fencei     = is_fencei_r;

    assign is_ecall      = is_ecall_r;
    assign is_ebreak     = is_ebreak_r;
    assign is_mret       = is_mret_r;
    assign is_wfi        = is_wfi_r;

    assign csr_en        = csr_en_r;
    assign csr_cmd       = csr_cmd_r;
    assign csr_use_imm   = csr_use_imm_r;
    assign csr_zimm      = csr_zimm_r;
    assign csr_addr      = csr_addr_r;

    assign is_mul        = is_mul_r;
    assign is_div        = is_div_r;
    assign is_rem        = is_rem_r;
    assign div_signed    = div_signed_r;
    assign mul_funct3    = mul_funct3_r;

    assign is_se_rtype   = is_se_rtype_r;
    assign is_se_ld      = is_se_ld_r;
    assign is_se_sd      = is_se_sd_r;
    assign se_op         = se_op_r;

    assign illegal       = illegal_r;

endmodule
