module BRANCH_COMPARATOR (
    input wire [63:0] A,
    input wire [63:0] B,
    input wire BRANCH_UNSIGNED,
    output wire BRANCH_EQUALS,
    output wire BRANCH_LESS_THAN
);
    wire signed [63:0] A_SIGNED = A;
    wire signed [63:0] B_SIGNED = B;

    // Set Simplified Branch Signals:
    assign BRANCH_EQUALS = (A == B);
    assign BRANCH_LESS_THAN = BRANCH_UNSIGNED ? (A < B) : (A_SIGNED < B_SIGNED);
endmodule