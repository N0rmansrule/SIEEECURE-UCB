\
    `timescale 1ns/1ps
    // -----------------------------------------------------------------------------
    // tb_div_unit.sv - unit test for div_unit (iterative)
    // -----------------------------------------------------------------------------
    module tb_div_unit;
      logic clk, rst;
      logic start;
      logic is_rem, is_signed;
      logic [63:0] a, b;
      wire busy, done;
      wire [63:0] y;

      div_unit dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .is_rem(is_rem),
        .is_signed(is_signed),
        .a(a),
        .b(b),
        .busy(busy),
        .done(done),
        .y(y)
      );

      initial clk = 1'b0;
      always #5 clk = ~clk;

      task automatic do_div(input logic rem, input logic sgn, input [63:0] aa, input [63:0] bb, input [63:0] exp, input string name);
        begin
          is_rem    = rem;
          is_signed = sgn;
          a         = aa;
          b         = bb;
          start     = 1'b1;
          @(posedge clk);
          start     = 1'b0;

          // wait for done
          while (!done) @(posedge clk);

          if (y !== exp) begin
            $display("FAIL %s: rem=%0d sgn=%0d a=%h b=%h got=%h exp=%h", name, rem, sgn, aa, bb, y, exp);
            $fatal(1);
          end
        end
      endtask

      initial begin
        rst = 1'b1;
        start = 1'b0;
        is_rem = 1'b0;
        is_signed = 1'b0;
        a = 0; b = 1;

        repeat (5) @(posedge clk);
        rst = 1'b0;

        do_div(1'b0, 1'b0, 64'd21, 64'd7, 64'd3, "DIVU");
        do_div(1'b1, 1'b0, 64'd22, 64'd7, 64'd1, "REMU");
        do_div(1'b0, 1'b1, -64'sd22, 64'sd7, -64'sd3, "DIV signed");
        do_div(1'b1, 1'b1, -64'sd22, 64'sd7, -64'sd1, "REM signed");

        // divide by zero: quotient all-ones, remainder dividend
        do_div(1'b0, 1'b0, 64'h1234, 64'd0, 64'hFFFF_FFFF_FFFF_FFFF, "DIV by zero quotient");
        do_div(1'b1, 1'b0, 64'h1234, 64'd0, 64'h1234, "DIV by zero remainder");

        $display("tb_div_unit PASS");
        $finish;
      end
    endmodule
