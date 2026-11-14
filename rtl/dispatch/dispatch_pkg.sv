// Entry types written by Dispatch into the ROB and the reservation stations.
// Spec: docs/dispatch/Dispatch.md (sections "Entrada na RS" and "Vizinhos").
//
// Temporary home. These types belong to the ROB and to the reservation
// stations, whose owners may move them when those blocks exist. They hold only
// information that execute_pkg does not have; every shared width and enum
// (XLEN, TAG_W, AGE_W, exec_op_t...) comes from execute_pkg, never redefined
// here (AGENTS.md, "Decode <-> Execute interface").
//
// The reservation stations hold tags only (decided, Dispatch.md item 4):
// operand values are read from the physical register file after issue,
// through the PRFRename read_tag -> read_data ports.
// PENDING (open item 5): pred_taken / pred_target have no source yet, because
// uop_t carries no prediction.
package dispatch_pkg;
  import execute_pkg::*;

  // -------------------------------------------------------------------------
  // Reservation station INT, shared by the ALU and the Branch Unit (one FU of
  // each kind, Execute wiki). The FU of an entry is fu_of(op); there is no
  // port choice.
  // -------------------------------------------------------------------------
  typedef struct packed {
    logic     busy;          // entry holds an instruction
    // source 1
    logic     src1_ready;    // the value of src1_tag is (or will be) in the PRF
    tag_t     src1_tag;      // tag to wait for, then to read at issue
    // source 2
    logic     src2_ready;
    tag_t     src2_tag;
    // execution: copied into fu_req_t at issue
    exec_op_t op;
    xlen_t    imm;
    logic     use_imm;
    xlen_t    pc;
    tag_t     dst_tag;       // becomes fu_req_t.dst_tag
    logic     wr_en;         // has_dest
    age_t     age;
    logic     pred_taken;
    xlen_t    pred_target;
  } rs_int_entry_t;

  // -------------------------------------------------------------------------
  // Reservation station MEM (port 2: AGU and LSU)
  // -------------------------------------------------------------------------
  typedef struct packed {
    logic     busy;
    // source 1: address base
    logic     src1_ready;
    tag_t     src1_tag;
    // source 2: store data (a load enters with src2_ready = 1)
    logic     src2_ready;
    tag_t     src2_tag;
    // execution
    exec_op_t op;            // AGU_*: access size, signedness and direction
    xlen_t    imm;           // address = src1 + imm
    tag_t     dst_tag;       // load destination
    logic     wr_en;         // 1 for a load with rd != x0, 0 for a store
    age_t     age;
  } rs_mem_entry_t;

  // -------------------------------------------------------------------------
  // ROB entry: what Dispatch knows about an instruction when it allocates it.
  // The ROB owner adds the fields filled later (completion, exception cause,
  // branch outcome).
  // -------------------------------------------------------------------------
  typedef struct packed {
    xlen_t pc;               // exception PC (mepc)
    reg_t  rd;               // architectural destination, for the committed map
    logic  has_dest;         // writes rd: commit sends rd/dst_tag/old_tag to Rename
    tag_t  dst_tag;          // becomes the architectural tag of rd at commit
    tag_t  old_tag;          // returns to the free list at commit
    logic  done;             // no FU will answer (fu_of(op) == FU_NONE)
    logic  illegal;          // raise illegal-instruction at commit
    logic  serializing;      // system instruction, handled by Retirement
  } rob_entry_t;

endpackage
