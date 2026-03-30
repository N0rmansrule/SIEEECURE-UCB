\
    `timescale 1ns/1ps
    // -----------------------------------------------------------------------------
    // tb_mul_unit.sv - unit test for mul_unit (RV64M)
    // -----------------------------------------------------------------------------
    module tb_mul_unit;
      logic [2:0]  funct3;
      logic        is_word;
      logic [63:0] a, b;
      wire  [63:0] y;

      mul_unit dut (
        .funct3(funct3),
        .is_word(is_word),
        .a(a),
        .b(b),
        .y(y)
      );

      task automatic check(input [2:0] f3, input logic iw, input [63:0] aa, input [63:0] bb, input [63:0] exp, input string name);
        begin
          funct3 = f3; is_word = iw; a = aa; b = bb;
          #1;
          if (y !== exp) begin
            $display("FAIL %s: f3=%b iw=%0d a=%h b=%h got=%h exp=%h", name, f3, iw, aa, bb, y, exp);
            $fatal(1);
          end
        end
      endtask

      initial begin
        // MUL low
        check(3'b000, 1'b0, 64'd3, 64'd7, 64'd21, "MUL");
        // MULH signed high: (-2)* (3) = -6 => 128-bit signed, high should be all 1s for small magnitude negative.
        check(3'b001, 1'b0, -64'sd2, 64'sd3, 64'hFFFF_FFFF_FFFF_FFFF, "MULH");
        // MULHU unsigned high
        check(3'b011, 1'b0, 64'hFFFF_FFFF_FFFF_FFFF, 64'h2, 64'h0000_0000_0000_0001, "MULHU");
        // MULW sign-extended low 32 bits
        check(3'b000, 1'b1, 64'h0000_0000_FFFF_FFFE, 64'h0000_0000_0000_0002, 64'hFFFF_FFFF_FFFF_FFFC, "MULW");

        $display("tb_mul_unit PASS");
        $finish;
      end
    endmodule
