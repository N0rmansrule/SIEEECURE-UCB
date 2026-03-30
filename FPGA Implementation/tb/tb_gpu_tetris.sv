// tb_gpu_tetris.sv
// Simple smoke-test for gpu_tetris_engine.
// This testbench just runs the GPU long enough to execute some commands.
module tb_gpu_tetris;
    logic clk = 1'b0;
    logic rst = 1'b1;

    wire [7:0] vga_r, vga_g, vga_b;
    wire vga_hsync, vga_vsync;

    // 25 MHz clock ~ 40ns period (approx)
    always #20 clk = ~clk;

    initial begin
        $dumpfile("tb_gpu_tetris.vcd");
        $dumpvars(0, tb_gpu_tetris);
        #200 rst = 1'b0;
        // Run for ~10 frames: 640*480 ~307k pixels per frame, plus porches ~420k clocks/frame
        // Here we run ~5 million cycles.
        #200000000 $finish;
    end

    gpu_tetris_engine #(.ENCRYPTED_ROM(1'b0)) dut (
        .clk(clk),
        .rst(rst),
        .vga_r(vga_r),
        .vga_g(vga_g),
        .vga_b(vga_b),
        .vga_hsync(vga_hsync),
        .vga_vsync(vga_vsync)
    );
endmodule
