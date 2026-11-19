`ifndef RETIRE_DEFS_VH
`define RETIRE_DEFS_VH

`define RETIRE_K_ALU    4'd0
`define RETIRE_K_BRANCH 4'd1
`define RETIRE_K_LOAD   4'd2
`define RETIRE_K_STORE  4'd3
`define RETIRE_K_CSR    4'd4
`define RETIRE_K_ECALL  4'd5
`define RETIRE_K_EBREAK 4'd6
`define RETIRE_K_MRET   4'd7
`define RETIRE_K_FENCE  4'd8
`define RETIRE_K_FENCEI 4'd9

`define RETIRE_XC_REDIR 5'b1_1111

`define RETIRE_FL_SERIAL 0
`define RETIRE_FL_MRET   1
`define RETIRE_FL_STORE  2
`define RETIRE_FL_LOAD   3
`define RETIRE_FL_W      4

`endif
