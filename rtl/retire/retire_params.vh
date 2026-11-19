`ifndef RETIRE_PARAMS_VH
`define RETIRE_PARAMS_VH

`ifndef RETIRE_XLEN
`define RETIRE_XLEN 64
`endif

`ifndef RETIRE_PC_W
`define RETIRE_PC_W 64
`endif

`ifndef RETIRE_LANES
`define RETIRE_LANES 3
`endif

`ifndef RETIRE_ROB_ROWS
`define RETIRE_ROB_ROWS 16
`endif

`ifndef RETIRE_AREG_W
`define RETIRE_AREG_W 5
`endif

`ifndef RETIRE_NUM_PREGS
`define RETIRE_NUM_PREGS 64
`endif

`ifndef RETIRE_PREG_W
`define RETIRE_PREG_W 6
`endif

`ifndef RETIRE_WB_PORTS
`define RETIRE_WB_PORTS 4
`endif

`ifndef RETIRE_XC_PORTS
`define RETIRE_XC_PORTS 3
`endif

`ifndef RETIRE_DBG_EN
`define RETIRE_DBG_EN 1
`endif

`ifndef RETIRE_MTVEC_RESET
`define RETIRE_MTVEC_RESET 64'h0
`endif

`endif
