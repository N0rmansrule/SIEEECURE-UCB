\
    `timescale 1ns/1ps
    // -----------------------------------------------------------------------------
    // tb_branch_predictor.sv - unit test for branch_predictor (BHT+BTB)
    // -----------------------------------------------------------------------------
    module tb_branch_predictor;
      logic clk, rst;

      logic [63:0] pc_query;
      wire  pred_taken;
      wire  [63:0] pred_target;

      logic upd_valid;
      logic [63:0] upd_pc;
      logic upd_is_cond;
      logic upd_is_jump;
      logic upd_is_call;
      logic upd_is_ret;
      logic upd_taken;
      logic [63:0] upd_target;
      logic [63:0] upd_pc_plus4;

      branch_predictor #(
        .BHT_ENTRIES(16),
        .BTB_ENTRIES(8),
        .RAS_DEPTH(4),
        .TAG_BITS(8)
      ) dut (
        .clk(clk),
        .rst(rst),
        .pc_query(pc_query),
        .pred_taken(pred_taken),
        .pred_target(pred_target),
        .upd_valid(upd_valid),
        .upd_pc(upd_pc),
        .upd_is_cond_branch(upd_is_cond),
        .upd_is_jump(upd_is_jump),
        .upd_is_call(upd_is_call),
        .upd_is_return(upd_is_ret),
        .upd_taken(upd_taken),
        .upd_target(upd_target),
        .upd_pc_plus4(upd_pc_plus4)
      );

      initial clk = 1'b0;
      always #5 clk = ~clk;

      initial begin
        rst = 1'b1;
        pc_query = 64'd0;

        upd_valid = 1'b0;
        upd_pc = 64'd0;
        upd_is_cond = 1'b0;
        upd_is_jump = 1'b0;
        upd_is_call = 1'b0;
        upd_is_ret  = 1'b0;
        upd_taken   = 1'b0;
        upd_target  = 64'd0;
        upd_pc_plus4= 64'd0;

        repeat (4) @(posedge clk);
        rst = 1'b0;

        // Default: no BTB hit => pred_taken should be 0, target pc+4
        pc_query = 64'h1000;
        #1;
        if (pred_taken !== 1'b0 || pred_target !== (64'h1000 + 64'd4)) begin
          $display("FAIL default prediction: taken=%0d target=%h", pred_taken, pred_target);
          $fatal(1);
        end

        // Train a conditional taken branch at pc 0x1000 -> target 0x2000
        @(posedge clk);
        upd_valid   <= 1'b1;
        upd_pc      <= 64'h1000;
        upd_is_cond <= 1'b1;
        upd_is_jump <= 1'b0;
        upd_taken   <= 1'b1;
        upd_target  <= 64'h2000;
        upd_pc_plus4<= 64'h1004;
        @(posedge clk);
        upd_valid   <= 1'b0;

        // After one taken update, BHT should move towards taken, BTB has entry => pred_taken should become 1
        pc_query = 64'h1000;
        repeat (2) @(posedge clk); // allow update to settle in regs
        #1;
        if (pred_taken !== 1'b1 || pred_target !== 64'h2000) begin
          $display("FAIL trained prediction: taken=%0d target=%h", pred_taken, pred_target);
          $fatal(1);
        end

        $display("tb_branch_predictor PASS");
        $finish;
      end
    endmodule
