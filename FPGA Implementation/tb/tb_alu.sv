\
    `timescale 1ns/1ps
    // -----------------------------------------------------------------------------
    // tb_alu.sv - unit test for ALU
    // -----------------------------------------------------------------------------
    module tb_alu;
      import rv64_pkg::*;

      logic [3:0]  sel;
      logic [63:0] A, B;
      wire  [63:0] Y;

      ALU dut (
        .ALU_SELECT(sel),
        .A(A),
        .B(B),
        .ALU_RESULT(Y)
      );

      task automatic check(input [3:0] s, input [63:0] a, input [63:0] b, input [63:0] exp, input string name);
        begin
          sel = s; A = a; B = b;
          #1;
          if (Y !== exp) begin
            $display("FAIL %s: sel=%b A=%h B=%h got=%h exp=%h", name, s, a, b, Y, exp);
            $fatal(1);
          end
        end
      endtask

      initial begin
        // Basic ops
        check(ALU_AND, 64'hF0F0, 64'h0FF0, 64'h00F0, "AND");
        check(ALU_OR , 64'hF0F0, 64'h0FF0, 64'hFFF0, "OR");
        check(ALU_XOR, 64'hAAAA, 64'h0F0F, 64'hA5A5, "XOR");

        // Add/sub
        check(ALU_ADD, 64'd5, 64'd7, 64'd12, "ADD");
        check(ALU_SUB, 64'd5, 64'd7, 64'hFFFF_FFFF_FFFF_FFFE, "SUB");

        // Shifts (B provides shamt in [5:0])
        check(ALU_SLL, 64'h1, 64'd4, 64'h10, "SLL");
        check(ALU_SRL, 64'h10, 64'd4, 64'h1, "SRL");
        check(ALU_SRA, 64'hFFFF_FFFF_FFFF_FFF0, 64'd4, 64'hFFFF_FFFF_FFFF_FFFF, "SRA");

        // Comparisons
        check(ALU_SLT , 64'hFFFF_FFFF_FFFF_FFFF, 64'd1, 64'd1, "SLT signed");
        check(ALU_SLTU, 64'hFFFF_FFFF_FFFF_FFFF, 64'd1, 64'd0, "SLTU unsigned");

        // LUI passthrough
        check(ALU_LUI, 64'd0, 64'h1234_0000, 64'h1234_0000, "LUI");

        $display("tb_alu PASS");
        $finish;
      end
    endmodule
