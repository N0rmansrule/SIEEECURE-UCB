// rv64_fpu_ieee754.v
// -----------------------------------------------------------------------------
// IEEE-754 (binary32) FPU for RV64F-style single-precision operations.
//
// Implements the 8 checkpoint instructions (compute-side):
//   1) flw   fd, imm(rs1)   -- load word -> FP reg (handled by LSU, not here)
//   2) fsw   fs2, imm(rs1)  -- store word from FP reg (handled by LSU, not here)
//   3) fadd.s   fd, fs1, fs2
//   4) fmadd.s  fd, fs1, fs2, fs3  (fused multiply-add: one rounding at end)
//   5) fsgnj.s  fd, fs1, fs2
//   6) fmv.x.w  rd, fs1
//   7) fmv.w.x  fd, rs1
//   8) fcvt.s.w fd, rs1
//
// IEEE-754 compliance choices:
//  - Format: binary32 (1 sign, 8 exp, 23 frac)
//  - Special cases handled: +/-0, subnormal, normal, +/-Inf, NaN (quiet/signaling)
//  - Rounding mode: Round Toward Zero (RZ / truncation). This is a valid IEEE-754
//    rounding mode and matches your checkpoint assumptions.
//
// Exception flags (RISC-V fflags order commonly NV,DZ,OF,UF,NX):
//  NV: invalid operation (e.g., Inf - Inf, Inf * 0, signaling NaN)
//  DZ: divide by zero (not used here; no div/sqrt in this instruction set)
//  OF: overflow to Inf
//  UF: underflow to subnormal/zero (we set when exponent drops below normal range)
//  NX: inexact (we truncated non-zero bits during rounding toward zero)
//
// Interface notes:
//  - This is a simple 1-cycle "start/done" unit (busy always 0 here).
//  - For integration, drive fs1/fs2/fs3 from fp_reg_file rd1/rd2/rd3.
//  - For fmv.w.x and fcvt.s.w, provide rs1_value from integer regfile.
//  - Writeback control: write_fp / write_int tell the datapath which regfile
//    should be written for the given operation.
//
// -----------------------------------------------------------------------------


