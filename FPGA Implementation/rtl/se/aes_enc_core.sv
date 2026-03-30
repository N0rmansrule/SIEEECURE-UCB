// -----------------------------------------------------------------------------
// aes_enc_core.sv
// AES encryption core (iterative, one round per cycle).
//
// Parameter KEY_BITS: 128 / 192 / 256
//
// Notes:
// - This is a *synthesizable* AES-ECB encryption core.
// - We use it as a keystream generator in the SIEEECURE unit (CTR-like).
// - Key expansion is computed combinationally on key_load and stored.
// -----------------------------------------------------------------------------
module aes_enc_core #(
    parameter int KEY_BITS = 128
)(
    input  wire                 clk,
    input  wire                 rst,

    // Key loading
    input  wire                 key_load,
    input  wire [KEY_BITS-1:0]  key_in,
    output wire                 key_ready,

    // Block encryption request
    input  wire                 start,
    input  wire [127:0]         block_in,
    output wire                 busy,
    output wire                 done,
    output wire [127:0]         block_out
);
    // Derived AES params
    localparam int NK = KEY_BITS / 32;      // 4/6/8
    localparam int NR = NK + 6;             // 10/12/14
    localparam int WWORDS = 4 * (NR + 1);   // 44/52/60

    // -------------------------------------------------------------------------
    // AES S-box (combinational lookup)
    // -------------------------------------------------------------------------
    function automatic [7:0] sbox(input [7:0] x);
        begin
            unique case (x)
                8'h00: sbox = 8'h63; 8'h01: sbox = 8'h7c; 8'h02: sbox = 8'h77; 8'h03: sbox = 8'h7b;
                8'h04: sbox = 8'hf2; 8'h05: sbox = 8'h6b; 8'h06: sbox = 8'h6f; 8'h07: sbox = 8'hc5;
                8'h08: sbox = 8'h30; 8'h09: sbox = 8'h01; 8'h0a: sbox = 8'h67; 8'h0b: sbox = 8'h2b;
                8'h0c: sbox = 8'hfe; 8'h0d: sbox = 8'hd7; 8'h0e: sbox = 8'hab; 8'h0f: sbox = 8'h76;
                8'h10: sbox = 8'hca; 8'h11: sbox = 8'h82; 8'h12: sbox = 8'hc9; 8'h13: sbox = 8'h7d;
                8'h14: sbox = 8'hfa; 8'h15: sbox = 8'h59; 8'h16: sbox = 8'h47; 8'h17: sbox = 8'hf0;
                8'h18: sbox = 8'had; 8'h19: sbox = 8'hd4; 8'h1a: sbox = 8'ha2; 8'h1b: sbox = 8'haf;
                8'h1c: sbox = 8'h9c; 8'h1d: sbox = 8'ha4; 8'h1e: sbox = 8'h72; 8'h1f: sbox = 8'hc0;
                8'h20: sbox = 8'hb7; 8'h21: sbox = 8'hfd; 8'h22: sbox = 8'h93; 8'h23: sbox = 8'h26;
                8'h24: sbox = 8'h36; 8'h25: sbox = 8'h3f; 8'h26: sbox = 8'hf7; 8'h27: sbox = 8'hcc;
                8'h28: sbox = 8'h34; 8'h29: sbox = 8'ha5; 8'h2a: sbox = 8'he5; 8'h2b: sbox = 8'hf1;
                8'h2c: sbox = 8'h71; 8'h2d: sbox = 8'hd8; 8'h2e: sbox = 8'h31; 8'h2f: sbox = 8'h15;
                8'h30: sbox = 8'h04; 8'h31: sbox = 8'hc7; 8'h32: sbox = 8'h23; 8'h33: sbox = 8'hc3;
                8'h34: sbox = 8'h18; 8'h35: sbox = 8'h96; 8'h36: sbox = 8'h05; 8'h37: sbox = 8'h9a;
                8'h38: sbox = 8'h07; 8'h39: sbox = 8'h12; 8'h3a: sbox = 8'h80; 8'h3b: sbox = 8'he2;
                8'h3c: sbox = 8'heb; 8'h3d: sbox = 8'h27; 8'h3e: sbox = 8'hb2; 8'h3f: sbox = 8'h75;
                8'h40: sbox = 8'h09; 8'h41: sbox = 8'h83; 8'h42: sbox = 8'h2c; 8'h43: sbox = 8'h1a;
                8'h44: sbox = 8'h1b; 8'h45: sbox = 8'h6e; 8'h46: sbox = 8'h5a; 8'h47: sbox = 8'ha0;
                8'h48: sbox = 8'h52; 8'h49: sbox = 8'h3b; 8'h4a: sbox = 8'hd6; 8'h4b: sbox = 8'hb3;
                8'h4c: sbox = 8'h29; 8'h4d: sbox = 8'he3; 8'h4e: sbox = 8'h2f; 8'h4f: sbox = 8'h84;
                8'h50: sbox = 8'h53; 8'h51: sbox = 8'hd1; 8'h52: sbox = 8'h00; 8'h53: sbox = 8'hed;
                8'h54: sbox = 8'h20; 8'h55: sbox = 8'hfc; 8'h56: sbox = 8'hb1; 8'h57: sbox = 8'h5b;
                8'h58: sbox = 8'h6a; 8'h59: sbox = 8'hcb; 8'h5a: sbox = 8'hbe; 8'h5b: sbox = 8'h39;
                8'h5c: sbox = 8'h4a; 8'h5d: sbox = 8'h4c; 8'h5e: sbox = 8'h58; 8'h5f: sbox = 8'hcf;
                8'h60: sbox = 8'hd0; 8'h61: sbox = 8'hef; 8'h62: sbox = 8'haa; 8'h63: sbox = 8'hfb;
                8'h64: sbox = 8'h43; 8'h65: sbox = 8'h4d; 8'h66: sbox = 8'h33; 8'h67: sbox = 8'h85;
                8'h68: sbox = 8'h45; 8'h69: sbox = 8'hf9; 8'h6a: sbox = 8'h02; 8'h6b: sbox = 8'h7f;
                8'h6c: sbox = 8'h50; 8'h6d: sbox = 8'h3c; 8'h6e: sbox = 8'h9f; 8'h6f: sbox = 8'ha8;
                8'h70: sbox = 8'h51; 8'h71: sbox = 8'ha3; 8'h72: sbox = 8'h40; 8'h73: sbox = 8'h8f;
                8'h74: sbox = 8'h92; 8'h75: sbox = 8'h9d; 8'h76: sbox = 8'h38; 8'h77: sbox = 8'hf5;
                8'h78: sbox = 8'hbc; 8'h79: sbox = 8'hb6; 8'h7a: sbox = 8'hda; 8'h7b: sbox = 8'h21;
                8'h7c: sbox = 8'h10; 8'h7d: sbox = 8'hff; 8'h7e: sbox = 8'hf3; 8'h7f: sbox = 8'hd2;
                8'h80: sbox = 8'hcd; 8'h81: sbox = 8'h0c; 8'h82: sbox = 8'h13; 8'h83: sbox = 8'hec;
                8'h84: sbox = 8'h5f; 8'h85: sbox = 8'h97; 8'h86: sbox = 8'h44; 8'h87: sbox = 8'h17;
                8'h88: sbox = 8'hc4; 8'h89: sbox = 8'ha7; 8'h8a: sbox = 8'h7e; 8'h8b: sbox = 8'h3d;
                8'h8c: sbox = 8'h64; 8'h8d: sbox = 8'h5d; 8'h8e: sbox = 8'h19; 8'h8f: sbox = 8'h73;
                8'h90: sbox = 8'h60; 8'h91: sbox = 8'h81; 8'h92: sbox = 8'h4f; 8'h93: sbox = 8'hdc;
                8'h94: sbox = 8'h22; 8'h95: sbox = 8'h2a; 8'h96: sbox = 8'h90; 8'h97: sbox = 8'h88;
                8'h98: sbox = 8'h46; 8'h99: sbox = 8'hee; 8'h9a: sbox = 8'hb8; 8'h9b: sbox = 8'h14;
                8'h9c: sbox = 8'hde; 8'h9d: sbox = 8'h5e; 8'h9e: sbox = 8'h0b; 8'h9f: sbox = 8'hdb;
                8'ha0: sbox = 8'he0; 8'ha1: sbox = 8'h32; 8'ha2: sbox = 8'h3a; 8'ha3: sbox = 8'h0a;
                8'ha4: sbox = 8'h49; 8'ha5: sbox = 8'h06; 8'ha6: sbox = 8'h24; 8'ha7: sbox = 8'h5c;
                8'ha8: sbox = 8'hc2; 8'ha9: sbox = 8'hd3; 8'haa: sbox = 8'hac; 8'hab: sbox = 8'h62;
                8'hac: sbox = 8'h91; 8'had: sbox = 8'h95; 8'hae: sbox = 8'he4; 8'haf: sbox = 8'h79;
                8'hb0: sbox = 8'he7; 8'hb1: sbox = 8'hc8; 8'hb2: sbox = 8'h37; 8'hb3: sbox = 8'h6d;
                8'hb4: sbox = 8'h8d; 8'hb5: sbox = 8'hd5; 8'hb6: sbox = 8'h4e; 8'hb7: sbox = 8'ha9;
                8'hb8: sbox = 8'h6c; 8'hb9: sbox = 8'h56; 8'hba: sbox = 8'hf4; 8'hbb: sbox = 8'hea;
                8'hbc: sbox = 8'h65; 8'hbd: sbox = 8'h7a; 8'hbe: sbox = 8'hae; 8'hbf: sbox = 8'h08;
                8'hc0: sbox = 8'hba; 8'hc1: sbox = 8'h78; 8'hc2: sbox = 8'h25; 8'hc3: sbox = 8'h2e;
                8'hc4: sbox = 8'h1c; 8'hc5: sbox = 8'ha6; 8'hc6: sbox = 8'hb4; 8'hc7: sbox = 8'hc6;
                8'hc8: sbox = 8'he8; 8'hc9: sbox = 8'hdd; 8'hca: sbox = 8'h74; 8'hcb: sbox = 8'h1f;
                8'hcc: sbox = 8'h4b; 8'hcd: sbox = 8'hbd; 8'hce: sbox = 8'h8b; 8'hcf: sbox = 8'h8a;
                8'hd0: sbox = 8'h70; 8'hd1: sbox = 8'h3e; 8'hd2: sbox = 8'hb5; 8'hd3: sbox = 8'h66;
                8'hd4: sbox = 8'h48; 8'hd5: sbox = 8'h03; 8'hd6: sbox = 8'hf6; 8'hd7: sbox = 8'h0e;
                8'hd8: sbox = 8'h61; 8'hd9: sbox = 8'h35; 8'hda: sbox = 8'h57; 8'hdb: sbox = 8'hb9;
                8'hdc: sbox = 8'h86; 8'hdd: sbox = 8'hc1; 8'hde: sbox = 8'h1d; 8'hdf: sbox = 8'h9e;
                8'he0: sbox = 8'he1; 8'he1: sbox = 8'hf8; 8'he2: sbox = 8'h98; 8'he3: sbox = 8'h11;
                8'he4: sbox = 8'h69; 8'he5: sbox = 8'hd9; 8'he6: sbox = 8'h8e; 8'he7: sbox = 8'h94;
                8'he8: sbox = 8'h9b; 8'he9: sbox = 8'h1e; 8'hea: sbox = 8'h87; 8'heb: sbox = 8'he9;
                8'hec: sbox = 8'hce; 8'hed: sbox = 8'h55; 8'hee: sbox = 8'h28; 8'hef: sbox = 8'hdf;
                8'hf0: sbox = 8'h8c; 8'hf1: sbox = 8'ha1; 8'hf2: sbox = 8'h89; 8'hf3: sbox = 8'h0d;
                8'hf4: sbox = 8'hbf; 8'hf5: sbox = 8'he6; 8'hf6: sbox = 8'h42; 8'hf7: sbox = 8'h68;
                8'hf8: sbox = 8'h41; 8'hf9: sbox = 8'h99; 8'hfa: sbox = 8'h2d; 8'hfb: sbox = 8'h0f;
                8'hfc: sbox = 8'hb0; 8'hfd: sbox = 8'h54; 8'hfe: sbox = 8'hbb; 8'hff: sbox = 8'h16;
            endcase
        end
    endfunction

    function automatic [31:0] rotword(input [31:0] w);
        rotword = {w[23:0], w[31:24]};
    endfunction

    function automatic [31:0] subword(input [31:0] w);
        subword = {sbox(w[31:24]), sbox(w[23:16]), sbox(w[15:8]), sbox(w[7:0])};
    endfunction

    function automatic [31:0] rcon(input int idx);
        // idx starts at 1
        logic [7:0] rc;
        begin
            unique case (idx)
                1: rc = 8'h01; 2: rc = 8'h02; 3: rc = 8'h04; 4: rc = 8'h08;
                5: rc = 8'h10; 6: rc = 8'h20; 7: rc = 8'h40; 8: rc = 8'h80;
                9: rc = 8'h1B; 10: rc = 8'h36; 11: rc = 8'h6C; 12: rc = 8'hD8;
                13: rc = 8'hAB; 14: rc = 8'h4D;
                default: rc = 8'h00;
            endcase
            rcon = {rc, 24'h000000};
        end
    endfunction

    // Key expansion (returns flat vector of round keys, rk[r] at slice r*128 +: 128)
    function automatic [(NR+1)*128-1:0] expand_key(input [KEY_BITS-1:0] key);
        logic [31:0] w [0:WWORDS-1];
        logic [31:0] temp;
        logic [(NR+1)*128-1:0] out;
        int i, r;
        begin
            // init words from key (MSW first)
            for (i = 0; i < NK; i = i + 1) begin
                w[i] = key[KEY_BITS-1 - 32*i -: 32];
            end

            for (i = NK; i < WWORDS; i = i + 1) begin
                temp = w[i-1];
                if ((i % NK) == 0) begin
                    temp = subword(rotword(temp)) ^ rcon(i / NK);
                end else if ((NK > 6) && ((i % NK) == 4)) begin
                    temp = subword(temp);
                end
                w[i] = w[i-NK] ^ temp;
            end

            // pack round keys
            out = '0;
            for (r = 0; r < (NR+1); r = r + 1) begin
                out[r*128 +: 128] = {w[4*r], w[4*r+1], w[4*r+2], w[4*r+3]};
            end
            expand_key = out;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Round functions
    // -------------------------------------------------------------------------
    function automatic [7:0] xtime(input [7:0] b);
        xtime = {b[6:0], 1'b0} ^ (8'h1B & {8{b[7]}});
    endfunction

    function automatic [7:0] mul2(input [7:0] b); mul2 = xtime(b); endfunction
    function automatic [7:0] mul3(input [7:0] b); mul3 = xtime(b) ^ b; endfunction

    function automatic [127:0] sub_bytes(input [127:0] s);
        logic [127:0] out;
        int k;
        begin
            out = 128'd0;
            for (k = 0; k < 16; k = k + 1) begin
                out[127 - k*8 -: 8] = sbox(s[127 - k*8 -: 8]);
            end
            sub_bytes = out;
        end
    endfunction

    function automatic [127:0] shift_rows(input [127:0] s);
        logic [7:0] b [0:15];
        logic [7:0] o [0:15];
        logic [127:0] out;
        int k;
        begin
            for (k = 0; k < 16; k = k + 1) begin
                b[k] = s[127 - k*8 -: 8];
            end

            // mapping for column-major state
            o[0]  = b[0];
            o[1]  = b[5];
            o[2]  = b[10];
            o[3]  = b[15];
            o[4]  = b[4];
            o[5]  = b[9];
            o[6]  = b[14];
            o[7]  = b[3];
            o[8]  = b[8];
            o[9]  = b[13];
            o[10] = b[2];
            o[11] = b[7];
            o[12] = b[12];
            o[13] = b[1];
            o[14] = b[6];
            o[15] = b[11];

            out = 128'd0;
            for (k = 0; k < 16; k = k + 1) begin
                out[127 - k*8 -: 8] = o[k];
            end
            shift_rows = out;
        end
    endfunction

    function automatic [127:0] mix_columns(input [127:0] s);
        logic [7:0] b [0:15];
        logic [7:0] o [0:15];
        logic [127:0] out;
        int c, k;
        logic [7:0] a0,a1,a2,a3;
        begin
            for (k = 0; k < 16; k = k + 1) begin
                b[k] = s[127 - k*8 -: 8];
            end

            // process 4 columns
            for (c = 0; c < 4; c = c + 1) begin
                a0 = b[c*4 + 0];
                a1 = b[c*4 + 1];
                a2 = b[c*4 + 2];
                a3 = b[c*4 + 3];

                o[c*4 + 0] = mul2(a0) ^ mul3(a1) ^ a2 ^ a3;
                o[c*4 + 1] = a0 ^ mul2(a1) ^ mul3(a2) ^ a3;
                o[c*4 + 2] = a0 ^ a1 ^ mul2(a2) ^ mul3(a3);
                o[c*4 + 3] = mul3(a0) ^ a1 ^ a2 ^ mul2(a3);
            end

            out = 128'd0;
            for (k = 0; k < 16; k = k + 1) begin
                out[127 - k*8 -: 8] = o[k];
            end
            mix_columns = out;
        end
    endfunction

    function automatic [127:0] add_round_key(input [127:0] s, input [127:0] rk);
        add_round_key = s ^ rk;
    endfunction

    function automatic [127:0] round_func(input [127:0] s, input [127:0] rk);
        round_func = add_round_key(mix_columns(shift_rows(sub_bytes(s))), rk);
    endfunction

    function automatic [127:0] final_round_func(input [127:0] s, input [127:0] rk);
        final_round_func = add_round_key(shift_rows(sub_bytes(s)), rk);
    endfunction

    // -------------------------------------------------------------------------
    // Stored round keys
    // -------------------------------------------------------------------------
    logic [(NR+1)*128-1:0] rk_flat;
    logic key_ready_r;

    assign key_ready = key_ready_r;

    // Helper to access round key slice
    function automatic [127:0] rk_at(input int r);
        rk_at = rk_flat[r*128 +: 128];
    endfunction

    // -------------------------------------------------------------------------
    // Encryption FSM
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {E_IDLE, E_RUN} est_t;
    est_t est;

    logic [127:0] state_reg;
    logic [4:0]   round_idx; // up to 14
    logic done_r;
    logic [127:0] out_reg;

    assign busy = (est != E_IDLE);
    assign done = done_r;
    assign block_out = out_reg;

    always_ff @(posedge clk) begin
        if (rst) begin
            key_ready_r <= 1'b0;
            rk_flat <= '0;

            est <= E_IDLE;
            state_reg <= 128'd0;
            round_idx <= 5'd0;
            done_r <= 1'b0;
            out_reg <= 128'd0;
        end else begin
            done_r <= 1'b0;

            // Load/expand key
            if (key_load) begin
                rk_flat <= expand_key(key_in);
                key_ready_r <= 1'b1;
            end

            case (est)
                E_IDLE: begin
                    if (start && key_ready_r) begin
                        // initial addroundkey with rk[0]
                        state_reg <= add_round_key(block_in, rk_at(0));
                        round_idx <= 5'd1;
                        est <= E_RUN;
                    end
                end

                E_RUN: begin
                    if (round_idx < NR) begin
                        state_reg <= round_func(state_reg, rk_at(round_idx));
                        round_idx <= round_idx + 5'd1;
                    end else begin
                        // final round
                        out_reg <= final_round_func(state_reg, rk_at(NR));
                        done_r <= 1'b1;
                        est <= E_IDLE;
                    end
                end

                default: est <= E_IDLE;
            endcase
        end
    end

endmodule
