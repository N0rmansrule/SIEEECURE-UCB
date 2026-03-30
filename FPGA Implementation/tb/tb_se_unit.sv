\
    `timescale 1ns/1ps
    // -----------------------------------------------------------------------------
    // tb_se_unit.sv - unit test for se_unit using a reference AES core
    //
    // This test:
    //  1) loads an AES-128 key
    //  2) constructs ct_a/ct_b for known plaintexts using the same AES core
    //  3) sends SEOP_ADD
    //  4) decrypts the returned ciphertext and checks plaintext result
    // -----------------------------------------------------------------------------
    module tb_se_unit;
      import se_pkg::*;

      logic clk, rst;

      // SE unit I/O
      logic se_enable;
      logic key_update;
      logic [127:0] key_in;
      logic [63:0]  seed_in;

      logic req_valid;
      wire  req_ready;
      logic [6:0] op;
      logic [127:0] ct_a, ct_b;

      wire  resp_valid;
      logic resp_ready;
      wire [127:0] ct_y;
      wire resp_err;

      // Reference AES for expected computation
      logic ref_key_load;
      wire  ref_key_ready;
      logic ref_start;
      logic [127:0] ref_block_in;
      wire  ref_busy, ref_done;
      wire [127:0] ref_block_out;

      // Test vectors
      logic [63:0] ptA, ptB;
      logic [63:0] exp;
      logic [127:0] ksA, ksB, ksOut;
      logic [63:0] ctrA, ctrB;
      logic [63:0] out_pt;

      aes_enc_core #(.KEY_BITS(128)) ref_aes (
        .clk(clk), .rst(rst),
        .key_load(ref_key_load),
        .key_in(key_in),
        .key_ready(ref_key_ready),
        .start(ref_start),
        .block_in(ref_block_in),
        .busy(ref_busy),
        .done(ref_done),
        .block_out(ref_block_out)
      );

      se_unit #(.KEY_BITS(128)) dut (
        .clk(clk), .rst(rst),
        .se_enable(se_enable),
        .key_update(key_update),
        .key_in(key_in),
        .seed_in(seed_in),
        .req_valid(req_valid),
        .req_ready(req_ready),
        .op(op),
        .ct_a(ct_a),
        .ct_b(ct_b),
        .resp_valid(resp_valid),
        .resp_ready(resp_ready),
        .ct_y(ct_y),
        .resp_err(resp_err)
      );

      initial clk = 1'b0;
      always #5 clk = ~clk;

      task automatic aes_encrypt(input [127:0] blk, output [127:0] out);
        begin
          // wait until key ready
          while (!ref_key_ready) @(posedge clk);
          ref_block_in = blk;
          ref_start = 1'b1;
          @(posedge clk);
          ref_start = 1'b0;
          while (!ref_done) @(posedge clk);
          out = ref_block_out;
        end
      endtask

      initial begin
        // init defaults
        rst = 1'b1;

        se_enable = 1'b0;
        key_update = 1'b0;
        key_in = 128'h00112233445566778899aabbccddeeff;
        seed_in = 64'h0123_4567_89ab_cdef;

        req_valid = 1'b0;
        op = SEOP_ADD;
        ct_a = 128'd0;
        ct_b = 128'd0;
        resp_ready = 1'b1;

        ref_key_load = 1'b0;
        ref_start = 1'b0;
        ref_block_in = 128'd0;

        // vectors
        ptA = 64'h1111_2222_3333_4444;
        ptB = 64'h0102_0304_0506_0708;
        exp = ptA + ptB;
        ctrA = 64'h0000_0000_0000_00AA;
        ctrB = 64'h0000_0000_0000_00BB;

        repeat (6) @(posedge clk);
        rst = 1'b0;

        // Load key (both SE unit and reference AES)
        @(posedge clk);
        key_update   <= 1'b1;
        se_enable    <= 1'b1;
        ref_key_load <= 1'b1;
        @(posedge clk);
        key_update   <= 1'b0;
        ref_key_load <= 1'b0;

        // Compute keystreams for input ciphertexts
        aes_encrypt({seed_in, ctrA}, ksA);
        aes_encrypt({seed_in, ctrB}, ksB);

        // Build ciphertext blocks (ctr || (pt XOR ks_low64))
        ct_a = {ctrA, (ptA ^ ksA[63:0])};
        ct_b = {ctrB, (ptB ^ ksB[63:0])};

        // Send request
        @(posedge clk);
        op        <= SEOP_ADD;
        req_valid <= 1'b1;
        @(posedge clk);
        req_valid <= 1'b0;

        // Wait response
        while (!resp_valid) @(posedge clk);
        if (resp_err) begin
          $display("FAIL: resp_err asserted");
          $fatal(1);
        end

        // Decrypt output
        aes_encrypt({seed_in, ct_y[127:64]}, ksOut);
        out_pt = ct_y[63:0] ^ ksOut[63:0];

        if (out_pt !== exp) begin
          $display("FAIL: decrypted result mismatch. got=%h exp=%h", out_pt, exp);
          $fatal(1);
        end

        $display("tb_se_unit PASS");
        $finish;
      end
    endmodule