module rv64_fpu_ieee754 (
    input  wire        clk,
    input  wire        reset,

    input  wire        start,

    // operation selector (your decode chooses these values)
    input  wire [4:0]  op,

    // FP operands (raw IEEE-754 bit patterns)
    input  wire [31:0] fs1,
    input  wire [31:0] fs2,
    input  wire [31:0] fs3,   // used by fmadd.s

    // Integer operand for fmv.w.x and fcvt.s.w
    input  wire [63:0] rs1_value,

    output reg         busy,
    output reg         done,

    // Writeback values
    output reg  [31:0] fp_wdata,
    output reg  [63:0] int_wdata,

    // Write enables to each destination domain
    output reg         write_fp,
    output reg         write_int,

    // IEEE-754 / RISC-V fflags: {NV,DZ,OF,UF,NX}
    output reg  [4:0]  flags
);

    // -------------------------------------------------------------------------
    // Operation encoding (adjust to match your control unit)
    // -------------------------------------------------------------------------
    localparam [4:0]
        OP_FADD_S   = 5'd0,
        OP_FMADD_S  = 5'd1,
        OP_FSGNJ_S  = 5'd2,
        OP_FMV_X_W  = 5'd3,
        OP_FMV_W_X  = 5'd4,
        OP_FCVT_S_W = 5'd5;

    // -------------------------------------------------------------------------
    // IEEE-754 field extraction helpers
    // -------------------------------------------------------------------------
    function [7:0] exp8;
        input [31:0] x;
        begin exp8 = x[30:23]; end
    endfunction

    function [22:0] frac23;
        input [31:0] x;
        begin frac23 = x[22:0]; end
    endfunction

    function sign1;
        input [31:0] x;
        begin sign1 = x[31]; end
    endfunction

    function is_zero;
        input [31:0] x;
        begin is_zero = (x[30:0] == 31'd0); end
    endfunction

    function is_inf;
        input [31:0] x;
        begin is_inf = (exp8(x) == 8'hFF) && (frac23(x) == 23'd0); end
    endfunction

    function is_nan;
        input [31:0] x;
        begin is_nan = (exp8(x) == 8'hFF) && (frac23(x) != 23'd0); end
    endfunction

    // Signaling NaN: exp=FF, frac!=0, and quiet bit (MSB of frac) = 0
    function is_snan;
        input [31:0] x;
        begin
            is_snan = (exp8(x) == 8'hFF) && (frac23(x) != 23'd0) && (x[22] == 1'b0);
        end
    endfunction

    // Subnormal: exp=0 and frac!=0
    function is_subnormal;
        input [31:0] x;
        begin
            is_subnormal = (exp8(x) == 8'd0) && (frac23(x) != 23'd0);
        end
    endfunction

    // Pack IEEE-754 binary32
    function [31:0] pack_fp32;
        input        s;
        input [7:0]  e;
        input [22:0] f;
        begin
            pack_fp32 = {s, e, f};
        end
    endfunction

    // Make a quiet NaN (preserve payload loosely; set quiet bit)
    function [31:0] qnan_from;
        input [31:0] x;
        reg [22:0] f;
        begin
            f = frac23(x);
            f[22] = 1'b1;         // set quiet bit
            qnan_from = {1'b0, 8'hFF, f};
        end
    endfunction

    // -------------------------------------------------------------------------
    // Shift-right-with-sticky helper (for alignment/rounding detection)
    // Sticky = OR of all bits shifted out, merged into bit0.
    // -------------------------------------------------------------------------
    function [26:0] shr_sticky27;
        input [26:0] in;
        input integer sh;
        reg sticky;
        integer j;
        reg [26:0] out;
        begin
            if (sh <= 0) begin
                shr_sticky27 = in;
            end else if (sh >= 27) begin
                // everything shifts out -> result 0, sticky is OR of all bits
                sticky = 1'b0;
                for (j = 0; j < 27; j = j + 1) sticky = sticky | in[j];
                shr_sticky27 = {26'd0, sticky};
            end else begin
                sticky = 1'b0;
                for (j = 0; j < sh; j = j + 1) sticky = sticky | in[j];
                out = (in >> sh);
                out[0] = out[0] | sticky;
                shr_sticky27 = out;
            end
        end
    endfunction

    function [47:0] shr_sticky48;
        input [47:0] in;
        input integer sh;
        reg sticky;
        integer j;
        reg [47:0] out;
        begin
            if (sh <= 0) begin
                shr_sticky48 = in;
            end else if (sh >= 48) begin
                sticky = 1'b0;
                for (j = 0; j < 48; j = j + 1) sticky = sticky | in[j];
                shr_sticky48 = {47'd0, sticky};
            end else begin
                sticky = 1'b0;
                for (j = 0; j < sh; j = j + 1) sticky = sticky | in[j];
                out = (in >> sh);
                out[0] = out[0] | sticky;
                shr_sticky48 = out;
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // Unbiased exponent and mantissa extraction
    //  - For normal numbers: mant = 1.frac (24 bits), exp_unb = exp - 127
    //  - For subnormals: mant = 0.frac (24 bits), exp_unb = -126
    //  - For zero: mant=0
    // -------------------------------------------------------------------------
    function signed [11:0] exp_unb;
        input [31:0] x;
        begin
            if (exp8(x) == 8'd0) exp_unb = -12'sd126;
            else exp_unb = $signed({1'b0, exp8(x)}) - 12'sd127;
        end
    endfunction

    function [23:0] mant24;
        input [31:0] x;
        begin
            if (exp8(x) == 8'd0) mant24 = {1'b0, frac23(x)};   // subnormal or zero
            else mant24 = {1'b1, frac23(x)};                   // normal
        end
    endfunction

    // -------------------------------------------------------------------------
    // Rounding toward zero (truncate) on a normalized mantissa with 3 extra bits.
    // We represent mantissa as 27 bits: [26] hidden, [25:3] frac+1, [2:0] extra.
    // IEEE-754 says inexact (NX) if discarded bits are non-zero.
    // -------------------------------------------------------------------------
    function [36:0] pack_round_rz;
        input        s;
        input signed [11:0] e_unb;
        input [26:0] mant27_norm;
        reg [7:0] e_field;
        reg [22:0] frac_field;
        reg nx, of, uf;
        reg [26:0] mant_sub;
        integer sh;
        begin
            nx = (mant27_norm[2:0] != 3'd0);
            of = 1'b0;
            uf = 1'b0;

            // Overflow: exponent too large => Inf (IEEE-754 overflow)
            if (e_unb > 12'sd127) begin
                of = 1'b1;
                nx = 1'b1; // overflow implies inexact in IEEE-754
                pack_round_rz = {5'b00101, {s, 8'hFF, 23'd0}}; // {NV,DZ,OF,UF,NX}
            end
            // Underflow/subnormal: exponent < -126 => shift mantissa right
            else if (e_unb < -12'sd126) begin
                // shift amount to bring exponent up to -126 for subnormal encoding
                sh = (-126 - e_unb); // >= 1
                mant_sub = shr_sticky27(mant27_norm, sh);
                uf = 1'b1;

                // if everything shifted out => +/-0
                if (mant_sub[26:3] == 24'd0) begin
                    // If sticky bit set, we were inexact
                    nx = nx | (mant_sub[0] == 1'b1);
                    pack_round_rz = { {1'b0,1'b0,1'b0,uf,nx}, {s, 8'd0, 23'd0} };
                end else begin
                    // exponent field 0 for subnormal
                    frac_field = mant_sub[25:3];
                    nx = nx | (mant_sub[2:0] != 3'd0);
                    pack_round_rz = { {1'b0,1'b0,1'b0,uf,nx}, {s, 8'd0, frac_field} };
                end
            end
            else begin
                // Normal number
                e_field = e_unb + 8'd127;
                frac_field = mant27_norm[25:3]; // drop hidden bit, keep 23
                pack_round_rz = { {1'b0,1'b0,of,uf,nx}, {s, e_field, frac_field} };
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // fp_add_rz: IEEE-754 binary32 addition with RZ rounding.
    // Handles NaN/Inf/subnormal/zero per IEEE rules.
    // Returns {flags[4:0], result[31:0]}.
    // -------------------------------------------------------------------------
    function [36:0] fp_add_rz;
        input [31:0] x;
        input [31:0] y;
        reg sx, sy, sr;
        reg [36:0] out;
        reg [31:0] res;
        reg [4:0]  f;
        reg signed [11:0] exu, eyu, eru;
        reg [26:0] mx, my;     // 24 + 3 extra bits
        reg [27:0] sum;        // allow carry
        reg [26:0] mantN;
        integer shift;
        integer i;
        integer lead;
        reg [26:0] aA, aB;
        begin
            // Default flags (NV,DZ,OF,UF,NX)
            f = 5'd0;

            // NaN propagation (IEEE-754)
            if (is_nan(x)) begin
                if (is_snan(x)) f[4] = 1'b1; // NV for signaling NaN
                res = qnan_from(x);
                fp_add_rz = {f, res};
            end
            else if (is_nan(y)) begin
                if (is_snan(y)) f[4] = 1'b1;
                res = qnan_from(y);
                fp_add_rz = {f, res};
            end
            // Infinities (IEEE-754)
            else if (is_inf(x) && is_inf(y)) begin
                // Inf + (-Inf) is invalid -> NaN
                if (sign1(x) != sign1(y)) begin
                    f[4] = 1'b1; // NV
                    res = 32'h7FC00000; // canonical quiet NaN
                    fp_add_rz = {f, res};
                end else begin
                    // Inf + Inf (same sign) = Inf
                    res = x;
                    fp_add_rz = {f, res};
                end
            end
            else if (is_inf(x)) begin
                res = x;
                fp_add_rz = {f, res};
            end
            else if (is_inf(y)) begin
                res = y;
                fp_add_rz = {f, res};
            end
            // Zeros: handle sign per IEEE (simple approach: if one is zero, return the other)
            else if (is_zero(x)) begin
                res = y;
                fp_add_rz = {f, res};
            end
            else if (is_zero(y)) begin
                res = x;
                fp_add_rz = {f, res};
            end
            else begin
                sx = sign1(x); sy = sign1(y);
                exu = exp_unb(x);
                eyu = exp_unb(y);

                // Build mantissa with 3 extra bits for rounding detection
                mx = {mant24(x), 3'b000};
                my = {mant24(y), 3'b000};

                // Align exponents by shifting smaller mantissa right (sticky)
                if (exu >= eyu) begin
                    eru = exu;
                    shift = exu - eyu;
                    aA = mx;
                    aB = shr_sticky27(my, shift);
                    sr = sx;
                end else begin
                    eru = eyu;
                    shift = eyu - exu;
                    aA = my;
                    aB = shr_sticky27(mx, shift);
                    sr = sy;
                end

                // Add or subtract based on signs (IEEE-754 sign-magnitude)
                if (sx == sy) begin
                    sum = {1'b0, aA} + {1'b0, aB};
                    sr = sx;
                end else begin
                    // subtract smaller magnitude from larger magnitude
                    if (aA >= aB) begin
                        sum = {1'b0, aA} - {1'b0, aB};
                        // sr remains sign of aA owner from alignment
                    end else begin
                        sum = {1'b0, aB} - {1'b0, aA};
                        sr = (exu >= eyu) ? sy : sx;
                    end
                end

                // If result is zero
                if (sum == 28'd0) begin
                    res = 32'd0;
                    fp_add_rz = {f, res};
                end else begin
                    // Normalize: want hidden bit at mantN[26]
                    if (sum[27]) begin
                        // Carry out -> shift right 1
                        mantN = sum[27:1];
                        // sticky from dropped bit
                        mantN[0] = mantN[0] | sum[0];
                        eru = eru + 1;
                    end else begin
                        mantN = sum[26:0];
                        // shift left until mantN[26] is 1
                        lead = -1;
                        for (i = 26; i >= 0; i = i - 1) begin
                            if (lead == -1 && mantN[i]) lead = i;
                        end
                        if (lead != -1 && lead < 26) begin
                            mantN = mantN << (26 - lead);
                            eru = eru - (26 - lead);
                        end
                    end

                    out = pack_round_rz(sr, eru, mantN);
                    // Merge exception flags from rounding packer (OF/UF/NX)
                    f = out[36:32];
                    res = out[31:0];
                    fp_add_rz = {f, res};
                end
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // fp_mul_rz: IEEE-754 binary32 multiplication with RZ rounding.
    // Handles NaN/Inf/zero per IEEE rules.
    // Returns {flags, result}.
    // -------------------------------------------------------------------------
    function [36:0] fp_mul_rz;
        input [31:0] x;
        input [31:0] y;
        reg [4:0] f;
        reg [31:0] res;
        reg sx, sy, sr;
        reg signed [11:0] exu, eyu, eru;
        reg [23:0] mx24, my24;
        reg [47:0] prod;
        reg [47:0] prodN;
        reg [26:0] mant27;
        reg sticky;
        integer j;
        reg [36:0] out;
        begin
            f = 5'd0;

            // NaN propagation
            if (is_nan(x)) begin
                if (is_snan(x)) f[4] = 1'b1;
                res = qnan_from(x);
                fp_mul_rz = {f, res};
            end else if (is_nan(y)) begin
                if (is_snan(y)) f[4] = 1'b1;
                res = qnan_from(y);
                fp_mul_rz = {f, res};
            end
            // Inf * 0 is invalid
            else if ((is_inf(x) && is_zero(y)) || (is_inf(y) && is_zero(x))) begin
                f[4] = 1'b1; // NV
                res = 32'h7FC00000;
                fp_mul_rz = {f, res};
            end
            else if (is_inf(x) || is_inf(y)) begin
                sr = sign1(x) ^ sign1(y);
                res = {sr, 8'hFF, 23'd0};
                fp_mul_rz = {f, res};
            end
            else if (is_zero(x) || is_zero(y)) begin
                sr = sign1(x) ^ sign1(y);
                res = {sr, 8'd0, 23'd0};
                fp_mul_rz = {f, res};
            end
            else begin
                sx = sign1(x); sy = sign1(y);
                sr = sx ^ sy;

                exu = exp_unb(x);
                eyu = exp_unb(y);
                eru = exu + eyu;

                mx24 = mant24(x);
                my24 = mant24(y);

                // Full precision product (no rounding yet): 24x24 -> 48 bits
                prod = mx24 * my24;

                // Normalize product so leading 1 is at bit46
                if (prod[47]) begin
                    prodN = prod >> 1;
                    eru = eru + 1;
                end else begin
                    prodN = prod;
                end

                // Build 27-bit mantissa with 3 extra bits:
                // Take bits [46:20] (27 bits) and fold all lower bits into sticky.
                mant27 = prodN[46:20];
                sticky = 1'b0;
                for (j = 0; j < 20; j = j + 1) sticky = sticky | prodN[j];
                mant27[0] = mant27[0] | sticky;

                out = pack_round_rz(sr, eru, mant27);
                f   = out[36:32];
                res = out[31:0];
                fp_mul_rz = {f, res};
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // fp_fmadd_rz: IEEE-754 fused multiply-add (binary32) with ONE rounding step.
    // Implements: (fs1 * fs2) + fs3 with fused semantics like RISC-V FMADD.S.
    //
    // IEEE-754 relevance:
    //  - "Fused" means we do NOT round after the multiply; we keep full product
    //    precision, align-add, then round once at the end (per IEEE-754 FMA).
    // -------------------------------------------------------------------------
    function [36:0] fp_fmadd_rz;
        input [31:0] x;
        input [31:0] y;
        input [31:0] z;
        reg [4:0] f;
        reg [31:0] res;
        reg [36:0] out_round;

        reg sx, sy, sz, sp, sr;
        reg signed [11:0] exu, eyu, ezu, ep, er;
        reg [23:0] mx24, my24, mz24;

        reg [47:0] prod;
        reg [47:0] prodN;
        reg [47:0] zN;
        reg [48:0] sum;     // one extra for carry
        reg [47:0] mant48;
        integer shift;
        integer i;
        integer lead;
        reg [26:0] mant27;
        reg sticky;
        integer j;

        begin
            f = 5'd0;

            // NaN handling: if any operand is NaN, propagate quiet NaN (IEEE-754).
            if (is_nan(x)) begin
                if (is_snan(x)) f[4] = 1'b1;
                res = qnan_from(x);
                fp_fmadd_rz = {f, res};
            end else if (is_nan(y)) begin
                if (is_snan(y)) f[4] = 1'b1;
                res = qnan_from(y);
                fp_fmadd_rz = {f, res};
            end else if (is_nan(z)) begin
                if (is_snan(z)) f[4] = 1'b1;
                res = qnan_from(z);
                fp_fmadd_rz = {f, res};
            end
            // Invalid: Inf*0
            else if ((is_inf(x) && is_zero(y)) || (is_inf(y) && is_zero(x))) begin
                f[4] = 1'b1;
                res = 32'h7FC00000;
                fp_fmadd_rz = {f, res};
            end
            else begin
                // Handle cases where product is Inf
                if (is_inf(x) || is_inf(y)) begin
                    sp = sign1(x) ^ sign1(y); // sign of product
                    // If z is Inf with opposite sign, Inf + (-Inf) invalid
                    if (is_inf(z) && (sign1(z) != sp)) begin
                        f[4] = 1'b1;
                        res = 32'h7FC00000;
                        fp_fmadd_rz = {f, res};
                    end else begin
                        // product dominates: +/-Inf
                        res = {sp, 8'hFF, 23'd0};
                        fp_fmadd_rz = {f, res};
                    end
                end
                // If product is zero, reduce to add(z, +/-0)
                else if (is_zero(x) || is_zero(y)) begin
                    fp_fmadd_rz = fp_add_rz({(sign1(x)^sign1(y)), 31'd0}, z);
                end
                else begin
                    // General fused path:
                    sx = sign1(x); sy = sign1(y); sz = sign1(z);
                    sp = sx ^ sy;

                    exu = exp_unb(x);
                    eyu = exp_unb(y);
                    ezu = exp_unb(z);

                    mx24 = mant24(x);
                    my24 = mant24(y);
                    mz24 = mant24(z);

                    // Full product (48 bits), NO rounding here (fused)
                    ep = exu + eyu;
                    prod = mx24 * my24;

                    // Normalize product so leading 1 at bit46
                    if (prod[47]) begin
                        prodN = prod >> 1;
                        ep = ep + 1;
                    end else begin
                        prodN = prod;
                    end

                    // Expand z to 48-bit fixed-point scale comparable to prodN:
                    // mz24 is 1.xxx (or 0.xxx for subnormal), shift left 23 so its
                    // "binary point" aligns with prodN's interpretation.
                    zN = {mz24, 23'd0};

                    // Align exponents: shift smaller significand right by difference.
                    if (ep >= ezu) begin
                        er = ep;
                        shift = ep - ezu;
                        zN = shr_sticky48(zN, shift);
                        // prodN stays
                    end else begin
                        er = ezu;
                        shift = ezu - ep;
                        prodN = shr_sticky48(prodN, shift);
                    end

                    // Add/Sub depending on signs (product sign vs z sign)
                    if (sp == sz) begin
                        sum = {1'b0, prodN} + {1'b0, zN};
                        sr = sp;
                    end else begin
                        if (prodN >= zN) begin
                            sum = {1'b0, prodN} - {1'b0, zN};
                            sr = sp;
                        end else begin
                            sum = {1'b0, zN} - {1'b0, prodN};
                            sr = sz;
                        end
                    end

                    if (sum == 49'd0) begin
                        res = 32'd0;
                        fp_fmadd_rz = {f, res};
                    end else begin
                        // Normalize to keep leading at bit46 in a 48-bit mantissa
                        if (sum[48]) begin
                            // carry -> shift right 1
                            mant48 = sum[48:1];
                            mant48[0] = mant48[0] | sum[0];
                            er = er + 1;
                        end else begin
                            mant48 = sum[47:0];
                            lead = -1;
                            for (i = 47; i >= 0; i = i - 1) begin
                                if (lead == -1 && mant48[i]) lead = i;
                            end
                            // target lead index is 46
                            if (lead != -1 && lead < 46) begin
                                mant48 = mant48 << (46 - lead);
                                er = er - (46 - lead);
                            end else if (lead > 46) begin
                                // shift right with sticky if needed
                                mant48 = shr_sticky48(mant48, (lead - 46));
                                er = er + (lead - 46);
                            end
                        end

                        // Convert 48-bit mantissa -> 27-bit mantissa + sticky
                        mant27 = mant48[46:20];
                        sticky = 1'b0;
                        for (j = 0; j < 20; j = j + 1) sticky = sticky | mant48[j];
                        mant27[0] = mant27[0] | sticky;

                        out_round = pack_round_rz(sr, er, mant27);
                        f   = out_round[36:32];
                        res = out_round[31:0];
                        fp_fmadd_rz = {f, res};
                    end
                end
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // int32_to_fp32_rz: IEEE-754 conversion of signed 32-bit int to float32.
    // Rounding mode is toward zero (truncate) which is IEEE-754 compliant.
    // Sets NX if bits are discarded.
    // -------------------------------------------------------------------------
    function [36:0] int32_to_fp32_rz;
        input signed [31:0] i;
        reg [4:0] f;
        reg [31:0] res;
        reg sign;
        reg [31:0] a;
        integer k;
        integer shift;
        reg [7:0] e;
        reg [23:0] mant;
        reg nx;
        reg [31:0] dropped_mask;
        begin
            f = 5'd0;
            if (i == 0) begin
                res = 32'd0;
                int32_to_fp32_rz = {f, res};
            end else begin
                sign = i[31];
                a = sign ? (~i + 1) : i;

                // find MSB position k
                k = 31;
                while (k > 0 && a[k] == 1'b0) k = k - 1;

                e = k + 8'd127;

                // shift so MSB ends at bit23 (hidden 1)
                shift = k - 23;
                nx = 1'b0;

                if (shift > 0) begin
                    dropped_mask = (32'h1 << shift) - 1;
                    nx = ((a & dropped_mask) != 0);   // discarded bits => NX
                    mant = a >> shift;                // truncation (RZ)
                end else begin
                    mant = a << (-shift);
                end

                res = {sign, e, mant[22:0]};
                f[0] = nx; // NX
                int32_to_fp32_rz = {f, res};
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // Main handshake/control
    // -------------------------------------------------------------------------
    reg [36:0] tmp;

    always @(posedge clk) begin
        if (reset) begin
            busy      <= 1'b0;
            done      <= 1'b0;
            fp_wdata  <= 32'd0;
            int_wdata <= 64'd0;
            write_fp  <= 1'b0;
            write_int <= 1'b0;
            flags     <= 5'd0;
        end else begin
            busy      <= 1'b0;   // single-cycle responder
            done      <= 1'b0;
            write_fp  <= 1'b0;
            write_int <= 1'b0;
            flags     <= 5'd0;

            if (start) begin
                done <= 1'b1;

                case (op)
                    // -----------------------------------------------------------------
                    // fadd.s fd, fs1, fs2
                    // IEEE-754: performs binary32 addition, handles NaN/Inf/zero/subnormal,
                    // rounds toward zero (truncate), and sets fflags accordingly.
                    // -----------------------------------------------------------------
                    OP_FADD_S: begin
                        tmp     = fp_add_rz(fs1, fs2);
                        flags   <= tmp[36:32];
                        fp_wdata<= tmp[31:0];
                        write_fp<= 1'b1;
                    end

                    // -----------------------------------------------------------------
                    // fmadd.s fd, fs1, fs2, fs3
                    // IEEE-754 FMA: (fs1*fs2)+fs3 with fused semantics:
                    // - full product precision is kept (no intermediate rounding)
                    // - addition is performed in extended precision
                    // - one final rounding toward zero is applied
                    // Sets NV for invalid cases (Inf*0, Inf-Inf), etc.
                    // -----------------------------------------------------------------
                    OP_FMADD_S: begin
                        tmp     = fp_fmadd_rz(fs1, fs2, fs3);
                        flags   <= tmp[36:32];
                        fp_wdata<= tmp[31:0];
                        write_fp<= 1'b1;
                    end

                    // -----------------------------------------------------------------
                    // fsgnj.s fd, fs1, fs2
                    // IEEE-754: purely bit-level sign manipulation:
                    // result = {sign(fs2), magnitude(fs1)}.
                    // This preserves exponent+fraction exactly (no rounding/exceptions).
                    // -----------------------------------------------------------------
                    OP_FSGNJ_S: begin
                        fp_wdata <= {fs2[31], fs1[30:0]};
                        flags    <= 5'd0;
                        write_fp <= 1'b1;
                    end

                    // -----------------------------------------------------------------
                    // fmv.x.w rd, fs1
                    // IEEE-754: raw bit move from float to integer register.
                    // RISC-V RV64: sign-extend 32-bit pattern to 64-bit destination.
                    // No IEEE arithmetic occurs; no exceptions.
                    // -----------------------------------------------------------------
                    OP_FMV_X_W: begin
                        int_wdata <= {{32{fs1[31]}}, fs1};
                        flags     <= 5'd0;
                        write_int <= 1'b1;
                    end

                    // -----------------------------------------------------------------
                    // fmv.w.x fd, rs1
                    // IEEE-754: raw bit move from integer to float.
                    // Copies rs1[31:0] into fd as an IEEE-754 bit pattern.
                    // No arithmetic; no exceptions.
                    // -----------------------------------------------------------------
                    OP_FMV_W_X: begin
                        fp_wdata <= rs1_value[31:0];
                        flags    <= 5'd0;
                        write_fp <= 1'b1;
                    end

                    // -----------------------------------------------------------------
                    // fcvt.s.w fd, rs1
                    // IEEE-754: converts signed 32-bit integer to binary32 float.
                    // Uses rounding-toward-zero (truncate). Sets NX if inexact.
                    // -----------------------------------------------------------------
                    OP_FCVT_S_W: begin
                        tmp      = int32_to_fp32_rz($signed(rs1_value[31:0]));
                        flags    <= tmp[36:32];
                        fp_wdata <= tmp[31:0];
                        write_fp <= 1'b1;
                    end

                    default: begin
                        // Unknown FPU op => invalid operation (NV)
                        flags <= 5'b10000;
                    end
                endcase
            end
        end
    end
endmodule
