// Self-checking test for the functions in execute_pkg.
module execute_pkg_tb;
  import execute_pkg::*;

  integer errors = 0;

  task automatic check(input logic cond, input string msg);
    if (!cond) begin
      $display("FAIL: %s", msg);
      errors++;
    end
  endtask

  initial begin
    // --- fu_of: every op maps to the right FU ---
    check(fu_of(ALU_ADD)    == FU_ALU,    "ALU_ADD -> FU_ALU");
    check(fu_of(ALU_AUIPC)  == FU_ALU,    "ALU_AUIPC -> FU_ALU");
    check(fu_of(BR_BEQ)     == FU_BRANCH, "BR_BEQ -> FU_BRANCH");
    check(fu_of(BR_JALR)    == FU_BRANCH, "BR_JALR -> FU_BRANCH");
    check(fu_of(AGU_LB)     == FU_AGU,    "AGU_LB -> FU_AGU");
    check(fu_of(AGU_SW)     == FU_AGU,    "AGU_SW -> FU_AGU");
    check(fu_of(MUL_MUL)    == FU_MUL,    "MUL_MUL -> FU_MUL");
    check(fu_of(MUL_MULHU)  == FU_MUL,    "MUL_MULHU -> FU_MUL");
    check(fu_of(exec_op_t'(6'd63)) == FU_NONE, "unknown op -> FU_NONE");

    // --- age_is_younger: plain ordering ---
    check( age_is_younger(8'd5,  8'd3), "5 is younger than 3");
    check(!age_is_younger(8'd3,  8'd5), "3 is not younger than 5");
    check(!age_is_younger(8'd7,  8'd7), "an age is not younger than itself");

    // --- age_is_younger: wraparound ---
    check( age_is_younger(8'd2,   8'd250), "2 is younger than 250 after wrap");
    check(!age_is_younger(8'd250, 8'd2),   "250 is older than 2 after wrap");
    check( age_is_younger(8'd0,   8'd255), "0 is younger than 255 after wrap");

    if (errors == 0) $display("PASS");
    else $fatal(1, "%0d check(s) failed", errors);
    $finish;
  end
endmodule
