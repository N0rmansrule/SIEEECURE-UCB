module REG_FILE (
    input wire CLOCK,
    input wire RESET_N,
    input wire WRITE_ENABLE,
    input wire [4:0] READ_ADDRESS_1,
    input wire [4:0] READ_ADDRESS_2,
    input wire [4:0] WRITE_ADDRESS,
    input wire [63:0] WRITE_DATA,
    output wire [63:0] READ_DATA_1,
    output wire [63:0] READ_DATA_2
);
    parameter DEPTH = 32;
    reg [63:0] REG_FILE_MEMORY [0:DEPTH-1];
    integer count;

    // Asynchronous Read Ports:
    assign READ_DATA_1 = (READ_ADDRESS_1 == 5'd0) ? 64'h0 : REG_FILE_MEMORY[READ_ADDRESS_1];
    assign READ_DATA_2 = (READ_ADDRESS_2 == 5'd0) ? 64'h0 : REG_FILE_MEMORY[READ_ADDRESS_2];
    
    // Synchronous Write Port:
    always @(posedge CLOCK or negedge RESET_N) begin
        if (!RESET_N) begin
            for (count=0; count<DEPTH; count=count+1) begin
                REG_FILE_MEMORY[count] <= 64'h0;
            end
        end else begin
            if (WRITE_ENABLE && (WRITE_ADDRESS != 5'd0)) begin
                REG_FILE_MEMORY[WRITE_ADDRESS] <= WRITE_DATA;
            end
            REG_FILE_MEMORY[0] <= 64'h0;
        end
    end
endmodule