`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_soc.sv
// Basic simulation testbench for soc_top.
//
// Usage (example):
//   <sim> +MEMHEX=program.hex
// -----------------------------------------------------------------------------
module tb_soc;
    logic clk;
    logic rst;
    logic ext_irq;
    wire [63:0] dbg_pc;

    // Clock: 100 MHz
    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        rst = 1'b1;
        ext_irq = 1'b0;
        repeat (10) @(posedge clk);
        rst = 1'b0;

        // Run for a while
        repeat (20000) @(posedge clk);
        $display("TB timeout. dbg_pc=%h", dbg_pc);
        $finish;
    end

    soc_top #(
        .RESET_PC(64'h0000_0000_0000_0000),
        .MEM_BYTES(1<<20),
        .MEM_INIT_HEX("")
    ) dut (
        .clk(clk),
        .rst(rst),
        .ext_irq(ext_irq),
        .dbg_pc(dbg_pc)
    );
endmodule
