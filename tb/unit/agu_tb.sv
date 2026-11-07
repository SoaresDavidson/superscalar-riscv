// Self-checking unit test for the AGU (rtl/execute/agu.sv).
// The AGU computes address = src1 + imm and flags a misalignment exception
// from the access size (carried by the op). Same handshake/flush contract as
// the ALU. Monitor checks every output against an expected FIFO.
module agu_tb;
  import execute_pkg::*;

  logic     clk = 0, reset, flush;
  age_t     flush_age;
  logic     req_valid, req_ready;
  fu_req_t  req;
  logic     resp_valid, resp_ready;
  fu_resp_t resp;

  agu dut (.clk, .reset, .flush, .flush_age,
           .req_valid, .req_ready, .req,
           .resp_valid, .resp_ready, .resp);

  always #5 clk = ~clk;

  integer errors = 0;
  task automatic check(input logic c, input string m);
    if (!c) begin $display("FAIL [t=%0t]: %s", $time, m); errors++; end
  endtask

  // expected FIFO
  localparam int D = 4096;
  age_t e_age[D]; xlen_t e_addr[D]; reg_t e_rd[D]; logic e_wr[D];
  logic e_exc[D]; exc_cause_t e_cause[D];
  integer head=0, tail=0;
  function automatic void push(input age_t a, input xlen_t ad, input reg_t rd,
                               input logic wr, input logic exc, input exc_cause_t c);
    e_age[tail]=a; e_addr[tail]=ad; e_rd[tail]=rd; e_wr[tail]=wr;
    e_exc[tail]=exc; e_cause[tail]=c; tail++;
  endfunction
  function automatic void kill_younger(input age_t fa);
    while (tail>head && age_is_younger(e_age[tail-1], fa)) tail--;
  endfunction

  always @(posedge clk) if (!reset && resp_valid && resp_ready) begin
    if (head==tail) begin $display("FAIL [t=%0t]: unexpected output, age=%0d addr=%h", $time, resp.age, resp.result); errors++; end
    else begin
      check(resp.age==e_age[head],       $sformatf("age got %0d exp %0d", resp.age, e_age[head]));
      check(resp.result==e_addr[head],   $sformatf("age %0d addr got %h exp %h", resp.age, resp.result, e_addr[head]));
      check(resp.rd==e_rd[head],         $sformatf("age %0d rd", resp.age));
      check(resp.wr_en==e_wr[head],      $sformatf("age %0d wr_en", resp.age));
      check(resp.exception==e_exc[head], $sformatf("age %0d exc got %b exp %b", resp.age, resp.exception, e_exc[head]));
      if (e_exc[head]) check(resp.cause==e_cause[head], $sformatf("age %0d cause", resp.age));
      head++;
    end
  end

  age_t next_age = 0;

  // size in bytes and whether the op is a store, per op
  function automatic int unsigned size_of(input exec_op_t op);
    case (op)
      AGU_LB, AGU_LBU, AGU_SB: return 1;
      AGU_LH, AGU_LHU, AGU_SH: return 2;
      AGU_LW, AGU_LWU, AGU_SW: return 4;
      AGU_LD, AGU_SD:          return 8;
      default:                 return 1;
    endcase
  endfunction
  function automatic logic is_store(input exec_op_t op);
    case (op) AGU_SB, AGU_SH, AGU_SW, AGU_SD: return 1; default: return 0; endcase
  endfunction

  // reference: address and the misalignment exception
  task automatic send(input exec_op_t op, input xlen_t base, input xlen_t imm,
                      input reg_t rd);
    xlen_t addr; int unsigned sz; logic misal, wr; logic hd; exc_cause_t cause;
    addr = base + imm;
    sz   = size_of(op);
    misal = (sz==2 && addr[0]) || (sz==4 && |addr[1:0]) || (sz==8 && |addr[2:0]);
    wr   = is_store(op);
    hd   = !wr;                 // loads write rd; stores do not
    if (!misal)   cause = CAUSE_NONE;
    else if (wr)  cause = CAUSE_STORE_MISALIGNED;
    else          cause = CAUSE_LOAD_MISALIGNED;
    @(negedge clk);
    req='0; req.op=op; req.src1=base; req.imm=imm; req.use_imm=1'b1;
    req.rd=rd; req.wr_en=hd; req.age=next_age;
    req_valid=1;
    #1; while(!req_ready) begin @(negedge clk); #1; end
    push(next_age, addr, rd, hd, misal, cause); next_age++;
  endtask
  task automatic idle(); @(negedge clk); req_valid=0; endtask

  integer seed = 909;
  logic random_bp = 0;
  integer bp_seed = 55;
  always @(negedge clk) if (random_bp) resp_ready = ($random(bp_seed)%4)!=0;

  function automatic exec_op_t rand_mem_op();
    case (($random(seed)&32'h7FFF_FFFF)%11)
      0:return AGU_LB; 1:return AGU_LBU; 2:return AGU_LH; 3:return AGU_LHU;
      4:return AGU_LW; 5:return AGU_LWU; 6:return AGU_LD; 7:return AGU_SB;
      8:return AGU_SH; 9:return AGU_SW; default:return AGU_SD;
    endcase
  endfunction

  initial begin
    reset=1; flush=0; flush_age=0; req_valid=0; req='0; resp_ready=1;
    repeat(2) @(negedge clk); reset=0; #1;
    check(resp_valid==0, "after reset resp_valid=0");
    check(req_ready==1,  "after reset req_ready=1");

    // 1. address arithmetic
    send(AGU_LW, 64'h1000, 64'd16, 5'd5);           // 0x1010, aligned
    send(AGU_LW, 64'h1000, -64'd8, 5'd5);           // negative offset -> 0xFF8
    send(AGU_LD, 64'h2000, 64'd0,  5'd5);           // aligned double
    send(AGU_SB, 64'h3001, 64'd0,  5'd0);           // store byte, any alignment ok

    // 2. alignment per size
    send(AGU_LH, 64'h1001, 64'd0, 5'd5);            // half misaligned (odd)
    send(AGU_LH, 64'h1002, 64'd0, 5'd5);            // half aligned
    send(AGU_LW, 64'h1002, 64'd0, 5'd5);            // word misaligned
    send(AGU_LW, 64'h1004, 64'd0, 5'd5);            // word aligned
    send(AGU_LD, 64'h1004, 64'd0, 5'd5);            // double misaligned
    send(AGU_LD, 64'h1008, 64'd0, 5'd5);            // double aligned
    send(AGU_LB, 64'h1003, 64'd0, 5'd5);            // byte never misaligned

    // 3. store vs load cause, and wr_en
    send(AGU_SW, 64'h2002, 64'd0, 5'd0);            // store misaligned -> STORE cause
    send(AGU_LW, 64'h2002, 64'd0, 5'd5);            // load  misaligned -> LOAD cause

    // 4. misalignment comes from base+imm together
    send(AGU_LW, 64'h1000, 64'd2, 5'd5);            // 0x1002 misaligned via imm
    send(AGU_LW, 64'h1002, 64'd2, 5'd5);            // 0x1004 aligned via imm
    idle(); repeat(2) @(negedge clk);

    // 5. back-pressure: A is held while resp_ready=0; B waits at the input
    resp_ready=0;
    send(AGU_LW, 64'h4000, 64'd0, 5'd5);         // A accepted (output was empty)
    @(negedge clk);                               // A now held in the output reg
    req='0; req.op=AGU_LW; req.src1=64'h4008; req.use_imm=1'b1;
    req.rd=5'd5; req.wr_en=1'b1; req.age=next_age; req_valid=1'b1;  // present B
    repeat(3) begin #1;
      check(req_ready==0,  "bp: req_ready 0 while output held");
      check(resp_valid==1 && resp.result==64'h4000, "bp: held result stable");
      @(negedge clk);
    end
    resp_ready=1;                                 // A leaves, B is accepted
    #1; check(req_ready==1, "bp: req_ready rises with resp_ready");
    push(next_age, 64'h4008, 5'd5, 1'b1, 1'b0, CAUSE_NONE); next_age++;
    idle();
    #1; check(resp_valid==1 && resp.result==64'h4008, "bp: B follows A");
    repeat(2) @(negedge clk);

    // 6. flush: older survives, younger dies
    resp_ready=0; next_age=8'd10;
    send(AGU_LW, 64'h5000, 64'd0, 5'd5);            // age 10
    idle(); flush=1; flush_age=8'd11; #1;
    check(resp_valid==1, "flush: older age10 survives");
    @(negedge clk); flush=0; resp_ready=1; repeat(2) @(negedge clk);

    resp_ready=0; next_age=8'd12;
    send(AGU_LW, 64'h6000, 64'd0, 5'd5);            // age 12
    @(negedge clk); flush=1; flush_age=8'd11; kill_younger(8'd11);
    resp_ready=1; req.age=8'd13; req_valid=1; #1;
    check(resp_valid==0, "flush: younger age12 masked");
    @(negedge clk); flush=0; req_valid=0; #1;
    check(resp_valid==0, "flush: younger age13 dropped");
    repeat(2) @(negedge clk);

    // 7. random with back-pressure
    next_age=0; random_bp=1;
    repeat(200) begin
      exec_op_t op; xlen_t base, imm;
      op=rand_mem_op();
      base={$random(seed),$random(seed)};
      imm =$random(seed);                            // 32-bit sign-extended-ish offset
      send(op, base, imm, 5'd5);
    end
    idle();
    random_bp=0;
    @(negedge clk);
    resp_ready=1;
    repeat(5) @(negedge clk);

    check(head==tail, $sformatf("%0d expected never came out", tail-head));
    if (errors==0) $display("PASS"); else $fatal(1,"%0d check(s) failed", errors);
    $finish;
  end

  initial begin #300000; $fatal(1,"timeout"); end
endmodule
